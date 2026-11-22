import SwiftUI
import AppKit

/// A small ⓘ-style "!" button that shows an explanation in a popover, in place of a paragraph of fine print.
///
/// The button and popover are plain AppKit. A SwiftUI `.popover` re-evaluates the views around it as it opens, which
/// in a window full of terminals and forms drops frames; an `NSPopover` with a laid-out text field opens at once and
/// animates at the display's frame rate.
struct InfoButton: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        InfoPopoverButton(text: text)
            .frame(width: 16, height: 16)
            .accessibilityElement()
            .accessibilityLabel(T("About this setting"))
            .accessibilityHint(text)
            .accessibilityAddTraits(.isButton)
    }
}

private struct InfoPopoverButton: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> InfoButtonView { InfoButtonView(text: text) }
    func updateNSView(_ view: InfoButtonView, context: Context) { view.text = text }
}

final class InfoButtonView: NSButton {
    var text: String { didSet { if text != oldValue { popover = nil } } }
    private var popover: NSPopover?

    init(text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        refusesFirstResponder = true
        setAccessibilityElement(false)
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { fatalError("InfoButtonView is created in code.") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    @objc private func toggle() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: isFlipped ? .maxY : .minY)
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
        popover.animates = true
        return popover
    }
}
