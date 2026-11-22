import Darwin
import Foundation

/// Ctrl-C and SIGTERM for long CLI work: the work is cancelled so its cleanup runs, and the command exits with 130.
/// If the work has not stopped after three seconds, the command removes the local partial file and exits anyway.
@MainActor enum Interruption {
    /// A local temporary file to remove if the command has to stop before the work's own cleanup runs.
    nonisolated(unsafe) static var partial: URL?

    private struct Box<Value>: @unchecked Sendable { let value: Value }

    static func run<Value>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let task = Task { @MainActor in Box(value: try await work()) }
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                task.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        if let partial { try? FileManager.default.removeItem(at: partial) }
                        ProductCLI.writeError("Cancelled.")
                        exit(130)
                    }
                }
            }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        do {
            let result = try await task.value.value
            if task.isCancelled { throw CancellationError() }
            return result
        } catch {
            if task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
