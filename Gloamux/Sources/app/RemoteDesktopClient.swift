import AppKit
import Foundation
import Network

/// A saved endpoint for the embedded RDP or VNC engine.
struct RemoteDesktopAddress {
    let host: String
    let authority: String

    init(_ profile: ContainerSession) throws {
        let host = profile.target
        let ip = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let displayHost: String
        if IPv6Address(ip) != nil {
            displayHost = "[\(ip)]"
        } else {
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, name.utf8.count <= 253, labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { throw Self.invalid }
            displayHost = host
        }
        guard profile.tool.opensDesktop, (1...65535).contains(profile.effectivePort) else { throw Self.invalid }
        self.host = ip
        authority = "\(displayHost):\(profile.effectivePort)"
    }

    private static var invalid: WorkspaceError { .invalid("Enter a valid remote desktop host and port.") }
}

