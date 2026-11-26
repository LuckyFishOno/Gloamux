import Crypto
import Foundation
import NIOCore
import NIOSSH
import BigInt

/// Finite-field Diffie-Hellman key exchange with the RFC 3526 MODP groups, for servers and network devices that offer
/// no elliptic-curve key exchange: diffie-hellman-group16-sha512 and diffie-hellman-group14-sha256 (RFC 8268).
/// SHA-1 variants are left out. Offered only when a session's SSH algorithms are set to Compatible.
protocol FiniteFieldGroup {
    associatedtype Hash: HashFunction
    static var name: Substring { get }
    static var prime: BigUInt { get }
    /// Bits of the private exponent: twice the group's security strength.
    static var exponentBits: Int { get }
}

enum ModpGroup14SHA256: FiniteFieldGroup {
    typealias Hash = SHA256
    static let name: Substring = "diffie-hellman-group14-sha256"
    static let prime = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74" +
        "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437" +
        "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05" +
        "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB" +
        "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718" +
        "3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF", radix: 16)!
    static let exponentBits = 512
}

enum ModpGroup16SHA512: FiniteFieldGroup {
    typealias Hash = SHA512
    static let name: Substring = "diffie-hellman-group16-sha512"
    static let prime = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74" +
        "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437" +
        "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05" +
        "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB" +
        "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718" +
        "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33" +
        "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864" +
        "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2" +
        "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7" +
        "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8" +
        "DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2" +
        "233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9" +
        "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF", radix: 16)!
    static let exponentBits = 1024
}

struct FiniteFieldKeyExchange<Group: FiniteFieldGroup>: NIOSSHKeyExchangeAlgorithmProtocol {
    static var keyExchangeInitMessageId: UInt8 { 30 }
    static var keyExchangeReplyMessageId: UInt8 { 31 }
    static var keyExchangeAlgorithmNames: [Substring] { [Group.name] }

