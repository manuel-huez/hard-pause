import CryptoKit
import Foundation
import LocalAuthentication
import Security

func noninteractiveKeychainContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
}

protocol StateAuthenticationKeyStoring: AnyObject {
    func existingKey() throws -> Data?
    func keyForWrite() throws -> Data
    func hasCommittedState() throws -> Bool
    func markCommittedState() throws
    func readAnchor() throws -> StateCommitAnchor?
    func saveAnchor(_ anchor: StateCommitAnchor) throws
}

struct StateCommitAnchor: Codable, Equatable {
    let currentDigest: String?
    let pendingDigest: String?
}

final class SystemKeychainStateAuthenticationKeys: StateAuthenticationKeyStoring {
    private static let keyAccount = "authentication-key-v1"
    private static let committedAccount = "committed-state-v1"
    private static let anchorAccount = "state-anchor-v1"
    private let service: String

    init(service: String = "org.hardpause.protected-state") {
        self.service = service
    }

    func existingKey() throws -> Data? {
        let data = try read(account: Self.keyAccount)
        guard data == nil || data?.count == 32 else {
            throw ServiceRuntimeError.unreadableState("the protected state key is invalid")
        }
        return data
    }

    func keyForWrite() throws -> Data {
        if let key = try existingKey() { return key }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ServiceRuntimeError.stateWriteFailed("the protected state key could not be created")
        }
        do {
            try add(key, account: Self.keyAccount)
        } catch {
            if let existing = try existingKey() { return existing }
            throw error
        }
        return key
    }

    func hasCommittedState() throws -> Bool {
        if try readAnchor() != nil { return true }
        guard let marker = try read(account: Self.committedAccount) else { return false }
        guard marker == Data([1]) else {
            throw ServiceRuntimeError.unreadableState("the protected state marker is invalid")
        }
        return true
    }

    func readAnchor() throws -> StateCommitAnchor? {
        guard let data = try read(account: Self.anchorAccount) else { return nil }
        guard let anchor = try? JSONDecoder().decode(StateCommitAnchor.self, from: data),
            anchor.currentDigest != nil || anchor.pendingDigest != nil
        else { throw ServiceRuntimeError.unreadableState("the protected state anchor is invalid") }
        return anchor
    }

    func saveAnchor(_ anchor: StateCommitAnchor) throws {
        guard anchor.currentDigest != nil || anchor.pendingDigest != nil else {
            throw ServiceRuntimeError.stateWriteFailed("the protected state anchor is empty")
        }
        let data = try JSONEncoder().encode(anchor)
        if try readAnchor() == nil {
            do {
                try add(data, account: Self.anchorAccount)
                return
            } catch {
                guard try readAnchor() != nil else { throw error }
            }
        }
        let keychain = try systemKeychain()
        var query = baseQuery(account: Self.anchorAccount)
        query[kSecMatchSearchList as String] = [keychain]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw ServiceRuntimeError.stateWriteFailed("the protected state anchor could not be saved")
        }
    }

    func markCommittedState() throws {
        if try hasCommittedState() { return }
        do {
            try add(Data([1]), account: Self.committedAccount)
        } catch {
            guard try hasCommittedState() else { throw error }
        }
    }

    private func read(account: String) throws -> Data? {
        let keychain = try systemKeychain()
        var query = baseQuery(account: account)
        query[kSecMatchSearchList as String] = [keychain]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = noninteractiveKeychainContext()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ServiceRuntimeError.unreadableState("the protected state key is unavailable")
        }
        return data
    }

    private func add(_ data: Data, account: String) throws {
        let keychain = try systemKeychain()
        var query = baseQuery(account: account)
        query[kSecUseKeychain as String] = keychain
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "Hard Pause protected state"
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw ServiceRuntimeError.stateWriteFailed("the protected state key could not be saved")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func systemKeychain() throws -> SecKeychain {
        var keychain: Unmanaged<SecKeychain>?
        guard HPCopySystemKeychain(&keychain) == errSecSuccess,
            let keychain
        else {
            throw ServiceRuntimeError.unreadableState("the system keychain is unavailable")
        }
        return keychain.takeRetainedValue()
    }
}

struct StateAuthenticator {
    let keys: any StateAuthenticationKeyStoring
    private let authenticationField = "_hardPauseAuthentication"

    func seal(_ payload: Data, purpose: String) throws -> Data {
        try PauseCoreEncryptedState.seal(
            payload, masterKey: keys.keyForWrite(), purpose: purpose
        )
    }

    func open(_ data: Data, purpose: String) throws -> (payload: Data, isLegacy: Bool) {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceRuntimeError.unreadableState("protected state has an invalid format")
        }
        if object["format"] as? String == PauseCoreEncryptedState.format {
            guard let key = try keys.existingKey() else {
                throw ServiceRuntimeError.unreadableState("the protected state key is missing")
            }
            do {
                return (try PauseCoreEncryptedState.open(data, masterKey: key, purpose: purpose), false)
            } catch {
                throw ServiceRuntimeError.unreadableState("protected state decryption failed")
            }
        }
        if let value = object.removeValue(forKey: authenticationField) {
            guard let metadata = value as? [String: String],
                metadata["format"] == "hmac-sha256-v1",
                metadata["purpose"] == purpose,
                let encodedCode = metadata["code"],
                let code = Data(base64Encoded: encodedCode),
                let key = try keys.existingKey()
            else {
                throw ServiceRuntimeError.unreadableState("protected state authentication failed")
            }
            let unsigned = try canonicalJSON(object)
            guard
                HMAC<SHA256>.isValidAuthenticationCode(
                    code,
                    authenticating: authenticatedBytes(unsigned, purpose: purpose),
                    using: SymmetricKey(data: key)
                )
            else {
                throw ServiceRuntimeError.unreadableState("protected state authentication failed")
            }
            return (unsigned, true)
        }
        guard try !keys.hasCommittedState() else {
            throw ServiceRuntimeError.unreadableState("protected state authentication is missing")
        }
        return (data, true)
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func authenticatedBytes(_ payload: Data, purpose: String) -> Data {
        var data = Data("HardPause/\(purpose)".utf8)
        data.append(0)
        data.append(payload)
        return data
    }
}
