import Foundation
import Security

enum PauseCoreEncryptedState {
    static let format = "hard-pause-aes-256-gcm-v1"

    private struct Envelope: Codable {
        let format: String
        let purpose: String
        let nonce: String
        let ciphertext: String
        let tag: String
    }

    private struct SealArguments: Encodable {
        let payloadB64: String
        let masterKeyB64: String
        let purpose: String
        let nonceB64: String
    }

    private struct SealResult: Decodable { let envelope: Envelope }
    private struct OpenArguments: Encodable {
        let envelope: Envelope
        let masterKeyB64: String
        let purpose: String
    }
    private struct OpenResult: Decodable { let payloadB64: String }

    enum Failure: Error {
        case invalidKey
        case invalidEnvelope
    }

    static func seal(
        _ payload: Data,
        masterKey: Data,
        purpose: String,
        nonce: Data? = nil
    ) throws -> Data {
        let nonce = try nonce ?? randomNonce()
        do {
            let result: SealResult = try RustCoreBridge.call(
                "crypto.seal",
                SealArguments(
                    payloadB64: payload.base64EncodedString(),
                    masterKeyB64: masterKey.base64EncodedString(),
                    purpose: purpose,
                    nonceB64: nonce.base64EncodedString()
                )
            )
            return try JSONEncoder().encode(result.envelope)
        } catch {
            throw failure(for: error)
        }
    }

    static func open(_ data: Data, masterKey: Data, purpose: String) throws -> Data {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let result: OpenResult = try RustCoreBridge.call(
                "crypto.open",
                OpenArguments(
                    envelope: envelope,
                    masterKeyB64: masterKey.base64EncodedString(),
                    purpose: purpose
                )
            )
            guard let payload = Data(base64Encoded: result.payloadB64) else {
                throw Failure.invalidEnvelope
            }
            return payload
        } catch {
            throw failure(for: error)
        }
    }

    private static func randomNonce() throws -> Data {
        var nonce = Data(count: 12)
        let status = nonce.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.invalidEnvelope }
        return nonce
    }

    private static func failure(for error: Error) -> Failure {
        if case RustCoreBridge.Failure.rejected("invalid_key") = error {
            return .invalidKey
        }
        return .invalidEnvelope
    }
}
