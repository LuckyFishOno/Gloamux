import CryptoKit
import Foundation
import MasterPassword
import Security

/// Sign-in secrets that work without unlocking anything, on this Mac only.
///
/// Each entry is sealed with AES-GCM under a key rebuilt from a Secure Enclave key agreement, with the entry ID bound
/// as associated data. The file holds the enclave's wrapped key handle, which no other Mac can use; the enclave key
/// needs no Touch ID, so a saved password connects again after the app restarts.
struct DeviceSecrets {
    static var isAvailable: Bool { SecureEnclave.isAvailable }
    private static let contextInfo = Data("Gloamux saved sign-ins v1".utf8)
    /// Entries saved under an earlier name were sealed with that name in the key derivation. They still open, and are
    /// sealed again under the current name the first time they are read.
    static let legacyContextInfo = LegacyName.installs.map { Data("\($0.folder) saved sign-ins v1".utf8) }
    static let unreadable = "The password saved on this Mac for this account could not be read. Type it again to replace it."

    private struct File: Codable {
        var version = 1
        var enclaveKey: Data
        var peerKey: Data
        var entries: [String: Data] = [:]
    }

    private let url: URL
    private var file: File?
    private var key: SymmetricKey?
    private var shared: SharedSecret?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let loaded = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard loaded.version == 1 else { throw WorkspaceError.invalid("Saved sign-ins use an unknown format.") }
            file = loaded
        }
    }

    func contains(_ id: String) -> Bool { file?.entries[id] != nil }
    var identifiers: [String] { file?.entries.keys.sorted() ?? [] }

    mutating func secret(id: String) throws -> String? {
        guard let sealed = file?.entries[id] else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { throw WorkspaceError.invalid(Self.unreadable) }
        let tag = Data(id.utf8)
        if let opened = try? AES.GCM.open(box, using: try symmetricKey(), authenticating: tag) {
            return String(decoding: opened, as: UTF8.self)
        }
        for info in Self.legacyContextInfo {
            guard let opened = try? AES.GCM.open(box, using: try symmetricKey(info: info), authenticating: tag) else { continue }
            let secret = String(decoding: opened, as: UTF8.self)
            try? store(id: id, secret: secret)
            return secret
        }
        throw WorkspaceError.invalid(Self.unreadable)
    }

    mutating func store(id: String, secret: String) throws {
        if file == nil { file = try Self.newFile() }
        guard let sealed = try AES.GCM.seal(Data(secret.utf8), using: try symmetricKey(), authenticating: Data(id.utf8)).combined else {
            throw WorkspaceError.invalid("Could not save the sign-in.")
        }
        file?.entries[id] = sealed
        try save()
    }

    mutating func remove(id: String) throws {
        guard file?.entries.removeValue(forKey: id) != nil else { return }
        try save()
    }

    private func save() throws {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(encoder.encode(file), to: url)
    }

    private mutating func symmetricKey() throws -> SymmetricKey {
        if let key { return key }
        let derived = try symmetricKey(info: Self.contextInfo)
        key = derived
        return derived
    }

    private mutating func symmetricKey(info: Data) throws -> SymmetricKey {
        if shared == nil {
            guard let file else { throw VaultError.notFound("saved sign-ins") }
            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.enclaveKey)
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: file.peerKey)
            shared = try enclave.sharedSecretFromKeyAgreement(with: peer)
        }
        return shared!.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }

    private static func newFile() throws -> File {
        guard isAvailable, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                          [.privateKeyUsage], nil) else {
            throw WorkspaceError.invalid("This Mac has no Secure Enclave.")
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let peer = P256.KeyAgreement.PrivateKey()
        return File(enclaveKey: enclave.dataRepresentation, peerKey: peer.publicKey.x963Representation)
    }
}
