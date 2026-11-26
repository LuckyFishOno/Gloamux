import SwiftUI

/// Gloamux's buttons: a rounded rectangle rather than macOS 26's capsule, one height everywhere, and text that follows
/// the app's text size. macOS draws its own bordered buttons and pop-up menus at a fixed font, so they stayed small
/// when the app's text grew. Set for every window by `appTextSize()`; `.prominent` is the main action in the accent,
/// and `.tinted`, an accent fill and outline under regular text, is a second action beside it, such as Save next to
/// Connect: clearly not a Cancel, and still a step below the main action.
struct AppButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, tinted, menu }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var app: AppButtonStyle { AppButtonStyle() }
    static var appProminent: AppButtonStyle { AppButtonStyle(kind: .prominent) }
    static var appTinted: AppButtonStyle { AppButtonStyle(kind: .tinted) }
}

private struct AppButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AppButtonStyle.Kind
    @Environment(\.appTextScale) private var scale
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: (small ? 5 : 6) * min(scale, 1.5), style: .continuous)
        let prominent = kind == .prominent, tinted = kind == .tinted
        configuration.label
            .appFont(.system(size: small ? 11 : 12, weight: prominent || tinted ? .medium : .regular))
            .lineLimit(1)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) :
                                configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, ((small ? 8 : 11) * scale).rounded())
            .frame(minHeight: ((small ? 20 : 24) * scale).rounded())
            .background {
                if prominent { shape.fill(.tint) }
                else if tinted {
                    shape.fill(.tint.opacity(hovering && isEnabled ? 0.42 : 0.32))
                        .overlay { shape.strokeBorder(.tint.opacity(0.85), lineWidth: 1) }
                }
                else { shape.fill(Color.primary.opacity(hovering && isEnabled ? 0.12 : 0.08)) }
            }
            .overlay { shape.fill(Color.black.opacity(configuration.isPressed ? 0.14 : prominent && hovering && isEnabled ? 0.05 : 0)) }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

/// A pop-up menu that shows its choice in the app's text size, where a SwiftUI `Picker` stays at macOS's fixed font.
/// The choices are the same as a picker's, tagged views, listed with a check mark in a native menu. `current` is the
/// text of the chosen one. `fills` stretches it to the width it is given, as a pop-up button in a form row does.
struct AppPicker<Value: Hashable, Content: View, Title: View>: View {
    private let title: String
    @Binding private var selection: Value
    private let current: String
    private let fills: Bool
    private let content: Content
    private let label: Title

    init(_ title: String, selection: Binding<Value>, current: String, fills: Bool = false,
         @ViewBuilder content: () -> Content) where Title == Text {
        self.init(title: title, selection: selection, current: current, fills: fills, content: content) { Text(title) }
    }

    init(title: String, selection: Binding<Value>, current: String, fills: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Title) {
        self.title = title
        self._selection = selection
        self.current = current
        self.fills = fills
        self.content = content()
        self.label = label()
    }

    @State private var anchor = MenuAnchor.Box()

    var body: some View {
        LabeledContent {
            Group {
                if #available(macOS 15, *) {
                    // A plain button that opens the menu once it is released. A SwiftUI Menu opens on the press, and a
                    // press on its text could close the menu again at once.
                    Button(action: showMenu) { face }
                        .background(MenuAnchor(box: anchor))
                } else {
                    Menu { choices } label: { face }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .menu))
            .fixedSize(horizontal: !fills, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(current)
        } label: {
            label
        }
    }

    private var choices: some View {
        Picker(selection: $selection) { content } label: { Text(title) }
            .pickerStyle(.inline)
            .labelsHidden()
    }

    private var face: some View {
        HStack(spacing: 6) {
            Text(current).lineLimit(1).truncationMode(.tail)
            if fills { Spacer(minLength: 4) }
            Image(systemName: "chevron.up.chevron.down").imageScale(.small).fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// Opens the choices just below the button, with the current one checked.
    @available(macOS 15, *)
    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSHostingMenu(rootView: choices)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

/// An empty view behind a control, so an AppKit menu can open next to it.
private struct MenuAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box
    func makeNSView(context: Context) -> NSView { let view = NSView(); box.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The buttons at the foot of every Gloamux dialog, so they look and sit the same everywhere: other controls on the
/// leading side, then Cancel and the main action at the trailing edge, at least the same width, the main action last
/// and filled. Escape cancels; Return confirms unless `returnConfirms` is off, as for trusting a host key, where a
/// stray Return must not decide.
struct DialogActions<Extra: View>: View {
    var cancelTitle = T("Cancel")
    let cancel: () -> Void
    let title: String
    var enabled = true
    /// A red main action, for one that replaces or runs something risky.
    var warns = false
    var returnConfirms = true
    var identifier: String?
    let confirm: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 8) {
            extra()
            Spacer(minLength: 12)
            Button(action: cancel) { Text(cancelTitle).frame(minWidth: 64) }
                .buttonStyle(.app).keyboardShortcut(.cancelAction)
            Button(action: confirm) { Text(title).frame(minWidth: 64) }
                .buttonStyle(.appProminent).tint(warns ? .red : nil)
                .keyboardShortcut(returnConfirms ? .defaultAction : nil)
                .disabled(!enabled)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

extension DialogActions where Extra == EmptyView {
    init(cancelTitle: String = T("Cancel"), cancel: @escaping () -> Void, title: String, enabled: Bool = true, warns: Bool = false,
         returnConfirms: Bool = true, identifier: String? = nil, confirm: @escaping () -> Void) {
        self.init(cancelTitle: cancelTitle, cancel: cancel, title: title, enabled: enabled, warns: warns, returnConfirms: returnConfirms,
                  identifier: identifier, confirm: confirm) { EmptyView() }
    }
}
