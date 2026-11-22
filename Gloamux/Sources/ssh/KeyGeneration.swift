import CommonCrypto
import CryptoKit
import Foundation

/// A new Ed25519 key in the OpenSSH file format, as `ssh-keygen -t ed25519` writes it.
public struct GeneratedSSHKey: Sendable {
    /// The private key file, `-----BEGIN OPENSSH PRIVATE KEY-----` through the end line.
    public let privateKey: String
    /// The line for `authorized_keys` and the `.pub` file.
    public let publicKeyLine: String

    /// Creates a key. With a passphrase, the file is encrypted with aes256-ctr and a bcrypt key, as OpenSSH does.
    public static func ed25519(comment: String, passphrase: String = "", rounds: UInt32 = 16) throws -> GeneratedSSHKey {
        let key = Curve25519.Signing.PrivateKey()
        return try ed25519(seed: Array(key.rawRepresentation), comment: comment, passphrase: passphrase, rounds: rounds,
                           check: UInt32.random(in: .min ... .max), salt: (0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func ed25519(seed: [UInt8], comment: String, passphrase: String, rounds: UInt32, check: UInt32, salt: [UInt8]) throws -> GeneratedSSHKey {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = Array(key.publicKey.rawRepresentation)
        let comment = comment.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")

        var blob = WireWriter()
        blob.string("ssh-ed25519"); blob.string(publicKey)

        let encrypted = !passphrase.isEmpty
        let blockSize = encrypted ? 16 : 8
        var secret = WireWriter()
        secret.uint32(check); secret.uint32(check)
        secret.string("ssh-ed25519"); secret.string(publicKey); secret.string(seed + publicKey); secret.string(Array(comment.utf8))
        var pad: UInt8 = 1
        while secret.bytes.count % blockSize != 0 { secret.bytes.append(pad); pad += 1 }

        var options = WireWriter()
        var body = secret.bytes
        if encrypted {
            options.string(salt); options.uint32(rounds)
            let material = try BCryptKDF.derive(passphrase: passphrase, salt: salt, rounds: rounds, length: 48)
            // CTR mode is its own inverse.
            body = try AESSpec(keyLength: 32, mode: CCMode(kCCModeCTR)).decrypt(body, key: Array(material[..<32]), iv: Array(material[32...]))
        }

        var file = WireWriter()
        file.bytes += Array("openssh-key-v1\0".utf8)
        file.string(encrypted ? "aes256-ctr" : "none"); file.string(encrypted ? "bcrypt" : "none")
        file.string(options.bytes)
        file.uint32(1)
        file.string(blob.bytes)
        file.string(body)

        let base64 = Data(file.bytes).base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<next])); index = next
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        let line = "ssh-ed25519 " + Data(blob.bytes).base64EncodedString() + (comment.isEmpty ? "" : " " + comment)
        return GeneratedSSHKey(privateKey: lines.joined(separator: "\n") + "\n", publicKeyLine: line)
    }

    /// Writes the key to `url` (readable only by you) and the public key next to it with `.pub` added.
    public func write(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let publicURL = url.appendingPathExtension("pub")
        guard !fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: publicURL.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard fileManager.createFile(atPath: url.path, contents: Data(privateKey.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard fileManager.createFile(atPath: publicURL.path, contents: Data((publicKeyLine + "\n").utf8), attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: publicURL.path])
        }
    }
}

private struct WireWriter {
    var bytes: [UInt8] = []
    mutating func uint32(_ value: UInt32) { bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    mutating func string(_ value: [UInt8]) { uint32(UInt32(value.count)); bytes += value }
    mutating func string(_ value: String) { string(Array(value.utf8)) }
}
