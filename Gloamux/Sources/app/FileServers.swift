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
        let account = tab.credentialID
        defer { if tab.epoch == epoch { tab.busy = false } }
        do {
            let vaultUnlocked = await vault.state == "Unlocked"
            if tab.confirmsEachConnection, !vaultUnlocked, typed.isEmpty {
                tab.status = "Waiting for Touch ID…"
                do { try await confirmOwner(String(format: T("connect to %@"), account)) }
                catch { throw WorkspaceError.invalid("This session asks for Touch ID or the Mac password before it connects.") }
                guard tab.epoch == epoch else { return }
                tab.status = "Connecting…"
            }
            let generation = await vault.sessionGeneration
            // Anonymous FTP has no saved password; anything else needs one typed or saved.
            var password = typed
            if password.isEmpty && !tab.username.isEmpty && tab.username != "anonymous" {
                password = try await vault.password(id: account)
            }
            let settings = FTPSettings(host: host, port: port, username: tab.username, password: password,
                                       security: security, trustedFingerprint: tab.ftpFingerprint)
            let transfer = try await FTPTransfer.connect(settings)
            guard tab.epoch == epoch else { try? await transfer.close(); return }
            if tab.fileCommandAccess == nil {
                if !password.isEmpty { await vault.rememberWorking(id: account, secret: password, generation: generation) }
                await refreshVault()
            }
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
