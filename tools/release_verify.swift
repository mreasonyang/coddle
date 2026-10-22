// Verify update bytes against the public key embedded in the shipped app.
import CryptoKit
import Foundation

do {
    guard CommandLine.arguments.count == 4,
          let signature = Data(base64Encoded: CommandLine.arguments[2]),
          let publicKeyData = Data(base64Encoded: CommandLine.arguments[3]) else {
        throw NSError(domain: "CoddleRelease", code: 1)
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "CoddleRelease", code: 2)
    }
} catch {
    fputs("Release archive signature does not match its embedded public key.\n", stderr)
    exit(1)
}
