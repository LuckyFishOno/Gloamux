import AppKit
import Carbon.HIToolbox

/// The key that shows and hides the dropdown window from any app.
public enum DropdownHotkey: String, CaseIterable, Sendable {
    case off
    case controlGrave = "control-grave"
    case optionGrave = "option-grave"
    case optionSpace = "option-space"
    case f12

    /// The key as menus show it; Off is translated by the caller.
    var symbol: String {
        switch self {
        case .off: "Off"
        case .controlGrave: "⌃`"
        case .optionGrave: "⌥`"
        case .optionSpace: "⌥Space"
        case .f12: "F12"
        }
    }

    fileprivate var carbonKey: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: nil
        case .controlGrave: (UInt32(kVK_ANSI_Grave), UInt32(controlKey))
        case .optionGrave: (UInt32(kVK_ANSI_Grave), UInt32(optionKey))
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .f12: (UInt32(kVK_F12), 0)
        }
    }
}

/// One workspace window that a global hotkey slides down from the top of the screen under the pointer and hides
/// again. The first press opens it; it keeps its tabs while hidden, and closing it like any window ends them.
/// The hotkey works while Gloamux is running and needs no Accessibility permission.
@MainActor public final class DropdownWindow: ObservableObject {
    public static let shared = DropdownWindow()
    public static let hotkeyKey = "dropdownHotkey"

    /// Opens a new workspace window. The app sets it once the workspace has loaded.
    public var openWindow: (() -> Void)?
    /// True when another app already uses the chosen key, so pressing it does nothing in Gloamux.
    @Published public private(set) var registrationFailed = false
    public private(set) var isShown = false
    private weak var window: NSWindow?
    private var awaitingWindow = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered = DropdownHotkey.off
    private var observer: NSObjectProtocol?
    /// The height the user last left it at; half the screen before that.
    private var height: CGFloat?

    public static var hotkey: DropdownHotkey {
        DropdownHotkey(rawValue: UserDefaults.standard.string(forKey: hotkeyKey) ?? "") ?? .off
    }

    /// Registers the chosen key, and again whenever Settings or `gloamux settings` changes it.
    public func start() {
        guard observer == nil else { return }
        update()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DropdownWindow.shared.update() }
        }
    }

    private func update() {
        let wanted = Self.hotkey
        guard wanted != registered else { return }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = wanted
        registrationFailed = false
        guard let key = wanted.carbonKey else { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Carbon calls this on the main thread.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { DropdownWindow.shared.toggle() }
                return noErr
            }, 1, &event, nil, &handler)
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: OSType(0x476C_6D78), id: 1),
                                         GetApplicationEventTarget(), 0, &reference)
        if status == noErr { hotKey = reference } else { registrationFailed = true }
    }

    /// Shows the window in front, or hides it when it already is. Returns whether it is shown afterwards.
    @discardableResult public func toggle() -> Bool {
        guard let window else {
            guard let openWindow else { return false }
            awaitingWindow = true
            openWindow()
            return true
        }
        if window.isVisible, window.isKeyWindow, NSApp.isActive { hide(window) } else { show(window) }
        return isShown
    }

    /// Takes the next workspace window to open after a press that found none.
    public func adopt(_ window: NSWindow) {
        guard awaitingWindow, self.window == nil else { return }
        awaitingWindow = false
        self.window = window
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = .floating
        show(window)
    }

    /// Forgets a window that closed, so the next press opens a new one.
    public func closed(_ window: NSWindow) {
        guard self.window === window else { return }
        self.window = nil
        isShown = false
    }

    private func show(_ window: NSWindow) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let height = min(area.height, max(240, height ?? (area.height / 2).rounded()))
        let frame = NSRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        window.alphaValue = 0
        window.setFrame(frame.offsetBy(dx: 0, dy: min(60, height / 4)), display: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        isShown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func hide(_ window: NSWindow) {
        height = window.frame.height
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.alphaValue = 1
                // With no other Gloamux window left on screen, the app that was in front before comes back.
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.hide(nil) }
            }
        })
    }
}
