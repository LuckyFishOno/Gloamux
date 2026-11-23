import Foundation
import Darwin
import SwiftUI

/// Whether saved hosts answer on their SSH port. Each check opens a TCP connection and closes it as soon as it is
/// accepted; nothing is sent and no sign-in is attempted. Sessions through a proxy or a jump host, and container
/// sessions, are not checked: a direct connection would say nothing about the route they take.
@MainActor final class Reachability: ObservableObject {
    static let key = "Gloamux.reachability"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    enum State: Equatable { case checking, reachable, unreachable }

    @Published private(set) var states: [UUID: State] = [:]
    private var checked: [UUID: Date] = [:]
    /// A host is checked again after this long.
    static let interval: TimeInterval = 90
    static let concurrency = 6
    static let timeout: TimeInterval = 3

    static func checkable(_ node: SessionTreeNode) -> SavedConnection? {
        guard let connection = node.connection, connection.proxyHost == nil, connection.jumpSessionID == nil else { return nil }
        return connection
    }

    /// Checks the given sessions that are due, a few at a time.
    func refresh(_ nodes: [SessionTreeNode]) async {
        guard Self.enabled else { states = [:]; checked = [:]; return }
        let now = Date()
        let due = nodes.compactMap { node -> (UUID, String, Int)? in
            guard let connection = Self.checkable(node), now.timeIntervalSince(checked[node.id] ?? .distantPast) >= Self.interval else { return nil }
            return (node.id, connection.host, connection.port)
        }.prefix(200)
        guard !due.isEmpty else { return }
        for (id, _, _) in due where states[id] == nil { states[id] = .checking }
        await withTaskGroup(of: (UUID, Bool).self) { group in
            var pending = Array(due).makeIterator()
            for _ in 0..<Self.concurrency {
                guard let (id, host, port) = pending.next() else { break }
                group.addTask { (id, await Self.probe(host: host, port: port, timeout: Self.timeout)) }
            }
            while let (id, reachable) = await group.next() {
                states[id] = reachable ? .reachable : .unreachable
                checked[id] = Date()
                if let (id, host, port) = pending.next() {
                    group.addTask { (id, await Self.probe(host: host, port: port, timeout: Self.timeout)) }
                }
            }
        }
    }

    /// Forgets a result, so the next refresh checks that session again (after its settings change, say).
    func invalidate(_ id: UUID) { checked[id] = nil }

    /// Resolves `host` and tries each address with a non-blocking connect until one is accepted or time runs out.
    /// (The package's own Network module shadows Apple's, so this uses sockets directly.)
    nonisolated static func probe(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard (1...65535).contains(port), !host.isEmpty else { return false }
        return await Task.detached(priority: .utility) { connects(host: host, port: port, timeout: timeout) }.value
    }

    nonisolated private static func connects(host: String, port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            current = info.pointee.ai_next
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
            if connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return true }
            guard errno == EINPROGRESS else { continue }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) == 1 else { continue }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0 { return true }
        }
        return false
    }
}

/// A small dot after a saved session's name: green when its SSH port answered, red when it did not.
struct ReachabilityDot: View {
    @ObservedObject var monitor: Reachability
    let id: UUID

    var body: some View {
        switch monitor.states[id] {
        // The color is backed by the tooltip and by a VoiceOver label, so the state never rests on color alone.
        case .reachable?:
            Circle().fill(Color.green.opacity(0.85)).frame(width: 6, height: 6).help(T("The SSH port answered"))
                .accessibilityLabel(T("The SSH port answered"))
        case .unreachable?:
            Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6).help(T("The SSH port did not answer"))
                .accessibilityLabel(T("The SSH port did not answer"))
        case .checking?:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6).help(T("Checking…"))
                .accessibilityLabel(T("Checking…"))
        case nil:
            EmptyView()
        }
    }
}
