import Darwin
import Foundation
import GloamuxNetwork

/// What a terminal tab talks to: a local shell, a Telnet server, or a serial port.
protocol TerminalTransport: AnyObject {
    func send(_ bytes: [UInt8])
    func resize(rows: Int, columns: Int)
    /// The same, with the text area's size in pixels for programs that size pictures by it. Only a PTY keeps it.
    func resize(rows: Int, columns: Int, pixelWidth: Int, pixelHeight: Int)
    func close()
    /// Stops and restarts reading output while the screen catches up. A serial line or Telnet never outpaces it.
    func setOutputPaused(_ paused: Bool)
}

extension TerminalTransport {
    func setOutputPaused(_ paused: Bool) {}
    func resize(rows: Int, columns: Int, pixelWidth: Int, pixelHeight: Int) { resize(rows: rows, columns: columns) }
}

extension LocalShell: TerminalTransport {}

extension TelnetConnection: TerminalTransport {}

/// A serial line, such as a USB console cable to a switch or a board: `/dev/cu.*` set to raw mode at the chosen speed,
/// data bits, parity, stop bits, and flow control.
final class SerialPort: TerminalTransport {
    struct Settings: Equatable {
        var baud = 9600
        /// Data bits, parity (N, E, or O), and stop bits, such as `8N1`.
        var format = "8N1"
        var flow = Flow.none

        /// RTS/CTS, DTR/DSR, or XON/XOFF.
        enum Flow: String, Codable, CaseIterable { case none, hardware, dtrDsr = "dtr-dsr", software }

        static let speeds = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

        var isValid: Bool { Self.speeds.contains(baud) && Self.parse(format) != nil }

        static func parse(_ format: String) -> (bits: Int, parity: Character, stopBits: Int)? {
            let characters = Array(format.uppercased())
            guard characters.count == 3, let bits = Int(String(characters[0])), (5...8).contains(bits), "NEO".contains(characters[1]),
                  let stop = Int(String(characters[2])), (1...2).contains(stop) else { return nil }
            return (bits, characters[1], stop)
        }
    }

    private let descriptor: Int32
    private let reader: DispatchSourceRead
    private let writes = DispatchQueue(label: "Gloamux.serial-input")
    private var closed = false

    /// Serial devices on this Mac, the call-out (`cu.`) side that does not wait for a carrier.
    static func devices() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
    }

    static func isDevicePath(_ path: String) -> Bool {
        (path.hasPrefix("/dev/cu.") || path.hasPrefix("/dev/tty.") || path.hasPrefix("/dev/ttys")) && !path.contains("..")
            && !path.contains(where: { $0.isWhitespace })
    }

    init(path: String, settings: Settings, output: @escaping @Sendable (Data) -> Void) throws {
        guard Self.isDevicePath(path), let format = Settings.parse(settings.format) else {
            throw WorkspaceError.invalid("Choose a serial device and valid line settings.")
        }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw WorkspaceError.invalid(code == EBUSY ? "The serial device is in use by another app." : code == EACCES ? "Gloamux is not allowed to open the serial device." : "The serial device could not be opened.")
        }
        do {
            try Self.configure(fd, baud: settings.baud, format: format, flow: settings.flow)
        } catch { Darwin.close(fd); throw error }
        descriptor = fd
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "Gloamux.serial-output"))
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { output(Data(buffer.prefix(count))) }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) { self.reader.cancel(); output(Data()) }
        }
        reader.setCancelHandler { Darwin.close(fd) }
        reader.resume()
    }

    private static func configure(_ fd: Int32, baud: Int, format: (bits: Int, parity: Character, stopBits: Int), flow: Settings.Flow) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { throw WorkspaceError.invalid("The serial device does not accept line settings.") }
        cfmakeraw(&options)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTS_IFLOW | CCTS_OFLOW | CDTR_IFLOW | CDSR_OFLOW)
        options.c_cflag |= tcflag_t(CREAD | CLOCAL)
        switch format.bits {
        case 5: options.c_cflag |= tcflag_t(CS5)
        case 6: options.c_cflag |= tcflag_t(CS6)
        case 7: options.c_cflag |= tcflag_t(CS7)
        default: options.c_cflag |= tcflag_t(CS8)
        }
        if format.parity != "N" { options.c_cflag |= tcflag_t(PARENB) }
        if format.parity == "O" { options.c_cflag |= tcflag_t(PARODD) }
        if format.stopBits == 2 { options.c_cflag |= tcflag_t(CSTOPB) }
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch flow {
        case .hardware: options.c_cflag |= tcflag_t(CRTS_IFLOW | CCTS_OFLOW)
        case .dtrDsr: options.c_cflag |= tcflag_t(CDTR_IFLOW | CDSR_OFLOW)
        case .software: options.c_iflag |= tcflag_t(IXON | IXOFF)
        case .none: break
        }
        // VMIN 1, VTIME 0: a read returns as soon as one byte is there.
        withUnsafeMutableBytes(of: &options.c_cc) { cc in cc[Int(VMIN)] = 1; cc[Int(VTIME)] = 0 }
        cfsetspeed(&options, speed_t(baud))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw WorkspaceError.invalid("The serial device does not support this speed with these settings.")
        }
        tcflush(fd, TCIOFLUSH)
    }

    func send(_ bytes: [UInt8]) {
        let fd = descriptor
        writes.async { [weak self] in
            guard self?.closed == false else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 { offset += written }
                else if errno == EAGAIN || errno == EINTR { usleep(2000) }
                else { return }
            }
        }
    }

    /// A serial line has no window size.
    func resize(rows: Int, columns: Int) {}

    func close() {
        guard !closed else { return }
        closed = true
        reader.cancel()
    }

    deinit { close() }
}
