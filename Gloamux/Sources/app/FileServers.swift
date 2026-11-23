import Foundation
import FileTransfer

extension WorkspaceModel {
    /// Signs in to an FTP or FTPS server. The tab then has files and no terminal: the file sidebar, the SFTP rail, and
    /// the File Transfer window browse it. Passwords come from the vault like SSH passwords, under `ftp:user@host:port`.
    func connectFTP(_ tab: SessionTab, host: String, port: Int, security: FTPSecurity) async {
        let epoch = UUID()
        tab.epoch = epoch; tab.busy = true; tab.status = "Connecting…"; tab.error = nil
        tab.host = host
        if !tab.opensAutomatically && !tab.renamed { tab.title = (tab.username.isEmpty ? "" : tab.username + "@") + host }
        let typed = tab.password
        tab.password = ""
        defer { if tab.epoch == epoch { tab.busy = false } }
        do {
            let transfer = try await connections.openFTP(
                host: host, port: port, username: tab.username, typedPassword: typed, security: security,
                fingerprint: tab.ftpFingerprint, asksEachConnection: tab.confirmsEachConnection,
                handler: TabSignIn(model: self, tab: tab, epoch: epoch))
            tab.transfer = transfer
            tab.connected = true; tab.transportLost = false; tab.showsFiles = true
            tab.status = "Connected"
            tab.feed(T("Connected to") + " \(KnownHosts.endpoint(host: host, port: port)) (\(transfer.protocolName))\n")
            tab.feed(T(security == .none
                       ? "Plain FTP: the password and files are not encrypted. Browse the files in Remote files or the File Transfer window."
                       : "Browse the files in Remote files or the File Transfer window.") + "\n")
        } catch {
            guard tab.epoch == epoch else { return }
            tab.status = "Connection failed"
            tab.error = message(for: error)
        }
    }
}
