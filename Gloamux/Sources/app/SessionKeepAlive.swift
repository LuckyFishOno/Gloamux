import AppKit
import Foundation
import Ssh

/// Keeping SSH sessions alive: a check while idle, reconnecting after a lost connection, and a check after the Mac wakes.
extension WorkspaceModel {
    /// Every `TerminalPreferences.keepAliveInterval` seconds without output, asks the server for one round trip. A
    /// server that does not answer is treated as gone, and the session ends as lost.
    func startKeepAlive(_ tab: SessionTab, session: SSHSession, epoch: UUID) {
        tab.keepAliveTask?.cancel()
        tab.keepAliveTask = Task { @MainActor [weak tab] in
            var lastRevision = -1
            while !Task.isCancelled {
                let interval = TerminalPreferences.keepAliveInterval
                try? await Task.sleep(for: .seconds(interval > 0 ? interval : 30))
                guard let tab, !Task.isCancelled, tab.epoch == epoch, tab.connected else { return }
                guard interval > 0 else { continue }
                // Output arrived since the last check: the connection is clearly working.
                if tab.screenRevision != lastRevision { lastRevision = tab.screenRevision; continue }
                _ = await session.checkAlive(timeoutSeconds: 15)
            }
        }
    }

    /// After a lost connection, a saved session connects again by itself: after 2, 5, 10, 30, then 60 seconds.
    func scheduleReconnect(_ tab: SessionTab) {
        guard TerminalPreferences.reconnects, !tab.isLocal, tab.transportLost, tab.savedSessionID != nil,
              tabs.contains(where: { $0.id == tab.id }) || sessionWindows[tab.id] != nil else { return }
        if let id = tab.savedSessionID, sessionTree.node(id)?.connection?.asksEachConnection == true { return }
        let delays = Self.reconnectDelays
        guard tab.reconnectAttempts < delays.count else {
            tab.feed(T("Stopped reconnecting. Use Reconnect to try again.") + "\n")
            return
        }
        let delay = delays[tab.reconnectAttempts]
        tab.reconnectAttempts += 1
        tab.feed(String(format: T("Reconnecting in %d seconds…"), delay) + "\n")
        tab.status = "Reconnecting"
        tab.reconnectTask?.cancel()
        tab.reconnectTask = Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let tab, tab.transportLost, !tab.connected, !tab.busy else { return }
            await self.connect(tab)
            if !tab.connected, tab.hostKeyChange == nil, tab.hostKeyPrompt == nil, !tab.loginCancelled {
                tab.transportLost = true
                self.scheduleReconnect(tab)
            }
        }
    }

    static let reconnectDelays = [2, 5, 10, 30, 60]

    /// After sleep, a connection may be dead without either side knowing. Checks each one at once so a dead one is
    /// reconnected now rather than after the next keystroke times out.
    func checkSessionsAfterWake() {
        for tab in allTabs where tab.connected && !tab.isLocal {
            guard let session = tab.session else { continue }
            Task { _ = await session.checkAlive(timeoutSeconds: 8) }
        }
    }

    /// Workspace tabs and sessions in their own windows.
    var allTabs: [SessionTab] { tabs + sessionWindows.values.map(\.tab).filter { tab in !tabs.contains { $0.id == tab.id } } }

    func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSessionsAfterWake() }
        }
    }
}
