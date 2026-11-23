import Foundation
import NIOCore

/// The file operations the file browser, the transfer queue, and Quick Look need, whatever the protocol: SFTP, SCP
/// over SSH for servers without an SFTP subsystem, or FTP and FTPS.
public protocol RemoteFileSystem: Actor {
    /// The protocol, as shown in the interface: `SFTP`, `SCP`, `FTP`, or `FTPS`.
    nonisolated var protocolName: String { get }
    func readDirectory(_ path: String) async throws -> (path: String, entries: [RemoteEntry])
    func download(remotePath: String, to localURL: URL, progress: ProgressHandler?) async throws
    func upload(localURL: URL, to remotePath: String, progress: ProgressHandler?) async throws
    /// Attributes of a remote path, following links; nil when it does not exist.
    func entry(at path: String) async throws -> RemoteEntry?
    func resolve(_ path: String) async throws -> String
    func makeDirectory(_ path: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func rename(from: String, to: String) async throws
    func replace(from: String, to: String) async throws
    /// Sets the permission bits (`0o7777`) of a remote file or folder.
    func setPermissions(_ path: String, mode: UInt32) async throws
    /// Whether a copy can continue from where an earlier one stopped.
    func canResume() async -> Bool
    /// Appends `remotePath` from byte `offset` to `localURL`, which already holds the first `offset` bytes. Progress
    /// counts those bytes too.
    func resumeDownload(remotePath: String, to localURL: URL, offset: UInt64, progress: ProgressHandler?) async throws
    /// Continues writing `localURL` from byte `offset` to `remotePath`, which already holds the first `offset` bytes.
    func resumeUpload(localURL: URL, to remotePath: String, offset: UInt64, progress: ProgressHandler?) async throws
    /// False once the connection is gone, so a new one is needed before trying again.
    nonisolated var isOpen: Bool { get }
    func close() async throws
}

extension RemoteFileSystem {
    public func replace(from: String, to: String) async throws { try await rename(from: from, to: to) }
    /// Moves a finished temporary upload to `destination`. A file already there is swapped out in one step with
    /// `replace` and is never deleted first, so a refused or broken move leaves it as it was. A server that cannot
    /// replace in one step refuses the overwrite instead.
    public func commitUpload(_ partial: String, to destination: String, replacing: Bool) async throws {
        if replacing { try await replace(from: partial, to: destination) } else { try await rename(from: partial, to: destination) }
    }
    public func listDirectory(_ path: String) async throws -> [RemoteEntry] { try await readDirectory(path).entries }
    public func download(remotePath: String, to localURL: URL) async throws { try await download(remotePath: remotePath, to: localURL, progress: nil) }
    public func upload(localURL: URL, to remotePath: String) async throws { try await upload(localURL: localURL, to: remotePath, progress: nil) }
}

extension SFTPTransfer: RemoteFileSystem {
    public nonisolated var protocolName: String { "SFTP" }
}

/// The octal digits `chmod` takes, such as `755`.
func octalMode(_ mode: UInt32) -> String { String(mode & 0o7777, radix: 8) }

/// Bytes arriving from a connection, read as lines, single bytes, or counted runs by one reader at a time.
final class ByteQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var head = 0
    private var ended = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?

    private var available: Int { buffer.count - head }

    func push(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if head > 65536 && head * 2 > buffer.count { buffer.removeFirst(head); head = 0 }
        buffer += bytes
        let waiting = waiter; waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    func finish(_ error: Error? = nil) {
        lock.lock()
        if !ended { ended = true; failure = error }
        let waiting = waiter; waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    /// Waits until bytes arrive, the stream ends, or the task is cancelled.
    private func wait() async throws {
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if available > 0 || ended || Task.isCancelled { lock.unlock(); continuation.resume() }
                else { waiter = continuation; lock.unlock() }
            }
        } onCancel: {
            lock.lock(); let waiting = waiter; waiter = nil; lock.unlock()
            waiting?.resume()
        }
        try Task.checkCancellation()
    }

    private enum Poll<T> { case ready(T), wait }

    /// Up to `maximum` bytes; empty at the end of the stream.
    func read(upTo maximum: Int) async throws -> [UInt8] {
        while true {
            let poll: Poll<[UInt8]> = try lock.withLock {
                if available > 0 {
                    let count = min(maximum, available)
                    defer { head += count }
                    return .ready(Array(buffer[head..<(head + count)]))
                }
                if ended { if let failure { throw failure }; return .ready([]) }
                return .wait
            }
            if case .ready(let bytes) = poll { return bytes }
            try await wait()
        }
    }

