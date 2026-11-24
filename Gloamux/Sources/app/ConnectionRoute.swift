import Foundation

/// One host on the way to a connected server: a jump host, or the destination last.
struct RouteStop: Equatable, Identifiable {
    /// What a server reported about the connection that reached it, from `$SSH_CONNECTION`.
    struct Seen: Equatable {
        /// The address the connection came from: the host before this one.
        let from: String?
        /// This server's own address on that connection.
        let address: String?

        /// Reads `client-ip client-port server-ip server-port`. A reply that is not that, as from a shell that does not
        /// expand `$SSH_CONNECTION`, leaves both empty.
        init(sshConnection reply: String?) {
            let fields = (reply ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 4, Self.isAddress(fields[0]), Self.isAddress(fields[2]) else { from = nil; address = nil; return }
            from = fields[0]
            address = fields[2]
        }

        /// An IPv4 or IPv6 address, IPv6 possibly with a zone (`fe80::1%en0`), and nothing else.
        static func isAddress(_ text: String) -> Bool {
            guard text.count <= 64 else { return false }
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, text, &v4) == 1 { return true }
            let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
            return text.contains(":") && inet_pton(AF_INET6, address, &v6) == 1
        }
    }

    var id: String { endpoint }
    let name: String
    let endpoint: String
    /// SHA-256 fingerprint of the host key that was trusted for this connection.
    let fingerprint: String?
    /// nil until the route is checked.
    var seen: Seen?

    /// Whether this server saw the connection come from the address the host before it reported for itself.
    func cameFrom(_ previous: RouteStop) -> Bool {
        guard let from = seen?.from, let address = previous.seen?.address else { return false }
        return from == address
    }
}
