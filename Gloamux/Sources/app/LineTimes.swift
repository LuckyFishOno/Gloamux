import AppKit
import Terminal

/// When each line of a terminal last changed, for Terminal › Show timestamps, as in iTerm2. Lines are numbered as
/// absolute lines (lines dropped from the scrollback, plus the scrollback index or screen row), so a line keeps its time
/// as it scrolls. Output marks the lines from where the cursor was to where it ends up.
struct LineTimes {
    private(set) var times: [Int: Date] = [:]

    /// The absolute line the cursor is on.
    static func cursorLine(_ screen: TerminalScreen) -> Int { screen.trimmedLines + screen.scrollback.count + screen.cursorRow }

    /// Marks the lines between two cursor lines as changed at `date`. Lines that left the scrollback are forgotten.
    mutating func touch(from start: Int, to end: Int, at date: Date, screen: TerminalScreen) {
        let first = screen.trimmedLines
        let last = first + screen.scrollback.count + screen.rows - 1
        let low = max(min(start, end), first), high = min(max(start, end), last)
        if low <= high { for line in low...high { times[line] = date } }
        if times.count > 2 * (screen.scrollback.count + screen.rows) + 64 { times = times.filter { $0.key >= first } }
    }

    func time(of line: Int) -> Date? { times[line] }

    /// How a time shows beside its line: the time of day, with the date for another day.
    static func label(_ date: Date, now: Date = Date()) -> String {
        (Calendar.current.isDate(date, inSameDayAs: now) ? today : earlier).string(from: date)
    }
    private static let today: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private static let earlier: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()
}
