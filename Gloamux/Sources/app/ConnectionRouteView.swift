import SwiftUI

/// The pane header's route, A › B › C › D: the hosts the connection went through. It opens each host's address, its
/// host key, and a check, from every server, of where the connection reached it from.
struct RouteHeaderButton: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let names = tab.route.map(\.name).joined(separator: " › ")
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted").appFont(.system(size: 10, weight: .medium))
                Text(verbatim: names).lineLimit(1).truncationMode(.middle)
            }
            .appFont(.system(size: 11))
            .foregroundStyle(hovering || showing ? Color.primary : Color.secondary)
            .padding(.horizontal, 7).frame(height: 22)
            .background(Color.primary.opacity(hovering || showing ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 320)
        .onHover { hovering = $0 }
        .help(T("Connection route"))
        .accessibilityLabel(T("Connection route"))
        .accessibilityValue(names)
        .accessibilityIdentifier("connectionRouteButton")
        .popover(isPresented: $showing, arrowEdge: .bottom) { RoutePopover(model: model, tab: tab) }
    }
}

/// Every host from this Mac to the destination, top to bottom, as a line of numbered stops.
struct RoutePopover: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(T("Connection route")).appFont(.headline)
                InfoButton(T("Gloamux signs in to each jump host in turn and asks it to open the connection to the next host, so each host is reached only from the one above it. Check from each server asks every server where the connection came from (echo $SSH_CONNECTION); each one should name the host above it. A server set to run a fixed command for your key runs that command instead."))
            }
            VStack(alignment: .leading, spacing: 0) {
                stop(symbol: "laptopcomputer", title: T("This Mac"), last: false) { EmptyView() }
                ForEach(Array(tab.route.enumerated()), id: \.offset) { index, hop in
                    let destination = index == tab.route.count - 1
                    stop(number: destination ? nil : index + 1, symbol: destination ? "server.rack" : nil,
                         title: hop.name, last: destination) {
                        details(hop, previous: index > 0 ? tab.route[index - 1] : nil, destination: destination)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(T("Check from each server")) { Task { await model.checkRoute(tab) } }
                    .disabled(tab.checkingRoute || !tab.connected)
                    .accessibilityIdentifier("checkRouteButton")
                if tab.checkingRoute { ProgressView().controlSize(.small) }
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
    }

    /// One stop: a badge on the route line, its name, and what is known about it.
    private func stop<Details: View>(number: Int? = nil, symbol: String? = nil, title: String, last: Bool,
                                     @ViewBuilder details: () -> Details) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(number == nil ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.1))
                    if let number {
                        Text(verbatim: "\(number)").appFont(.system(size: 11, weight: .semibold).monospacedDigit())
                    } else if let symbol {
                        Image(systemName: symbol).appFont(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 22, height: 22)
                if !last { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2).frame(minHeight: 14) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).appFont(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                details()
            }
            .padding(.top, 2).padding(.bottom, last ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func details(_ hop: RouteStop, previous: RouteStop?, destination: Bool) -> some View {
        Text(verbatim: hop.endpoint).appFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled)
        if let fingerprint = hop.fingerprint {
            Text(verbatim: fingerprint).appFont(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(fingerprint)
        }
        if let seen = hop.seen {
            if let from = seen.from {
                HStack(spacing: 5) {
                    Text(String(format: T("Came from %@"), from)).appFont(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    if let previous, hop.cameFrom(previous) {
                        Label(T("The host above"), systemImage: "checkmark.circle.fill")
                            .appFont(.system(size: 11)).foregroundStyle(.green)
                    }
                }
            } else {
                Text(T("This server did not say where the connection came from."))
                    .appFont(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
}
