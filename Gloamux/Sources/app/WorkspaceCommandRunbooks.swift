import Foundation

/// `gloamux runbooks`: the Markdown runbooks of the Runbooks window.
extension WorkspaceCommand {
    @MainActor static func runbooks(_ action: String, _ args: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel]) throws -> Any {
        let library = model.runbooks
        library.reload()
        func file(_ name: String) throws -> URL {
            guard let url = library.files.first(where: { $0.lastPathComponent == name || $0.deletingPathExtension().lastPathComponent == name }) else {
                throw WorkspaceError.invalid("No runbook named \(name). Run gloamux runbooks list.")
            }
            return url
        }
        func blocks(_ url: URL) -> [(index: Int, code: String)] {
            library.runbook(url).blocks.compactMap { block in
                if case .code(let index, _, let code) = block { return (index, code) }
                return nil
            }
        }
        switch action {
        case "list":
            try count(args, 0...0)
            return library.files.map { ["name": $0.lastPathComponent, "title": library.runbook($0).title, "blocks": blocks($0).count] as [String: Any] }
        case "show":
            try count(args, 1...1)
            let url = try file(args[0])
            let results = library.results[url.lastPathComponent] ?? [:]
            let dates = ISO8601DateFormatter()
            return ["name": url.lastPathComponent, "title": library.runbook(url).title,
                    "running": library.running.contains(url.lastPathComponent),
                    "blocks": blocks(url).map { block -> [String: Any] in
                        var info: [String: Any] = ["block": block.index + 1, "code": block.code]
                        if let result = results[block.index] {
                            var last: [String: Any] = ["date": dates.string(from: result.date), "destination": result.destination, "sentOnly": result.sentOnly]
                            if let code = result.exitCode { last["exitCode"] = code }
                            if let output = result.output { last["output"] = output }
                            info["last"] = last
                        }
                        return info
                    }]
        case "create":
            try count(args, 1...1)
            let name = args[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw Usage("Enter a runbook name without a slash.") }
            return ["name": try library.create(named: name).lastPathComponent]
        case "import":
            try count(args, 1...1)
            let source = URL(fileURLWithPath: args[0])
            guard args[0].hasPrefix("/"), ["md", "markdown"].contains(source.pathExtension.lowercased()) else {
                throw Usage("Use the absolute path of a Markdown file.")
            }
            return ["name": try library.importFile(source).lastPathComponent]
        case "delete":
            try count(args, 1...1)
            let url = try file(args[0])
            try library.delete(url)
            return ["name": url.lastPathComponent, "movedToTrash": true]
        case "run":
            try count(args, 2...3)
            let url = try file(args[0])
            let (owner, tab) = try tab(args[1], windows)
            var chosen = blocks(url)
            if let raw = args.dropFirst(2).first {
                guard let number = Int(raw), let block = chosen.first(where: { $0.index + 1 == number }) else {
                    throw Usage("Choose a block number from gloamux runbooks show.")
                }
                chosen = [block]
            }
            guard !chosen.isEmpty else { throw WorkspaceError.invalid("The runbook has no shell blocks.") }
            guard tab.terminalReady, !tab.readOnly else { throw WorkspaceError.invalid("The terminal in this tab is not ready.") }
            // A tagged environment that confirms risky commands gets the review in Gloamux instead.
            if let environment = tab.environment, SessionEnvironment.confirming.contains(environment) {
                throw WorkspaceError.invalid("This session is tagged \(environment.rawValue). Run the runbook from Gloamux to review it first.")
            }
            let key = url.lastPathComponent
            guard !library.running.contains(key) else { throw WorkspaceError.invalid("The runbook is already running.") }
            library.running.insert(key)
            owner.reveal(tab: tab.id)
            let terminal = tab.terminalID
            Task {
                for block in chosen {
                    let result = await owner.runBlock(block.code, in: tab, terminal: terminal)
                    library.record(result, block: block.index, in: url)
                    if (result.exitCode ?? 0) != 0 { break }
                }
                library.running.remove(key)
            }
            return ["name": key, "tab": tab.id.uuidString, "blocks": chosen.map { $0.index + 1 }, "status": "running"]
        default: throw Usage("Unknown runbooks operation.")
        }
    }
}