    func readByte() async throws -> UInt8? { try await read(upTo: 1).first }

    func readExactly(_ count: Int) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            let chunk = try await read(upTo: count - bytes.count)
            if chunk.isEmpty { throw TransferError.remoteError("The connection closed early.") }
            bytes += chunk
        }
        return bytes
    }

    /// One line without its line ending; nil at the end of the stream. Lines longer than `limit` are refused.
    func readLine(limit: Int = 16384) async throws -> String? {
        while true {
            let poll: Poll<[UInt8]?> = try lock.withLock {
                if let newline = buffer[head...].firstIndex(of: 0x0A) {
                    defer { head = newline + 1 }
                    return .ready(Array(buffer[head..<newline]))
                }
                if available > limit { throw TransferError.remoteError("The server sent a line that is too long.") }
                if ended {
                    if let failure { throw failure }
                    defer { head = buffer.count }
                    return .ready(available == 0 ? nil : Array(buffer[head...]))
                }
                return .wait
            }
            if case .ready(let line) = poll {
                guard var line else { return nil }
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            try await wait()
        }
    }
}

/// Parses `ls -ln` and Unix-style FTP `LIST` lines.
enum UnixListing {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func parse(_ line: String, now: Date = Date()) -> RemoteEntry? {
        let characters = Array(line)
        // Fields with their positions, so a name keeps its own spacing.
        var fields: [(String, Int)] = []
        var index = 0
        while index < characters.count && fields.count < 9 {
            while index < characters.count && characters[index] == " " { index += 1 }
            guard index < characters.count else { break }
            if fields.count == 8 { fields.append((String(characters[index...]), index)); break }
            let start = index
            while index < characters.count && characters[index] != " " { index += 1 }
            fields.append((String(characters[start..<index]), start))
        }
        guard let mode = fields.first?.0, mode.count >= 10, let type = mode.first, "-dlcbps".contains(type) else { return nil }
        let parts = fields.map(\.0)
        // Device files show "major, minor" where the size goes.
        if parts.count > 4, parts[4].hasSuffix(",") {
            let device = line.replacingOccurrences(of: #"^(\S+\s+\S+\s+\S+\s+\S+\s+)\d+,\s*\d+"#, with: "$1" + "0", options: .regularExpression)
            guard device != line else { return nil }
            return parse(device, now: now).map { var entry = $0; entry.size = nil; return entry }
        }
        guard parts.count == 9, let size = UInt64(parts[4]), let month = months.firstIndex(of: parts[5]), let day = Int(parts[6]) else { return nil }
        var name = parts[8]
        if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let permissions = bits(mode)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents(month: month + 1, day: day)
        let clock = parts[7]
        if clock.contains(":") {
            let time = clock.split(separator: ":").compactMap { Int($0) }
            guard time.count == 2 else { return nil }
            components.hour = time[0]; components.minute = time[1]
            // A time instead of a year means within the last six months.
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86400 * 2) { components.year! -= 1 }
        } else {
            components.year = Int(clock)
        }
        return RemoteEntry(name: name, size: size, isDirectory: type == "d", permissions: permissions, modified: calendar.date(from: components))
    }

    static func bits(_ mode: String) -> UInt32 {
        let characters = Array(mode)
        var value: UInt32
        switch characters[0] {
        case "d": value = 0o040000
        case "l": value = 0o120000
        case "c": value = 0o020000
        case "b": value = 0o060000
        case "p": value = 0o010000
        case "s": value = 0o140000
        default: value = 0o100000
        }
        let flags: [(Int, Character, UInt32)] = [(1, "r", 0o400), (2, "w", 0o200), (4, "r", 0o40), (5, "w", 0o20), (7, "r", 0o4), (8, "w", 0o2)]
        for (position, letter, bit) in flags where characters[position] == letter { value |= bit }
        for (position, bit, special) in [(3, UInt32(0o100), UInt32(0o4000)), (6, 0o10, 0o2000), (9, 0o1, 0o1000)] {
            switch characters[position] {
            case "x", "t": value |= bit; if characters[position] == "t" { value |= special }
            case "s": value |= bit | special
            case "S", "T": value |= special
            default: break
            }
        }
        return value
    }
}

/// Paths and file names for a remote command or protocol line: no line breaks or NUL.
func checkedPath(_ path: String) throws -> String {
    guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
        throw TransferError.remoteError("This name cannot be used on the server.")
    }
    return path
}
