import CryptoKit
import Foundation

/// Portable JSON envelope. Other platforms can open it with AES-256-GCM, base64,
/// and UTF-8 AAD `HardPause/state/v1/<purpose>`; key storage is platform-specific.
enum PauseCoreEncryptedState {
    static let format = "hard-pause-aes-256-gcm-v1"

    private struct Envelope: Codable {
        let format: String
        let purpose: String
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

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
        let key = try encryptionKey(masterKey)
        let nonce = try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(
            payload, using: key, nonce: nonce, authenticating: associatedData(purpose)
        )
        return try JSONEncoder().encode(
            Envelope(
                format: format,
                purpose: purpose,
                nonce: Data(nonce),
                ciphertext: box.ciphertext,
                tag: box.tag
            )
        )
    }

    static func open(_ data: Data, masterKey: Data, purpose: String) throws -> Data {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == format, envelope.purpose == purpose,
            envelope.nonce.count == 12, envelope.tag.count == 16
        else { throw Failure.invalidEnvelope }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: envelope.nonce),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        return try AES.GCM.open(
            box, using: encryptionKey(masterKey), authenticating: associatedData(purpose)
        )
    }

    private static func encryptionKey(_ masterKey: Data) throws -> SymmetricKey {
        guard masterKey.count == 32 else { throw Failure.invalidKey }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: Data("HardPause/state-key/v1".utf8),
            info: Data("AES-256-GCM".utf8),
            outputByteCount: 32
        )
    }

    private static func associatedData(_ purpose: String) -> Data {
        Data("HardPause/state/v1/\(purpose)".utf8)
    }
}
