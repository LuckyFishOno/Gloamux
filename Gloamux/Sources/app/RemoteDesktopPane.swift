import AppKit
import SwiftUI

struct RemoteDesktopPane: View {
    let model: WorkspaceModel
    let tab: SessionTab
    @ObservedObject var connection: RemoteDesktopSession
    @State private var username = ""
    @State private var password = ""
    @State private var trustError: String?
    @State private var remember = false
    @State private var hasSavedPassword = false
    @AppStorage(RemoteDesktopSession.clipboardKey) private var sharesClipboard = true

    var body: some View {
        VStack(spacing: 0) {
            if connection.phase == .connected {
                ZStack {
                    NativeDesktopView(image: connection.image, send: connection.send, focused: connection.shareClipboard)
                    if connection.image == nil {
                        ProgressView(T("Waiting for the remote desktop…")).padding(18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(T(connection.profile.tool.title)).appFont(.title2.weight(.semibold))
                    if connection.profile.tool == .rdp {
                        TextField(T("Username"), text: $username).frame(width: 280)
                    } else {
                        HStack(spacing: 6) {
                            TextField(T("Username (optional)"), text: $username).frame(width: 280)
                            InfoButton(T("To sign in to a Mac's Screen Sharing, enter the Mac account name and password. Leave it empty to use the VNC password."))
                        }
                    }
                    HStack(spacing: 6) {
                        SecureField(T("Password"), text: $password)
                            .onSubmit(connect).frame(width: 280)
                            .onChange(of: password) { _, value in password = Self.withoutSavedMask(value) }
                            .accessibilityValue(password == Self.savedMask ? T("Saved password") : "")
                        if connection.profile.tool == .vnc, connection.profile.gatewaySessionID == nil {
                            InfoButton(T("This VNC connection does not encrypt traffic."))
                        }
                    }
                    HStack(spacing: 6) {
                        Toggle(T("Share clipboard"), isOn: $sharesClipboard)
                        InfoButton(T("Text you copy on this Mac goes to the remote desktop when you click into it, and text copied there comes back to this Mac."))
                    }
                    HStack(spacing: 6) {
                        Toggle(T("Remember password"), isOn: $remember)
                        if !model.savesWithoutUnlock {
                            InfoButton(T("The password goes into the password vault. While the vault is locked, Gloamux keeps it until it quits and saves it when you unlock the vault."))
                        }
                    }
                    if let error = trustError ?? connection.error {
                        Text(T(error)).appFont(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let fingerprint = connection.pendingFingerprint {
                        Text(T("Verify the RDP server certificate fingerprint before trusting it."))
                        Text(fingerprint).appFont(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button(T("Cancel")) { connection.dismissFingerprint() }
                            Button(T("Trust this certificate")) { trustCertificate() }
                        }
                    } else if connection.phase == .connecting {
                        ProgressView(T("Connecting…"))
                    } else {
                        Button(T("Connect"), action: connect).buttonStyle(.borderedProminent)
                            .disabled(connection.profile.tool == .rdp && username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .disabled(connection.phase == .connecting)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { if let gateway = connection.gatewayTab { GatewayHostKey(model: model, gateway: gateway) } }
        // The desktop size an RDP server is asked for follows this view.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { connection.viewResized(proxy.size) }
                .onChange(of: proxy.size) { _, size in connection.viewResized(size) }
        })
        .onAppear {
            if username.isEmpty { username = connection.profile.user ?? "" }
        }
        // A saved password shows as dots in the field and is used when Connect is pressed; the desktop waits for Connect.
        .task(id: credentialID) { await checkSaved() }
        // A publisher rather than onChange: it also reports the current phase when this view is rebuilt mid sign-in.
        .onReceive(connection.$phase) { phase in
            guard phase != .connecting, let attempt = connection.signIn else { return }
            connection.signIn = nil
            // Only a password the desktop accepted is kept.
            guard phase == .connected else { return }
            password = ""
            keepUser(attempt.user)
            Task {
                if attempt.remember {
                    await model.vault.rememberWorking(id: attempt.id, secret: attempt.secret, generation: attempt.generation)
                } else {
                    try? await model.vault.forgetRemembered(id: attempt.id)
                }
                await model.refreshVault()
                await checkSaved()
            }
        }
    }

    /// The saved sign-in for this desktop: `rdp:user@host:port`, `vnc:user@host:port` for a Mac account, or
    /// `vnc:host:port` for a VNC password.
    private var credentialID: String {
        let endpoint = KnownHosts.endpoint(host: connection.profile.target, port: connection.profile.effectivePort)
        let user = username.trimmingCharacters(in: .whitespaces)
        return connection.profile.tool.rawValue + ":" + (connection.profile.tool == .rdp || !user.isEmpty ? user + "@" : "") + endpoint
    }

    private func checkSaved() async {
        hasSavedPassword = await model.vault.hasRemembered(id: credentialID)
        remember = remember || hasSavedPassword
        if hasSavedPassword, password.isEmpty { password = Self.savedMask }
        if !hasSavedPassword, password == Self.savedMask { password = "" }
    }

    /// Stands in for a saved password in the field, so it shows as dots without reading the password, which could
    /// ask for Touch ID before the user means to connect. Characters from Unicode's private use area, which no
    /// keyboard types.
    static let savedMask = String(repeating: "\u{F8FF}", count: 8)

    /// Editing the dots clears them: a deleted dot clears the whole saved password, and typing replaces it.
    static func withoutSavedMask(_ value: String) -> String {
        value == savedMask ? value : value.replacingOccurrences(of: "\u{F8FF}", with: "")
    }

    private func connect() {
        guard connection.profile.tool != .rdp || !username.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        trustError = nil
        // The field keeps the password until the desktop accepts it, so a certificate check or a typo
        // does not make it be typed again.
        let typed = password, id = credentialID
        Task {
            var secret = typed
            // The saved password's dots, or an empty field, sign in with the saved one.
            if secret.isEmpty || secret == Self.savedMask, hasSavedPassword {
                do { secret = try await model.vault.password(id: id) }
                catch { trustError = message(for: error); return }
            }
            let generation = await model.vault.sessionGeneration
            let user = username.trimmingCharacters(in: .whitespaces)
            connection.signIn = (id, secret, generation, remember, user)
            connection.connect(username: user, password: secret)
        }
    }

    private func trustCertificate() {
        guard let fingerprint = connection.pendingFingerprint else { return }
        do {
            if let saved = model.sessionTree.node(tab.savedSessionID), var current = saved.container,
               current.tool == .rdp, current.target == connection.profile.target,
               current.effectivePort == connection.profile.effectivePort {
                current.rdpFingerprint = fingerprint
                try model.sessionTree.updateContainer(saved.id, name: saved.name, container: current, environment: saved.environment)
            }
            connection.confirmFingerprint()
            trustError = nil
            connect()
        } catch { trustError = message(for: error) }
    }

    /// Saves the account name with the saved session, so the next sign-in finds its remembered password.
    private func keepUser(_ user: String) {
        guard (connection.profile.user ?? "") != user else { return }
        connection.useUser(user)
        if let saved = model.sessionTree.node(tab.savedSessionID), var current = saved.container,
           current.tool == connection.profile.tool, current.target == connection.profile.target,
           current.effectivePort == connection.profile.effectivePort {
            current.user = user.isEmpty ? nil : user
            try? model.sessionTree.updateContainer(saved.id, name: saved.name, container: current, environment: saved.environment)
        }
        tab.container = connection.profile
    }
}

/// The host key check for the SSH session a desktop tunnels through, which has no pane of its own.
private struct GatewayHostKey: View {
    let model: WorkspaceModel
    @ObservedObject var gateway: SessionTab

    var body: some View {
        Color.clear.loginChallengeSheet(model: model, tab: gateway).sheet(item: Binding(get: { gateway.hostKeyPrompt }, set: { _ in }),
                          onDismiss: { model.answerHostKey(gateway, approve: false) }) { prompt in
            VStack(alignment: .leading, spacing: 18) {
                Label(T("Verify this server"), systemImage: "key.horizontal").appFont(.title2.bold())
                Text(prompt.endpoint).appFont(.headline)
                Text(T("Compare this fingerprint with the server administrator before trusting this connection."))
                Text(prompt.fingerprint).appFont(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button(T("Cancel")) { model.answerHostKey(gateway, approve: false) }
                    Spacer()
                    Button(T("Trust and connect")) { model.answerHostKey(gateway, approve: true) }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 530)
        }
    }
}

private struct NativeDesktopView: NSViewRepresentable {
    let image: CGImage?
    let send: (DesktopInput) -> Void
    let focused: () -> Void

    func makeNSView(context: Context) -> DesktopSurface {
        let view = DesktopSurface()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: DesktopSurface, context: Context) {
        view.send = send
        view.focused = focused
        view.image = image
        view.layer?.contents = image
    }
}

private final class DesktopSurface: NSView {
    var image: CGImage?
    var send: ((DesktopInput) -> Void)?
    /// Called when the view takes focus or is clicked, to share the Mac clipboard.
    var focused: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var buttons: UInt8 = 0
    private var modifiers: Set<UInt16> = []
    private var heldKeysyms: [UInt16: UInt32] = [:]
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func becomeFirstResponder() -> Bool {
        focused?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        buttons = 0
        modifiers.removeAll()
        heldKeysyms.removeAll()
        send?(DesktopInput(kind: "release"))
        return super.resignFirstResponder()
    }

    private func position(_ event: NSEvent, clamp: Bool) -> (UInt16, UInt16)? {
        guard let image, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        let point = convert(event.locationInWindow, from: nil)
        let x = (point.x - (bounds.width - width) / 2) / scale
        let y = (point.y - (bounds.height - height) / 2) / scale
        guard clamp || (x >= 0 && y >= 0 && x < CGFloat(image.width) && y < CGFloat(image.height)) else { return nil }
        return (UInt16(min(max(x, 0), CGFloat(image.width - 1))), UInt16(min(max(y, 0), CGFloat(image.height - 1))))
    }

    private func move(_ event: NSEvent, clamp: Bool = false) {
        guard let (x, y) = position(event, clamp: clamp) else { return }
        send?(DesktopInput(kind: "pointer", x: x, y: y, mask: buttons))
    }

    private func click(_ event: NSEvent, button: UInt8, down: Bool) {
        if down {
            guard position(event, clamp: false) != nil else { return }
            if window?.firstResponder === self { focused?() } else { window?.makeFirstResponder(self) }
            buttons |= button
        } else {
            buttons &= ~button
        }
        move(event, clamp: true)
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event, clamp: true) }
    override func rightMouseDragged(with event: NSEvent) { move(event, clamp: true) }
    override func otherMouseDragged(with event: NSEvent) { move(event, clamp: true) }
    override func mouseDown(with event: NSEvent) { click(event, button: 1, down: true) }
    override func mouseUp(with event: NSEvent) { click(event, button: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { click(event, button: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { click(event, button: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { click(event, button: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { click(event, button: 2, down: false) }
    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = position(event, clamp: false), event.scrollingDeltaY != 0 else { return }
        send?(DesktopInput(kind: "wheel", x: x, y: y, delta: event.scrollingDeltaY > 0 ? 120 : -120))
    }

    override func keyDown(with event: NSEvent) {
        let keysym = Self.keysym(event)
        heldKeysyms[event.keyCode] = keysym
        key(event.keyCode, keysym: keysym, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        let keysym = heldKeysyms.removeValue(forKey: event.keyCode) ?? Self.keysym(event)
        key(event.keyCode, keysym: keysym, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        guard let keysym = Self.specialKeys[code] else { return }
        let pressed = modifiers.insert(code).inserted
        if !pressed { modifiers.remove(code) }
        key(code, keysym: keysym, pressed: pressed)
    }

    private func key(_ keyCode: UInt16, keysym: UInt32, pressed: Bool) {
        send?(DesktopInput(kind: "key", scan: Self.scans[keyCode] ?? 0, keysym: keysym, pressed: pressed))
    }

    private static func keysym(_ event: NSEvent) -> UInt32 {
        if let value = specialKeys[event.keyCode] { return value }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first, scalar.value >= 32 else { return 0 }
        return scalar.value <= 255 ? scalar.value : 0x0100_0000 | scalar.value
    }

    private static let specialKeys: [UInt16: UInt32] = [
        36:0xff0d, 48:0xff09, 51:0xff08, 53:0xff1b, 55:0xffeb, 54:0xffec, 56:0xffe1, 60:0xffe2,
        57:0xffe5, 58:0xffe9, 61:0xffea, 59:0xffe3, 62:0xffe4, 76:0xff8d, 115:0xff50, 116:0xff55,
        117:0xffff, 119:0xff57, 121:0xff56, 123:0xff51, 124:0xff53, 125:0xff54, 126:0xff52,
        122:0xffbe, 120:0xffbf, 99:0xffc0, 118:0xffc1, 96:0xffc2, 97:0xffc3,
        98:0xffc4, 100:0xffc5, 101:0xffc6, 109:0xffc7, 103:0xffc8, 111:0xffc9
    ]

    private static let scans: [UInt16: UInt16] = [
        0:0x1e, 1:0x1f, 2:0x20, 3:0x21, 4:0x23, 5:0x22, 6:0x2c, 7:0x2d, 8:0x2e, 9:0x2f, 11:0x30,
        12:0x10, 13:0x11, 14:0x12, 15:0x13, 16:0x15, 17:0x14, 18:0x02, 19:0x03, 20:0x04, 21:0x05,
        22:0x07, 23:0x06, 24:0x0d, 25:0x0a, 26:0x08, 27:0x0c, 28:0x09, 29:0x0b, 30:0x1b, 31:0x18,
        32:0x16, 33:0x1a, 34:0x17, 35:0x19, 36:0x1c, 37:0x26, 38:0x24, 39:0x28, 40:0x25, 41:0x27,
        42:0x2b, 43:0x33, 44:0x35, 45:0x31, 46:0x32, 47:0x34, 48:0x0f, 49:0x39, 50:0x29, 51:0x0e,
        53:0x01, 54:0xe05c, 55:0xe05b, 56:0x2a, 57:0x3a, 58:0x38, 59:0x1d, 60:0x36, 61:0xe038,
        62:0xe01d, 65:0x53, 67:0x37, 69:0x4e, 71:0x45, 75:0xe035, 76:0xe01c, 78:0x4a, 82:0x52,
        83:0x4f, 84:0x50, 85:0x51, 86:0x4b, 87:0x4c, 88:0x4d, 89:0x47, 91:0x48, 92:0x49,
        96:0x3f, 97:0x40, 98:0x41, 99:0x3d, 100:0x42, 101:0x43, 103:0x57, 109:0x44, 111:0x58,
        114:0xe052, 115:0xe047, 116:0xe049, 117:0xe053, 118:0x3e, 119:0xe04f,
        120:0x3c, 121:0xe051, 122:0x3b, 123:0xe04b, 124:0xe04d, 125:0xe050, 126:0xe048
    ]
}
