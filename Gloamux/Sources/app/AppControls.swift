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

    var body: some View {
        LabeledContent {
            Menu {
                Picker(selection: $selection) { content } label: { Text(title) }
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Text(current).lineLimit(1).truncationMode(.tail)
                    if fills { Spacer(minLength: 4) }
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(AppButtonStyle(kind: .menu))
            .fixedSize(horizontal: !fills, vertical: true)
            .accessibilityLabel(title)
            .accessibilityValue(current)
        } label: {
            label
        }
    }
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
