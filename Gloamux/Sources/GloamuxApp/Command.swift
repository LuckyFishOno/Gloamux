import Foundation
import GloamuxShared

enum FeatureCheckCommand {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--self-test") || arguments.contains("--flow") || arguments.contains("--help")
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Exit code 0 when every feature ran or was reported; 2 when a module's contract pin differs from the plan.
    static func run(_ arguments: [String]) -> Int32 {
        let input = value(after: "--input", in: arguments) ?? ""
        if arguments.contains("--flow") {
            let target = value(after: "--flow", in: arguments) ?? FeatureRegistry.defaultFlow
            guard FeatureRegistry.features.contains(where: { $0.id == target }) else {
                print("GLOAMUX-FLOW " + FeatureRunner.json(["schema": "gloamux/feature-flow@1", "error": "unknown feature \(target)"]))
                return 1
            }
            let results = FeatureRunner.evaluate(FeatureRunner.closure(of: target, in: FeatureRegistry.features), input: input)
            let last = results.last { $0.id == target }
            var report: [String: Any] = ["schema": "gloamux/feature-flow@1", "planId": FeatureRegistry.planId, "flow": target,
                                         "steps": results.map(FeatureRunner.describe), "completed": last?.status == "implemented-ok"]
            if let output = last?.output { report["output"] = output.payload }
            print("GLOAMUX-FLOW " + FeatureRunner.json(report))
            return results.contains { $0.status == "contract-mismatch" } ? 2 : 0
        }
        if arguments.contains("--self-test") {
            let results = FeatureRunner.evaluate(FeatureRegistry.features, input: input)
            print("GLOAMUX-SELF-TEST " + FeatureRunner.json(["schema": "gloamux/feature-self-test@1", "planId": FeatureRegistry.planId,
                "features": results.map(FeatureRunner.describe), "implemented": results.filter { $0.status == "implemented-ok" }.count, "total": results.count]))
            return results.contains { $0.status == "contract-mismatch" } ? 2 : 0
        }
        print("Feature checks for plan \(FeatureRegistry.planId). Options: --self-test [--input TEXT], --flow FEATURE [--input TEXT]. Default flow: \(FeatureRegistry.defaultFlow).")
        return 0
    }
}
