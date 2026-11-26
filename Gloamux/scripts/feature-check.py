#!/usr/bin/env python3
"""Gloamux feature check: one working operation for every `gloamux` command group, against the packaged app.

Everything runs against a throwaway workspace, a throwaway OpenSSH server on 127.0.0.1 that accepts only a key made
for this run, and local web servers. It never opens your workspace, never signs in with a password, never connects to
another host, and never opens your default browser. The steps that need the app start a second Gloamux process
with the throwaway workspace and quit it at the end.

    python3 Gloamux/scripts/feature-check.py                                  # build/Gloamux.app
    python3 Gloamux/scripts/feature-check.py --app "/path/Gloamux UITest.app" # a renamed copy

The app and its `gloamux` write the app's own preferences domain. With a renamed copy (another CFBundleIdentifier),
the run also changes and resets settings and imports a backup; with the installed app's identifier, it leaves those
steps out so the settings of the Gloamux you use stay as they are.

Steps that need a person are not run: Touch ID for saved passwords, unlocking the workspace, and approving an agent's
proposed command. Exit status: 0 when every check passed, 1 when any failed, 2 for a setup problem.
"""

import argparse
import datetime
import importlib.util
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import http.server
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("gloamux_stress", HERE / "stress-test.py")
stress = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stress)


class Check:
    def __init__(self, out):
        self.results = []
        self.out = out

    def __call__(self, name, function):
        start = time.monotonic()
        try:
            detail = function()
            self.results.append({"check": name, "passed": True, "detail": "" if detail is None else str(detail)[:200]})
            print(f"PASS {name}" + (f"  ({detail})" if detail else ""), flush=True)
        except Exception as error:  # noqa: BLE001 - every failure belongs in the report
            self.results.append({"check": name, "passed": False, "detail": str(error)[:500]})
            print(f"FAIL {name}  {str(error)[:300]}", flush=True)
        self.results[-1]["seconds"] = round(time.monotonic() - start, 2)

    def report(self, header):
        passed = sum(1 for item in self.results if item["passed"])
        lines = [f"# Gloamux feature check, {header}", "", f"{passed}/{len(self.results)} passed.", "",
                 "| Check | Result | Detail |", "|---|---|---|"]
        for item in self.results:
            lines.append(f"| {item['check']} | {'pass' if item['passed'] else 'FAIL'} | "
                         f"{item['detail'].replace('|', '/').replace(chr(10), ' ')} |")
        (self.out / "report.md").write_text("\n".join(lines) + "\n")
        (self.out / "report.json").write_text(json.dumps(self.results, indent=2, ensure_ascii=False))
        print(f"\n{passed}/{len(self.results)} passed. Report: {self.out / 'report.md'}")
        return passed == len(self.results)


def expect(condition, message):
    if not condition:
        raise RuntimeError(message)


