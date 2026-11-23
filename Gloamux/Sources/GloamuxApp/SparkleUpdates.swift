import AppKit
import App
import Sparkle

/// Connects Sparkle to `AppUpdates`. It runs only from an app bundle whose Info.plist names the update feed and the
/// EdDSA public key (set by `package-app.sh`), so `swift run`, tests, and the command line never check for updates.
/// Sparkle asks on the second launch whether to check automatically, then once a day; it verifies each download
/// against the public key before installing it.
@MainActor final class SparkleUpdates: NSObject, AppUpdates.Updater {
    private static var current: SparkleUpdates?
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    static func start() {
        guard current == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        let updates = SparkleUpdates()
        current = updates
        AppUpdates.shared.connect(updates)
    }

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, _ in
            Task { @MainActor in AppUpdates.shared.refresh() }
        }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
