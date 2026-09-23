import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let encoded = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    fputs("Invalid Sparkle EdDSA private key file\n", stderr)
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
