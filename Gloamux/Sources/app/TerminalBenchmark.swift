import AppKit
import Foundation
import Terminal

/// `gloamux benchmark`: how fast the terminal parses typical output, how long a full-screen redraw takes, and how long
/// one keystroke's echo takes from bytes to drawn lines. It runs offline, with no window and no connection.
public enum TerminalBenchmark {
    struct Workload {
        let name: String
        let chunk: [UInt8]
    }

    struct Result: Codable {
        let workload: String
        let megabytes: Double
        let seconds: Double
        let megabytesPerSecond: Double
        let redrawMilliseconds: Double
    }

    public static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains("--help") {
            print("usage: gloamux benchmark [--megabytes N] [--columns N] [--rows N] [--json]")
            return 0
        }
        let megabytes = max(1, min(512, Int(value("--megabytes") ?? "") ?? 16))
        let columns = max(20, min(500, Int(value("--columns") ?? "") ?? 160))
        let rows = max(5, min(200, Int(value("--rows") ?? "") ?? 48))
        let results = workloads(columns: columns).map { measure($0, megabytes: megabytes, columns: columns, rows: rows) }
        let echo = keystrokeLatency(columns: columns, rows: rows)
        if arguments.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Report: Codable { let columns: Int; let rows: Int; let results: [Result]; let echoP50: Double; let echoP99: Double }
            let report = Report(columns: columns, rows: rows, results: results, echoP50: echo.p50, echoP99: echo.p99)
            print(String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self))
        } else {
            print("Gloamux terminal benchmark · \(columns)×\(rows) · \(megabytes) MB per workload")
            print(pad("Workload", 22) + pad("MB/s", 10, right: true) + pad("Redraw (ms)", 14, right: true))
            for result in results {
                print(pad(result.workload, 22) + pad(String(format: "%.1f", result.megabytesPerSecond), 10, right: true)
                      + pad(String(format: "%.2f", result.redrawMilliseconds), 14, right: true))
            }
            print(String(format: "Keystroke echo (parse + redraw one line): p50 %.3f ms, p99 %.3f ms", echo.p50, echo.p99))
        }
        return 0
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let space = String(repeating: " ", count: max(0, width - text.count))
        return right ? space + text : text + space
    }

    /// About 64 KB of each kind of output, repeated to the requested size.
    static func workloads(columns: Int) -> [Workload] {
        func repeated(_ make: (Int) -> String) -> [UInt8] {
            var text = "", index = 0
            while text.utf8.count < 65_536 { text += make(index); index += 1 }
            return Array(text.utf8)
        }
        let words = "the quick brown fox jumps over the lazy dog 0123456789 "
        let plain = repeated { _ in String(String(repeating: words, count: columns / words.count + 1).prefix(columns - 1)) + "\r\n" }
        let colored = repeated { index in
            "\u{1b}[1;32mINFO\u{1b}[0m \u{1b}[38;5;\(index % 216 + 16)m[worker-\(index % 8)]\u{1b}[0m request \u{1b}[4m/api/v1/items/\(index)\u{1b}[24m "
                + "took \u{1b}[33m\(index % 997) ms\u{1b}[0m \u{1b}[38;2;120;\(index % 255);200mstatus=200\u{1b}[0m\r\n"
        }
        let cjk = repeated { index in "第\(index)行：終端機效能測試，包含中文、日本語のテキストと 한국어 문자。\r\n" }
        let fullScreen = repeated { index in
            let row = index % 40 + 1
            return "\u{1b}[\(row);1H\u{1b}[2K\u{1b}[7m \(row) \u{1b}[0m cpu \(index % 100)% mem \(index % 64) GiB "
                + String(repeating: "▇", count: index % 40)
        }
        let prompts = repeated { index in
            "\u{1b}]133;A\u{07}user@host:~$ \u{1b}]133;B\u{07}ls -la\r\n\u{1b}]133;C\u{07}"
                + "-rw-r--r--  1 user staff  \(index) Nov 21 12:00 file\(index).txt\r\n\u{1b}]133;D;0\u{07}"
        }
        return [Workload(name: "Plain text", chunk: plain), Workload(name: "Colored logs", chunk: colored),
                Workload(name: "CJK text", chunk: cjk), Workload(name: "Full-screen redraw", chunk: fullScreen),
                Workload(name: "Shell prompts (OSC 133)", chunk: prompts)]
    }

    static func screen(columns: Int, rows: Int) -> TerminalScreen {
        var options = TerminalOptions()
        options.rows = rows; options.cols = columns; options.scrollbackSize = 1000
        return TerminalScreen(options: options)
    }

    private static func measure(_ workload: Workload, megabytes: Int, columns: Int, rows: Int) -> Result {
        let screen = screen(columns: columns, rows: rows)
        let total = megabytes * 1024 * 1024
        var fed = 0
        let start = DispatchTime.now().uptimeNanoseconds
        while fed < total {
            // 4 KB reads, the size a PTY or SSH channel usually delivers.
            var offset = 0
            while offset < workload.chunk.count {
                let end = min(offset + 4096, workload.chunk.count)
                screen.feed(Array(workload.chunk[offset..<end]))
                offset = end
            }
            fed += workload.chunk.count
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let redraw = redrawMilliseconds(screen, frames: 60)
        let size = Double(fed) / 1_048_576
        return Result(workload: workload.name, megabytes: size, seconds: seconds, megabytesPerSecond: size / seconds, redrawMilliseconds: redraw)
    }

    /// Builds every visible line from scratch, as when the window is first drawn or the theme changes.
    static func redrawMilliseconds(_ screen: TerminalScreen, frames: Int) -> Double {
        let ansi = (0..<16).map { NSColor(white: Double($0) / 15, alpha: 1) }
        var elapsed: UInt64 = 0
        for _ in 0..<frames {
            let start = DispatchTime.now().uptimeNanoseconds
            var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: ansi, color: TerminalDisplay.color,
                                                link: { screen.link($0) })
            for row in 0..<screen.rows {
                let cells = (0..<screen.cols).map { screen.cell(row: row, col: $0) }
                _ = renderer.line(cells, cursorColumn: row == screen.cursorRow ? screen.cursorCol : nil, cursorColor: .white)
            }
            elapsed += DispatchTime.now().uptimeNanoseconds - start
        }
        return Double(elapsed) / Double(frames) / 1e6
    }

    /// One typed character echoed back: parse it, then rebuild the cursor's line.
    static func keystrokeLatency(columns: Int, rows: Int, samples: Int = 2000) -> (p50: Double, p99: Double) {
        let screen = screen(columns: columns, rows: rows)
        screen.feed("user@host:~/project$ ")
        let ansi = (0..<16).map { NSColor(white: Double($0) / 15, alpha: 1) }
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: ansi, color: TerminalDisplay.color)
        var times: [Double] = []
        times.reserveCapacity(samples)
        for index in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            screen.feed(index % 60 == 59 ? [0x0D, 0x0A] : [UInt8(ascii: "a") + UInt8(index % 26)])
            let row = screen.cursorRow
            let cells = (0..<screen.cols).map { screen.cell(row: row, col: $0) }
            _ = renderer.line(cells, cursorColumn: screen.cursorCol, cursorColor: .white)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        return (times[times.count / 2], times[min(times.count - 1, times.count * 99 / 100)])
    }
}
