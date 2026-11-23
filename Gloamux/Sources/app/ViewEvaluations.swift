import Foundation

/// Counts how often chosen view bodies run, so tests can check that terminal output does not re-evaluate views that
/// do not show it. Counting happens only in debug builds; in a release build `note` does nothing.
enum ViewEvaluations {
    #if DEBUG
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    static func note(_ name: String) { counts[name, default: 0] += 1 }
    #else
    @inline(__always) static func note(_ name: String) {}
    #endif
}
