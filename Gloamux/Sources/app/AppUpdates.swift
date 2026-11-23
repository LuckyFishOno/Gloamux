import Foundation

/// In-app updates, as the menu and Settings see them. The app executable connects Sparkle through `Updater`, so this
/// module and its tests do not link Sparkle. Without an updater (`swift run`, tests, or a bundle without a feed and
/// key), the menu item and the setting are hidden.
@MainActor public final class AppUpdates: ObservableObject {
    @MainActor public protocol Updater: AnyObject {
        var canCheckForUpdates: Bool { get }
        var automaticallyChecksForUpdates: Bool { get set }
        func checkForUpdates()
    }

    public static let shared = AppUpdates()

    @Published public private(set) var isAvailable = false
    /// False while a check or an update is already under way.
    @Published public private(set) var canCheck = false
    private var updater: Updater?

    public init() {}

    public func connect(_ updater: Updater) {
        self.updater = updater
        isAvailable = true
        refresh()
    }

    /// Picks up the updater's state, after a check starts or ends.
    public func refresh() {
        canCheck = updater?.canCheckForUpdates ?? false
        objectWillChange.send()
    }

    public func check() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
        refresh()
    }

    /// Whether Gloamux looks for a new version once a day. Sparkle asks the first time; this changes the answer.
    public var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
}

import SwiftUI

/// Gloamux › Check for Updates, under About Gloamux, when the app can update itself.
public struct CheckForUpdatesCommand: View {
    @ObservedObject private var updates = AppUpdates.shared
    public init() {}
    public var body: some View {
        if updates.isAvailable {
            Button(T("Check for Updates")) { updates.check() }
                .disabled(!updates.canCheck)
        }
    }
}