    private let ourRole: SSHConnectionRole
    private let previousSessionIdentifier: ByteBuffer?
    private let exponent: BigUInt
    private let ourPublic: BigUInt

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        var random = SystemRandomNumberGenerator()
        var exponent = BigUInt.randomInteger(withExactWidth: Group.exponentBits, using: &random)
        if exponent < 2 { exponent = 2 }
        self.exponent = exponent
        ourPublic = BigUInt(2).power(exponent, modulus: Group.prime)
    }

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 520)
        buffer.writeBytes(Self.mpintBody(ourPublic))
        return buffer
    }

    mutating func completeKeyExchangeServerSide(clientKeyExchangeMessage message: ByteBuffer, serverHostKey: NIOSSHPrivateKey,
                                                initialExchangeBytes: inout ByteBuffer, allocator: ByteBufferAllocator,
                                                expectedKeySizes: ExpectedKeySizes) throws -> (KeyExchangeResult, NIOSSHKeyExchangeServerReply) {
        let (result, hash) = try finish(theirs: message, hostKey: serverHostKey.publicKey, exchange: &initialExchangeBytes,
                                        allocator: allocator, sizes: expectedKeySizes)
        var publicKey = allocator.buffer(capacity: 520)
        publicKey.writeBytes(Self.mpintBody(ourPublic))
        return (result, NIOSSHKeyExchangeServerReply(hostKey: serverHostKey.publicKey, publicKey: publicKey,
                                                     signature: try serverHostKey.sign(digest: hash)))
    }

    mutating func receiveServerKeyExchangePayload(serverKeyExchangeMessage: NIOSSHKeyExchangeServerReply, initialExchangeBytes: inout ByteBuffer,
                                                  allocator: ByteBufferAllocator, expectedKeySizes: ExpectedKeySizes) throws -> KeyExchangeResult {
        let (result, hash) = try finish(theirs: serverKeyExchangeMessage.publicKey, hostKey: serverKeyExchangeMessage.hostKey,
                                        exchange: &initialExchangeBytes, allocator: allocator, sizes: expectedKeySizes)
        guard serverKeyExchangeMessage.hostKey.isValidSignature(serverKeyExchangeMessage.signature, for: hash) else {
            throw SSHError.connectFailed("The server's host key did not sign the key exchange.")
        }
        return result
    }

    /// The shared secret, the exchange hash H = HASH(V_C || V_S || I_C || I_S || K_S || e || f || K), and the keys.
    private func finish(theirs bytes: ByteBuffer, hostKey: NIOSSHPublicKey, exchange: inout ByteBuffer, allocator: ByteBufferAllocator,
                        sizes: ExpectedKeySizes) throws -> (KeyExchangeResult, Group.Hash.Digest) {
        let theirs = BigUInt(Data(bytes.readableBytesView))
        // RFC 4253 8: values outside 1 < f < p - 1 would force a known secret.
        guard theirs > 1, theirs < Group.prime - 1 else { throw SSHError.connectFailed("The server sent an invalid key exchange value.") }
        let secret = theirs.power(exponent, modulus: Group.prime)
        guard secret > 1 else { throw SSHError.connectFailed("The key exchange produced an invalid secret.") }
        var hostKeyBlob = ByteBuffer()
        hostKey.write(to: &hostKeyBlob)
        exchange.writeInteger(UInt32(hostKeyBlob.readableBytes))
        exchange.writeBuffer(&hostKeyBlob)
        let (client, server) = Self.isClient(ourRole) ? (ourPublic, theirs) : (theirs, ourPublic)
        for value in [client, server, secret] { Self.writeMPInt(value, to: &exchange) }
        var hasher = Group.Hash()
        hasher.update(data: exchange.readableBytesView)
        let hash = hasher.finalize()
        let sessionID = previousSessionIdentifier ?? { var id = allocator.buffer(capacity: Group.Hash.Digest.byteCount); id.writeContiguousBytes(hash); return id }()

        var prefix = ByteBuffer()
        Self.writeMPInt(secret, to: &prefix)
        prefix.writeContiguousBytes(hash)
        let base = Array(prefix.readableBytesView)
        let id = Array(sessionID.readableBytesView)
        /// RFC 4253 7.2: HASH(K || H || letter || session_id), extended with HASH(K || H || K1 || ...) when too short.
        func derive(_ letter: Character, _ size: Int) -> [UInt8] {
            var key = Array(Group.Hash.hash(data: base + [letter.asciiValue!] + id))
            while key.count < size { key += Array(Group.Hash.hash(data: base + key)) }
            return Array(key.prefix(size))
        }
        let client2server = (iv: derive("A", sizes.ivSize), key: derive("C", sizes.encryptionKeySize), mac: derive("E", sizes.macKeySize))
        let server2client = (iv: derive("B", sizes.ivSize), key: derive("D", sizes.encryptionKeySize), mac: derive("F", sizes.macKeySize))
        let (inbound, outbound) = Self.isClient(ourRole) ? (server2client, client2server) : (client2server, server2client)
        let keys = NIOSSHSessionKeys(initialInboundIV: inbound.iv, initialOutboundIV: outbound.iv,
                                     inboundEncryptionKey: SymmetricKey(data: inbound.key), outboundEncryptionKey: SymmetricKey(data: outbound.key),
                                     inboundMACKey: SymmetricKey(data: inbound.mac), outboundMACKey: SymmetricKey(data: outbound.mac))
        return (KeyExchangeResult(sessionID: sessionID, keys: keys), hash)
    }

    static func isClient(_ role: SSHConnectionRole) -> Bool {
        if case .client = role { return true }
        return false
    }

    /// The bytes of an SSH mpint: big-endian, with a leading zero when the top bit is set.
    static func mpintBody(_ value: BigUInt) -> [UInt8] {
        var bytes = Array(value.serialize())
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    static func writeMPInt(_ value: BigUInt, to buffer: inout ByteBuffer) {
        let body = mpintBody(value)
        buffer.writeInteger(UInt32(body.count))
        buffer.writeBytes(body)
    }
}

/// Which algorithms a connection offers. Modern offers the elliptic-curve key exchanges only. Compatible adds the
/// finite-field ones for older servers and network devices that have nothing newer.
public enum SSHAlgorithmSet: String, CaseIterable, Codable, Sendable {
    case modern, compatible

    var keyExchanges: [NIOSSHKeyExchangeAlgorithmProtocol.Type] {
        switch self {
        case .modern: []
        case .compatible: [FiniteFieldKeyExchange<ModpGroup16SHA512>.self, FiniteFieldKeyExchange<ModpGroup14SHA256>.self]
        }
    }
}
