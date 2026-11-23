import SwiftUI
import AppKit
import QuartzCore

/// A small ⓘ-style "!" button that shows an explanation in a popover, in place of a paragraph of fine print.
///
/// The AppKit button shows its pre-laid-out explanation without invalidating the surrounding SwiftUI form.
struct InfoButton: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        // The AppKit button is the accessibility element itself, so VoiceOver's press opens the popover.
        InfoPopoverButton(text: text)
            .frame(width: 16, height: 16)
    }
}

private struct InfoPopoverButton: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> InfoButtonView { InfoButtonView(text: text) }
    func updateNSView(_ view: InfoButtonView, context: Context) { view.text = text }
    static func dismantleNSView(_ view: InfoButtonView, coordinator: ()) { view.resetPopover() }
}

final class InfoButtonView: NSButton, NSPopoverDelegate {
    private struct Fade {
        let window: NSWindow
        let timer: Timer
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let from: CGFloat
        let to: CGFloat
    }

    var text: String {
        didSet {
            guard text != oldValue else { return }
            resetPopover()
            setAccessibilityHelp(text)
        }
    }
    private var popover: NSPopover?
    private var fade: Fade?

    init(text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        refusesFirstResponder = true
        setAccessibilityLabel(T("About this setting"))
        setAccessibilityHelp(text)
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { fatalError("InfoButtonView is created in code.") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    @objc private func toggle() {
        guard window != nil else { return }
        if let popover, popover.isShown { popover.performClose(nil); return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: isFlipped ? .maxY : .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              let window = popover.contentViewController?.view.window else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.alphaValue = 1
            return
        }
        window.alphaValue = 0
        beginFade(window, to: 1, duration: 0.16)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let window = popover.contentViewController?.view.window,
              window.alphaValue > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return true }
        if fade?.to != 0 { beginFade(window, to: 0, duration: 0.12) }
        return false
    }

    func popoverDidClose(_ notification: Notification) { stopFade() }

    private func beginFade(_ window: NSWindow, to opacity: CGFloat, duration: CFTimeInterval) {
        stopFade()
        let refreshRate = window.screen?.maximumFramesPerSecond ?? 60
        let timer = Timer(timeInterval: 1.0 / Double(max(1, refreshRate)), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.advanceFade() }
        }
        fade = Fade(window: window, timer: timer, start: CACurrentMediaTime(), duration: duration,
                    from: window.alphaValue, to: opacity)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceFade() {
        guard let fade else { return }
        let progress = (CACurrentMediaTime() - fade.start) / fade.duration
        if progress >= 1 {
            finishFade()
        } else {
            let eased = fade.to == 1 ? 1 - (1 - progress) * (1 - progress) : progress
            fade.window.alphaValue = fade.from + (fade.to - fade.from) * eased
        }
    }

    private func finishFade() {
        guard let fade else { return }
        stopFade()
        fade.window.alphaValue = fade.to
        if fade.to == 0 { popover?.close() }
    }

    private func stopFade() {
        fade?.timer.invalidate()
        fade = nil
    }

    fileprivate func resetPopover() {
        stopFade()
        popover?.close()
        popover = nil
    }

    /// Lays the text out once, at a fixed width, so showing it only has to draw.
    private func makePopover() -> NSPopover {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.preferredFont(forTextStyle: .callout)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 280
        let size = label.sizeThatFits(NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280 + 24, height: ceil(size.height) + 24))
        label.frame = NSRect(x: 12, y: 12, width: 280, height: ceil(size.height))
        content.addSubview(label)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.behavior = .transient
        popover.delegate = self
        // Keep the window at its final size and animate only its opacity.
        popover.animates = false
        return popover
    }
}

extension View {
    /// Gives a borderless icon button at least the 20 pt hit area macOS asks for, without changing how it looks.
    /// Small glyphs (an arrow, a close mark) otherwise only answer clicks on their few visible pixels.
    func iconHitArea() -> some View { frame(minWidth: 20, minHeight: 20).contentShape(Rectangle()) }
}
