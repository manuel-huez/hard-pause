import Foundation
import Security

protocol AppleLockdownCredentialVault: AnyObject {
    func save(passcode: String, credentialID: UUID) throws
    func read(credentialID: UUID) throws -> String
    func delete(credentialID: UUID) throws
    func deleteAll() throws
    func containsAnyCredential() throws -> Bool
}

protocol AppleLockdownPasscodeGenerating: AnyObject {
    func generate() throws -> String
}

final class SecureAppleLockdownPasscodeGenerator: AppleLockdownPasscodeGenerating {
    func generate() throws -> String {
        var digits: [UInt8] = []
        digits.reserveCapacity(4)
        while digits.count < 4 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
                throw AppleLockdownError.credentialStoreFailed
            }
            guard byte < 250 else { continue }
            digits.append(48 + byte % 10)
        }
        return String(decoding: digits, as: UTF8.self)
    }
}

final class SystemFileKeychainAppleLockdownVault: AppleLockdownCredentialVault {
    private static let service = "org.hardpause.apple-lockdown"

    func save(passcode: String, credentialID: UUID) throws {
        try validate(passcode)
        let keychain = try systemKeychain()
        var query = baseQuery(credentialID: credentialID)
        query[kSecUseKeychain as String] = keychain
        query[kSecValueData as String] = Data(passcode.utf8)
        query[kSecAttrLabel as String] = "Hard Pause Screen Time credential"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppleLockdownError.credentialStoreFailed
        }
    }

    func read(credentialID: UUID) throws -> String {
        let keychain = try systemKeychain()
        var query = baseQuery(credentialID: credentialID)
        query[kSecMatchSearchList as String] = [keychain]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = noninteractiveKeychainContext()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let passcode = String(data: data, encoding: .utf8)
        else {
            throw AppleLockdownError.credentialUnavailable
        }
        try validate(passcode)
        return passcode
    }

    func delete(credentialID: UUID) throws {
        let keychain = try systemKeychain()
        var query = baseQuery(credentialID: credentialID)
        query[kSecMatchSearchList as String] = [keychain]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleLockdownError.credentialStoreFailed
        }
    }

    func deleteAll() throws {
        let keychain = try systemKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchSearchList as String: [keychain],
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleLockdownError.credentialStoreFailed
        }
    }

    func containsAnyCredential() throws -> Bool {
        let keychain = try systemKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: noninteractiveKeychainContext(),
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw AppleLockdownError.credentialStoreFailed
        }
        return true
    }

    private func baseQuery(credentialID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credentialID.uuidString.lowercased(),
        ]
    }

    private func systemKeychain() throws -> SecKeychain {
        var keychain: Unmanaged<SecKeychain>?
        let status = HPCopySystemKeychain(&keychain)
        guard status == errSecSuccess, let keychain else {
            throw AppleLockdownError.credentialStoreFailed
        }
        return keychain.takeRetainedValue()
    }

    private func validate(_ passcode: String) throws {
        guard passcode.utf8.count == 4,
            passcode.utf8.allSatisfy({ (48...57).contains($0) })
        else {
            throw AppleLockdownError.credentialUnavailable
        }
    }
}
