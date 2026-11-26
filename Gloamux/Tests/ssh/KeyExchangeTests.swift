import XCTest
@testable import Ssh
import BigInt

/// Compatible sessions sign in to servers that offer only finite-field Diffie-Hellman; Modern ones do not offer it.
final class KeyExchangeTests: XCTestCase {
    private func signIn(_ server: LocalSSHD, key: URL, algorithms: SSHAlgorithmSet) async throws -> String {
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user,
                                                                                   algorithms: algorithms),
                                                   credential: SSHCredential.privateKeyFile(at: key, passphrase: ""), connectTimeoutSeconds: 15)
        defer { Task { try? await session.close() } }
        return try await session.runCommand("echo signed-in").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testFiniteFieldGroupsSignInOnlyWhenCompatible() async throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        for kex in ["diffie-hellman-group14-sha256", "diffie-hellman-group16-sha512"] {
            // Each cipher family, so the derived keys of every size are checked, MAC keys longer than the hash included.
            for cipher in ["aes256-gcm@openssh.com", "aes128-ctr"] {
                let server = try LocalSSHD(extraConfig: "KexAlgorithms \(kex)\nCiphers \(cipher)\nMACs hmac-sha2-512")
                defer { server.stop() }
                let key = try server.addKey("login", type: "ed25519")
                let output = try await signIn(server, key: key, algorithms: .compatible)
                XCTAssertEqual(output, "signed-in", "\(kex) \(cipher)")
                do { _ = try await signIn(server, key: key, algorithms: .modern); XCTFail("Modern offered \(kex)") } catch {}
            }
        }
    }

    func testMPIntEncodingAndGroupPrimes() {
        XCTAssertEqual(FiniteFieldKeyExchange<ModpGroup14SHA256>.mpintBody(0x7f), [0x7f])
        XCTAssertEqual(FiniteFieldKeyExchange<ModpGroup14SHA256>.mpintBody(0x80), [0x00, 0x80])
        XCTAssertEqual(ModpGroup14SHA256.prime.bitWidth, 2048)
        XCTAssertEqual(ModpGroup16SHA512.prime.bitWidth, 4096)
        // RFC 3526 primes begin and end with 64 one bits.
        for prime in [ModpGroup14SHA256.prime, ModpGroup16SHA512.prime] {
            XCTAssertEqual(prime & ((1 << 64) - 1), (1 << 64) - 1)
            XCTAssertEqual(prime >> (prime.bitWidth - 64), (1 << 64) - 1)
        }
    }
}
