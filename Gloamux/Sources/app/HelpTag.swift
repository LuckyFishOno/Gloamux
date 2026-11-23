import SwiftUI
import AppKit

/// A help tag that names a control after the pointer rests on it for about a second, as macOS tooltips do.
///
/// SwiftUI's `.help` registers its tag again whenever the view around it redraws. The toolbars redraw with the
/// workspace, which restarts the wait each time, so the name never appeared; nor does `.help` show on a disabled
/// button. An AppKit `toolTip` on a view that lets clicks through is not shown either, as the system shows tooltips
/// only for the view under the pointer. So this view watches the pointer with its own tracking area, which redraws do
/// not reset, and shows the tag in a small panel drawn with the system's tooltip material.
struct HelpTag: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TagView { TagView(text: text) }

    func updateNSView(_ view: TagView, context: Context) {
        if view.text != text { view.text = text }
    }

    /// Clicks go to the control in front of it; the tracking area sees the pointer either way.
    final class TagView: NSView {
        var text: String { didSet { if HelpTagPanel.shared.owner === self { HelpTagPanel.shared.show(text, for: self) } } }
        private var timer: Timer?

        init(text: String) {
            self.text = text
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { fatalError("TagView is created in code.") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { beginHover() }
        override func mouseExited(with event: NSEvent) { endHover() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { endHover() }
        }

        /// Shows the tag after the delay, or at once while another tag was just showing, as when moving along a toolbar.
        func beginHover(delay: TimeInterval = Double(HelpTags.delay) / 1000) {
            timer?.invalidate()
            guard !text.isEmpty else { return }
            if HelpTagPanel.shared.recentlyShown {
                HelpTagPanel.shared.show(text, for: self)
                return
            }
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    HelpTagPanel.shared.show(self.text, for: self)
                }
            }
        }

        func endHover() {
            timer?.invalidate()
            timer = nil
            HelpTagPanel.shared.hide(for: self)
        }
    }
}

public enum HelpTags {
    /// How long the pointer rests before a help tag appears, in milliseconds.
    public static let delay = 1000
}

/// The one panel that shows help tags, below the pointer like the system's tooltips.
@MainActor final class HelpTagPanel {
    static let shared = HelpTagPanel()
    private(set) weak var owner: NSView?
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hiddenAt: Date?
    private var monitor: Any?

    var isShown: Bool { panel?.isVisible == true && owner != nil }
    var shownText: String? { isShown ? label?.stringValue : nil }
    /// A tag was on screen within the last half second.
    var recentlyShown: Bool { isShown || hiddenAt.map { Date().timeIntervalSince($0) < 0.5 } == true }

    func show(_ text: String, for view: NSView, at point: NSPoint = NSEvent.mouseLocation) {
        guard let window = view.window else { return }
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        owner = view
        label.stringValue = text
        panel.appearance = window.effectiveAppearance
        let size = label.fittingSize
        let frameSize = NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 6)
        // Below and slightly right of the pointer, kept on the screen it is on.
        var origin = NSPoint(x: point.x + 2, y: point.y - 22 - frameSize.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? window.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frameSize.width - 4)
            if origin.y < visible.minY + 4 { origin.y = point.y + 18 }
        }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        label.frame = NSRect(x: 6, y: 3, width: ceil(size.width), height: ceil(size.height))
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
        }
        // A click, key press, or scroll puts the tag away, as with the system's tooltips.
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.hide() }
                return event
            }
        }
    }

    /// Hides the tag if `view` is the one it names, or whichever is showing when `view` is nil.
    func hide(for view: NSView? = nil) {
        guard view == nil || owner === view else { return }
        if isShown { hiddenAt = Date() }
        owner = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background
        panel.setAccessibilityElement(false)
        self.panel = panel
        self.label = label
        return panel
    }
}

extension View {
    /// Names the control in a help tag after the pointer rests on it, and to VoiceOver.
    func helpTag(_ text: String) -> some View {
        background(HelpTag(text: text)).accessibilityLabel(text)
    }
}