class TLSPage(threading.Thread):
    """An HTTPS page with a certificate made for this run, which macOS does not trust."""

    def __init__(self, folder):
        super().__init__(daemon=True)
        key, cert = folder / "tls.key", folder / "tls.crt"
        stress.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1", "-keyout", str(key), "-out", str(cert)])

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                data = b"<!doctype html><title>TLS page</title>tls"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.port = self.server.server_address[1]

    def run(self):
        self.server.serve_forever()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class FeatureCheck:
    def __init__(self, options):
        self.options = options
        self.out = Path(options.out or tempfile.mkdtemp(prefix=f"gloamux-features-{datetime.datetime.now():%Y%m%d-%H%M%S}-"))
        self.out.mkdir(parents=True, exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix="gloamux-features-work-"))
        self.workspace = self.scratch / "workspace"
        self.cli = stress.CLIRunner(self.workspace)
        self.check = Check(self.out)
        self.sshd = None
        self.app = None
        self.own_settings = not stress.writes_installed_settings()

    def fails(self, *args):
        """Runs a command that must be refused; returns its message."""
        process = subprocess.run([str(stress.CLI), *map(str, args), "--workspace", str(self.workspace)],
                                 capture_output=True, text=True, timeout=120)
        expect(process.returncode != 0, f"{' '.join(map(str, args[:3]))} was accepted")
        return (process.stderr or process.stdout).strip().splitlines()[-1][:120]

    def wait_ready(self, tab, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            info = self.cli.json("tabs", "show", tab)
            if info.get("terminalReady"):
                return info
            if info.get("error"):
                raise RuntimeError(info["error"])
            time.sleep(0.3)
        raise RuntimeError(f"tab {tab} did not become ready")

    def wait_text(self, tab, text, seconds=30, lines=40):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if text in self.cli.json("tabs", "read", tab, lines)["text"]:
                return
            time.sleep(0.3)
        raise RuntimeError(f"{text!r} did not appear in the tab")

    # MARK: Without the app

    def offline(self):
        c, cli = self.check, self.cli
        fixture = self.sshd

        c("version", lambda: stress.run([str(stress.CLI), "--version"])[1].strip())
        c("self-test", lambda: stress.run([str(stress.CLI), "--self-test"], timeout=120)[1].strip().splitlines()[-1])
        c("help for a command", lambda: expect("Usage: gloamux sessions" in stress.run([str(stress.CLI), "sessions", "--help"])[1], "no usage"))
        c("help with --workspace", lambda: expect("Usage: gloamux web" in cli("web", "--help")[1], "no usage"))
        c("completion", lambda: expect("gloamux" in stress.run([str(stress.CLI), "completion", "zsh"])[1], "no completion script"))
        c("unknown command is refused", lambda: self.fails("frobnicate"))

        def sessions():
            cli("sessions", "mkdir", "Servers")
            cli("sessions", "add", "Web 1", "ssh", "198.51.100.10", "admin", 22, "Servers")
            cli("sessions", "edit", "Web 1", "198.51.100.11", "admin", 2222)
            cli("sessions", "options", "Web 1", "forward-agent=on", "startup=uptime", "algorithms=compatible")
            cli("sessions", "env", "Web 1", "staging")
            cli("sessions", "rename", "Web 1", "Web A")
            cli("sessions", "add-other", "Router console", "telnet", "198.51.100.1", "port=2323")
            cli("sessions", "edit-other", "Router console", "port=23")
            cli("sessions", "add-other", "Box", "docker", "web-1", "shell=/bin/bash")
            cli("sessions", "add", "Desk", "vnc", "198.51.100.20", "-", 5900)
            cli("sessions", "edit-other", "Desk", "clipboard=on")
            cli("sessions", "move", "Router console", "Servers")
            shown = cli.json("sessions", "show", "Web A")
            expect("198.51.100.11" in json.dumps(shown), "edit did not reach the session")
            listed = cli.json("sessions", "list")
            return f"{len(listed)} items"
        c("sessions: folders, add, edit, options, other kinds, move", sessions)

        def sessions_files():
            for fmt, name in (("openssh", "config"), ("csv", "sessions.csv"), ("gloamux", "sessions.gloamuxsessions")):
                cli("sessions", "export", fmt, self.scratch / name)
                expect((self.scratch / name).stat().st_size > 0, f"{fmt} export is empty")
            preview = cli.json("sessions", "import", "gloamux", self.scratch / "sessions.gloamuxsessions")
            cli("sessions", "import", "openssh", self.scratch / "config", "Imported")
            cli("sessions", "from-sftp", "Gateway", "sftp -P 2222 admin@198.51.100.30:/srv")
            cli("sessions", "remove", "Box")
            names = [item["name"] for item in cli.json("sessions", "list")]
            expect("Gateway" in json.dumps(cli.json("sessions", "list")), "from-sftp did not save")
            return f"preview {len(json.dumps(preview))} bytes, {len(names)} items"
        c("sessions: export, import, from-sftp, remove", sessions_files)
        c("sessions: serial-ports", lambda: cli("sessions", "serial-ports")[1].strip()[:60])
        c("sessions: bad protocol is refused", lambda: self.fails("sessions", "add", "X", "gopher", "198.51.100.1", "a"))

        def hosts():
            cli("hosts", "trust", f"[127.0.0.1]:{fixture.port}", fixture.host_key, fixture.fingerprint)
            expect(fixture.fingerprint in json.dumps(cli.json("hosts", "list")), "trusted key not listed")
            known = self.scratch / "known_hosts"
            cli("hosts", "export", known)
            expect(fixture.host_key.split()[1] in known.read_text(), "export lacks the key")
            cli.json("hosts", "history")
            return "trusted, listed, exported"
        c("hosts: trust, list, export, history", hosts)

        cli("sessions", "add", "Fixture", "ssh", "127.0.0.1", fixture.user, fixture.port)
        cli("sessions", "auth", "Fixture", "key", fixture.client_key)
        data = fixture.data

        def files(protocol):
            def body():
                local = self.scratch / f"note-{protocol}.txt"
                local.write_text(f"hello over {protocol}\n" * 100)
                remote = data / f"note-{protocol}.txt"
                cli("files", "put", "--session", "Fixture", "--protocol", protocol, local, remote)
                expect(remote.read_text() == local.read_text(), "upload differs")
                self.fails("files", "put", "--session", "Fixture", "--protocol", protocol, local, remote)
                cli("files", "put", "--session", "Fixture", "--protocol", protocol, "--overwrite", local, remote)
                back = self.scratch / f"back-{protocol}.txt"
                cli("files", "get", "--session", "Fixture", "--protocol", protocol, remote, back)
                expect(back.read_text() == local.read_text(), "download differs")
                return "put, refused overwrite, --overwrite, get"
            return body
        c("files over SFTP", files("sftp"))
        c("files over SCP", files("scp"))

        def files_ops():
            cli("files", "mkdir", "--session", "Fixture", data / "dir")
            cli("files", "mv", "--session", "Fixture", data / "note-sftp.txt", data / "dir" / "moved.txt")
            cli("files", "chmod", "--session", "Fixture", "0600", data / "dir" / "moved.txt")
            expect(oct((data / "dir" / "moved.txt").stat().st_mode & 0o777) == "0o600", "chmod did not apply")
            stat = cli.json("files", "stat", "--session", "Fixture", "--json", data / "dir" / "moved.txt")
            listing = cli("files", "ls", "--session", "Fixture", data / "dir")[1]
            expect("moved.txt" in listing, "ls lacks the file")
            cli("files", "pwd", "--session", "Fixture")
            cli("files", "rm", "--session", "Fixture", data / "dir" / "moved.txt")
            cli("files", "rmdir", "--session", "Fixture", data / "dir")
            expect(not (data / "dir").exists(), "rmdir left the folder")
            return f"stat {str(stat)[:40]}"
        c("files: mkdir, mv, chmod, stat, ls, pwd, rm, rmdir", files_ops)

        def sftp_batch():
            local = self.scratch / "batch.txt"
            local.write_text("batch\n")
            script = f"put {local} {data / 'batch.txt'}\nls {data}\nbye\n"
            process = subprocess.run([str(stress.CLI), "sftp", "Fixture", "--workspace", str(self.workspace)], input=script,
                                     capture_output=True, text=True, timeout=120)
            expect(process.returncode == 0, f"exited {process.returncode}: {process.stderr.strip()[:200]}")
            expect((data / "batch.txt").read_text() == "batch\n", "the file did not arrive")
            return "put and ls from standard input"
        c("sftp: commands from standard input", sftp_batch)

        def ssh():
            process = subprocess.run([str(stress.CLI), "ssh", "Fixture", "--workspace", str(self.workspace)],
                                     input="echo gloamux-ssh-$((40+2))\nexit 3\n", capture_output=True, text=True, timeout=120)
            expect("gloamux-ssh-42" in process.stdout, f"no output: {process.stdout[-200:]!r} {process.stderr[-200:]!r}")
            expect(process.returncode == 3, f"exit status {process.returncode}, not the shell's 3")
            return "ran a command, kept the exit status"
        c("ssh: a saved session in this terminal", ssh)

        def forwards():
            added = cli.json("forwards", "add", "Fixture", "local", 0, "127.0.0.1", 9)
            rules = cli.json("forwards", "list", "Fixture")
            expect(rules, "no rules listed")
            rule = added.get("id") if isinstance(added, dict) else None
            rule = rule or rules[-1]["id"]
            cli("forwards", "remove", "Fixture", rule)
            return "add, list, remove"
        c("forwards: saved rules", forwards)

        def commands():
            added = cli.json("commands", "add", "Disk", "df -h")
            command = added["id"]
            cli("commands", "edit", command, "Disk use", "df -h /")
            expect("Disk use" in json.dumps(cli.json("commands", "list")), "edit not listed")
            self.command = cli.json("commands", "add", "Marker", "echo quick-$((6*7))")["id"]
            cli("commands", "remove", command)
            return "add, edit, list, remove"
        c("commands: quick commands", commands)

        def triggers():
            added = cli.json("triggers", "add", "Errors", "ERROR", "mark", "text", "ignore-case")
            trigger = added["id"]
            cli("triggers", "disable", trigger)
            cli("triggers", "enable", trigger)
            cli("triggers", "edit", trigger, "Failures", "fail(ed)?", "notify", "regex", "match-case")
            expect("Failures" in json.dumps(cli.json("triggers", "list")), "edit not listed")
            cli("triggers", "remove", trigger)
            return "add, disable, enable, edit, remove"
        c("triggers: output triggers", triggers)

        def runbooks():
            book = self.scratch / "Check.md"
            book.write_text("# Check\n\n```sh\necho runbook-$((5*5))\n```\n")
            cli("runbooks", "import", book)
            cli("runbooks", "create", "Empty")
            expect("Check" in json.dumps(cli.json("runbooks", "list")), "import not listed")
            cli("runbooks", "show", "Check")
            return "import, create, list, show"
        c("runbooks: import, create, show", runbooks)

        def history():
            records = cli.json("history", "list", 20)
            expect(records, "no connection records after the file transfers")
            for name in ("history.json", "history.csv"):
                cli("history", "export", self.scratch / name)
                expect((self.scratch / name).stat().st_size > 0, f"{name} is empty")
            first = records[0]["id"]
            cli("history", "show", first)
            cli("history", "log", first, self.scratch / "record.txt")
            return f"{len(records)} records"
        c("history: list, show, log, export", history)

        def appearance():
            themes = cli.json("appearance", "list")
            current = cli.json("appearance", "get")
            other = next(item["id"] for item in themes if item["id"] != (current.get("id") if isinstance(current, dict) else current))
            cli("appearance", "set", other)
            return f"{len(themes)} themes, set {other}"
        c("appearance: list, get, set", appearance)

        def layout():
            before = cli.json("layout", "get")
            cli("layout", "set", "classic")
            expect("classic" in json.dumps(cli.json("layout", "get")), "layout not set")
            cli("layout", "set", "default")
            return f"was {before}"
        c("layout: get, set", layout)

        def settings():
            listed = cli.json("settings", "list")
            cli("settings", "get", "terminal.scrollback")
            if not self.own_settings:
                return f"{len(listed)} settings; set and reset left out for the installed app's settings"
            cli("settings", "set", "terminal.scrollback", 5000)
            expect("5000" in json.dumps(cli.json("settings", "get", "terminal.scrollback")), "set did not apply")
            cli("settings", "reset", "terminal.scrollback")
            return f"{len(listed)} settings, set and reset"
        c("settings: list, get, set, reset", settings)
        c("settings: bad value is refused", lambda: self.fails("settings", "set", "terminal.scrollback", "lots"))

        def config():
            backup = self.scratch / "all.gloamuxconfig"
            cli("config", "export", backup)
            expect((self.scratch / "all.gloamuxconfig.sha256").exists(), "no .sha256")
            if not self.own_settings:
                return "export; import left out for the installed app's settings"
            restored = stress.CLIRunner(self.scratch / "restored")
            restored("config", "import", backup)
            names = sorted(item["name"] for item in cli.json("sessions", "list"))
            expect(names == sorted(item["name"] for item in restored.json("sessions", "list")), "restored sessions differ")
            return "export, import into another workspace"
        c("config: export, import", config)
        c("agents: status, history", lambda: (cli.json("agents", "status"), cli.json("agents", "history"))[0])
        c("vault: status", lambda: cli.json("vault", "status"))
        c("xserver: status", lambda: cli.json("xserver", "status"))
        c("recordings: list", lambda: f"{len(cli.json('recordings', 'list'))} recordings")
        c("benchmark", lambda: len(json.loads(stress.run([str(stress.CLI), "benchmark", "--megabytes", "2", "--json"], timeout=300)[1])["results"]))
        c("tabs need the running app", lambda: self.fails("tabs", "list"))
        c("web needs the running app", lambda: self.fails("web", "list"))

    # MARK: With the app

    def start_app(self):
        fixture = next(item for item in self.cli.json("sessions", "list") if item["name"] == "Fixture")
        (self.workspace / "agent-access.json").write_text(json.dumps({"enabled": True, "sessions": [fixture["id"]]}))
        self.app = subprocess.Popen([str(stress.APP_BINARY), "--workspace", str(self.workspace)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            expect(self.app.poll() is None, "the app exited during launch")
            if self.cli("tabs", "list", check=False, timeout=30)[1].strip().startswith("["):
                time.sleep(2)
                return "answering"
            time.sleep(0.5)
        raise RuntimeError("the app did not answer within 40 seconds")

    def live(self):
        c, cli = self.check, self.cli
        tabs = {}

        def open_tabs():
            tabs["local"] = cli.json("tabs", "local")["id"]
            tabs["ssh"] = cli.json("tabs", "open", "Fixture")["id"]
            self.wait_ready(tabs["local"])
            self.wait_ready(tabs["ssh"])
            time.sleep(1.5)
            return f"{len(cli.json('tabs', 'list'))} tabs"
        c("tabs: local and saved SSH", open_tabs)
        if len(tabs) < 2:
            return
        local, ssh = tabs["local"], tabs["ssh"]

        def run_read():
            cli("tabs", "run", ssh, "echo over-ssh-$((20+3))")
            self.wait_text(ssh, "over-ssh-23")
            # send types without Return; run then adds a comment and presses Return.
            cli("tabs", "send", local, "echo typed-$((3+4))")
            cli("tabs", "run", local, " # sent")
            self.wait_text(local, "typed-7")
            return "run, send, read"
        c("tabs: run, send, read", run_read)

        def tab_controls():
            cli("tabs", "rename", local, "Checks")
            cli("tabs", "select", local)
            for operation in ("readonly", "timestamps", "copy-mode", "log", "multiexec"):
                cli("tabs", operation, local, "on")
                cli("tabs", operation, local, "off")
            cli("tabs", "encoding", local, "utf8")
            cli("tabs", "integration", local)
            cli("tabs", "zmodem", local, "status")
            cli("tabs", "paste-history")
            for view in ("files", "session-log", "terminal"):
                cli("tabs", "view", ssh, view)
            return "rename, select, switches, encoding, integration, zmodem, view"
        c("tabs: names, switches, views", tab_controls)

        def splits():
            extra = cli.json("tabs", "duplicate", local)["id"]
            self.wait_ready(extra)
            cli("tabs", "split", local, "right", extra)
            cli("tabs", "broadcast", local, "on")
            cli("tabs", "broadcast", local, "off")
            cli("tabs", "unsplit", extra)
            cli("tabs", "window", extra)
            cli("tabs", "attach", extra)
            cli("tabs", "close", extra)
            return "duplicate, split, broadcast, unsplit, window, attach, close"
        c("tabs: split and windows", splits)

        def reconnect():
            cli("tabs", "disconnect", ssh)
            time.sleep(1)
            cli("tabs", "reconnect", ssh)
            self.wait_ready(ssh)
            cli("tabs", "run", ssh, "echo back-$((1+1))")
            self.wait_text(ssh, "back-2")
            return "disconnect, reconnect"
        c("tabs: disconnect and reconnect", reconnect)

        def recording():
            cli("tabs", "record", local, "on")
            cli("tabs", "run", local, "echo recorded")
            self.wait_text(local, "recorded")
            time.sleep(0.5)
            cli("tabs", "record", local, "off")
            listed = cli.json("recordings", "list")
            expect(listed, "no recording saved")
            name = listed[0].get("file") or listed[0].get("name")
            cli("recordings", "export", name, self.scratch / "export.cast")
            expect((self.scratch / "export.cast").stat().st_size > 0, "export is empty")
            return name
        c("tabs: record; recordings export", recording)

        def quick_commands():
            cli("commands", "run", self.command, local)
            self.wait_text(local, "quick-42")
            return "run"
        c("commands: run into a tab", quick_commands)

        def runbook():
            cli("runbooks", "run", "Check", local)
            self.wait_text(local, "runbook-25")
            return json.dumps(cli.json("runbooks", "show", "Check"))[:80]
        c("runbooks: run", runbook)

        def forwards():
            echo = stress.EchoServer()
            echo.start()
            try:
                started = cli.json("forwards", "start", ssh, "local", 0, "127.0.0.1", echo.port)
                with socket.create_connection(("127.0.0.1", started["boundPort"]), timeout=10) as connection:
                    connection.sendall(b"ping\n")
                    expect(connection.recv(16) == b"ping\n", "the forward did not echo")
                expect(started["id"] in json.dumps(cli.json("forwards", "live-list")), "live-list lacks the forward")
                cli("forwards", "stop", ssh, started["id"])
            finally:
                echo.stop()
            return f"port {started['boundPort']}"
        c("forwards: start, live-list, stop", forwards)

        def web():
            pages = stress.PageServer()
            pages.start()
            tls = TLSPage(self.scratch)
            tls.start()
            base = f"http://127.0.0.1:{pages.port}"
            try:
                cli("web", "show", f"{base}/page/1")
                second = cli.json("web", "open", f"{base}/page/2")["id"]
                self.wait_page(second, "Page 2")
                cli("web", "go", second, f"{base}/page/3")
                self.wait_page(second, "Page 3")
                cli("web", "back", second)
                self.wait_page(second, "Page 2")
                cli("web", "forward", second)
                self.wait_page(second, "Page 3")
                cli("web", "reload", second)
                cli("web", "stop", second)
                expect(cli.json("web", "zoom", second, 125)["zoom"] == 125, "zoom")
                first = next(page["id"] for page in cli.json("web", "list")["pages"] if page["id"] != second)
                cli("web", "select", first)
                expect(cli.json("web", "list")["current"] == first, "select")

                secure = cli.json("web", "open", f"https://127.0.0.1:{tls.port}/")["id"]
                prompt = self.wait_certificate(secure)
                self.fails("web", "trust", secure, "0" * 64)
                cli("web", "trust", secure, prompt["sha256"])
                self.wait_page(secure, "TLS page")
                other = cli.json("web", "open", f"https://localhost:{tls.port}/")["id"]
                self.wait_certificate(other)
                cli("web", "refuse", other)
                expect("error" in cli.json("web", "status", other), "refused page has no error")

                cli("web", "go", first, f"{base}/cookie")
                self.wait_page(first, "cookie set")
                cli("web", "reload", first)
                self.wait_page(first, "cookie kept")
                cli("web", "clear-data")
                self.wait_page(first, "cookie set")
                self.fails("web", "open", "file:///etc/hosts")
                for page in cli.json("web", "list")["pages"]:
                    cli("web", "close", page["id"])
                cli("web", "hide")
                expect(cli.json("web", "list")["shown"] is False, "panel still shown")
                return "show, open, go, back, forward, reload, stop, zoom, select, trust, refuse, clear-data, close, hide"
            finally:
                pages.stop()
                tls.stop()
        c("web: browser panel", web)

        def mcp():
            client = stress.MCPClient(self.workspace)
            try:
                client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                              "clientInfo": {"name": "gloamux-features", "version": "1"}})
                client.notify("notifications/initialized")
                tools = client.request("tools/list")["tools"]
                listed = client.tool("list_sessions")
                expect([item["name"] for item in listed] == ["Fixture"], "agent saw other sessions")
                proposal = client.tool("propose_command", {"session": "Fixture", "command": "uptime", "reason": "feature check"})
                expect(client.tool("get_proposal", {"proposal": proposal["proposal"]})["status"] == "waiting", "ran without review")
                return f"{len(tools)} tools"
            finally:
                client.close()
        c("mcp: tools, allowed sessions, proposals wait", mcp)
        c("agents: history after MCP", lambda: f"{len(self.cli.json('agents', 'history'))} events")

        def dropdown():
            if not self.own_settings:
                return "left out: it needs a dropdown-hotkey setting"
            cli("settings", "set", "dropdown-hotkey", "f12")
            try:
                expect(cli.json("layout", "dropdown")["dropdown"] is True, "not shown")
                time.sleep(0.5)
                expect(cli.json("layout", "dropdown")["dropdown"] is False, "not hidden")
            finally:
                cli("settings", "reset", "dropdown-hotkey")
            return "shown and hidden"
        c("layout: dropdown window", dropdown)

        def close_and_history():
            cli("tabs", "close", ssh)
            records = cli.json("history", "list", 5)
            expect(any("Fixture" in json.dumps(record) for record in records), "no record of the SSH tab")
            return f"{len(records)} records"
        c("history: the SSH tab is recorded", close_and_history)

        def lock():
            cli("workspace", "lock")
            message = self.fails("tabs", "read", local)
            return message
        c("workspace: lock refuses tab control", lock)

    def wait_page(self, page, title, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            status = self.cli.json("web", "status", page)
            if status.get("title") == title and not status.get("loading"):
                return status
            time.sleep(0.2)
        raise RuntimeError(f"page did not show {title!r}: {status}")

    def wait_certificate(self, page, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            status = self.cli.json("web", "status", page)
            if "certificate" in status:
                return status["certificate"]
            time.sleep(0.2)
        raise RuntimeError("the page did not ask about its certificate")

    # MARK: Driving it

    def execute(self):
        if not stress.CLI.exists() or not stress.APP_BINARY.exists():
            raise stress.SetupError(f"{stress.APP} is missing. Build it with Gloamux/scripts/package-app.sh first.")
        started = datetime.datetime.now()
        try:
            self.sshd = stress.LocalSSHD(self.scratch / "sshd")
            self.offline()
            if not self.options.no_app:
                self.check("app launch", self.start_app)
                if self.app and self.app.poll() is None:
                    self.live()
                    self.check("app still running", lambda: expect(self.app.poll() is None, f"exited {self.app.returncode}"))
        finally:
            if self.app and self.app.poll() is None:
                self.app.terminate()
                try:
                    self.app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.app.kill()
            if self.sshd:
                self.sshd.stop()
            ok = self.check.report(f"{started:%Y-%m-%d %H:%M}, {stress.APP.name} ({stress.app_identifier()})")
            if not self.options.keep:
                shutil.rmtree(self.scratch, ignore_errors=True)
        return ok


def main():
    parser = argparse.ArgumentParser(description="Check one working operation of every gloamux command group.")
    parser.add_argument("--app", help="the Gloamux app to check, such as a renamed copy (default: build/Gloamux.app)")
    parser.add_argument("--no-app", action="store_true", help="skip the checks that start the app")
    parser.add_argument("--out", help="folder for report.md and report.json")
    parser.add_argument("--keep", action="store_true", help="keep the throwaway workspace and server files")
    options = parser.parse_args()
    if options.app:
        stress.use_app(options.app)
    try:
        return 0 if FeatureCheck(options).execute() else 1
    except stress.SetupError as error:
        print(f"Setup problem: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
