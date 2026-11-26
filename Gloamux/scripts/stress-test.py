#!/usr/bin/env python3
"""Gloamux stress test and resource report.

Exercises the packaged app and its `gloamux` CLI end to end, under load, and records what it costs this Mac.
Everything runs against a throwaway workspace and a throwaway OpenSSH server on 127.0.0.1 that accepts only a key
made for this run. It never opens your own workspace, never signs in with a password, and never connects to
another host. The app instance it starts is a second, separate Gloamux process that it quits at the end.

    python3 Gloamux/scripts/stress-test.py                  # full run, about 3 minutes
    python3 Gloamux/scripts/stress-test.py --quick          # smaller loads, about 1 minute
    python3 Gloamux/scripts/stress-test.py --no-app         # CLI and file transfers only, no app window
    python3 Gloamux/scripts/stress-test.py --app "/path/Gloamux UITest.app"   # a renamed copy of the app

Build first with Gloamux/scripts/package-app.sh. The app and its `gloamux` use the app's own preferences domain, so a
renamed copy (another CFBundleIdentifier) keeps the run away from the settings of the Gloamux you use; with the
installed app's identifier, the run leaves out the steps that would write those settings. The report (Markdown and JSON) and the resource samples (CSV) are
written to --out, by default a new folder under the system temporary folder; its path is printed at the end.
Exit status: 0 when every check passed, 1 when any failed, 2 for a setup problem.
"""

import argparse
import base64
import http.server
import plistlib
import concurrent.futures
import csv
import datetime
import hashlib
import json
import os
import platform
import random
import resource
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "build" / "Gloamux.app"
APP_BINARY = APP / "Contents" / "MacOS" / "Gloamux"
CLI = APP / "Contents" / "Resources" / "bin" / "gloamux"
INSTALLED_ID = "local.gloamux.desktop"


def use_app(path):
    """Points the run at another copy of the app, such as a renamed test copy."""
    global APP, APP_BINARY, CLI
    APP = Path(path).resolve()
    APP_BINARY = APP / "Contents" / "MacOS" / "Gloamux"
    CLI = APP / "Contents" / "Resources" / "bin" / "gloamux"


def app_identifier():
    try:
        with open(APP / "Contents" / "Info.plist", "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier", "")
    except (OSError, plistlib.InvalidFileException):
        return ""


def writes_installed_settings():
    """True when this copy's preferences are those of the Gloamux the user runs."""
    return app_identifier() == INSTALLED_ID


class SetupError(Exception):
    pass


# MARK: Running commands

def run(args, *, timeout=300, check=True, stdin=None):
    """Runs a command; returns (seconds, stdout). Raises with stderr when it fails and check is set."""
    start = time.monotonic()
    process = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    seconds = time.monotonic() - start
    if check and process.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, args[:4]))} exited {process.returncode}: "
                           f"{(process.stderr or process.stdout).strip()[:400]}")
    return seconds, process.stdout


class CLIRunner:
    def __init__(self, workspace):
        self.workspace = str(workspace)

    def __call__(self, *args, timeout=300, check=True):
        seconds, out = run([str(CLI), *map(str, args), "--workspace", self.workspace], timeout=timeout, check=check)
        return seconds, out

    def json(self, *args, timeout=300):
        _, out = self(*args, timeout=timeout)
        return json.loads(out) if out.strip() else None


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(folder):
    entries = {}
    for path in sorted(Path(folder).rglob("*")):
        if path.is_file():
            entries[str(path.relative_to(folder))] = sha256_file(path)
    return entries


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


# MARK: Resource sampling

def parse_cputime(text):
    """ps `time` (cumulative CPU) as seconds: [[dd-]hh:]mm:ss.ss."""
    text = text.strip()
    days = 0
    if "-" in text:
        day, text = text.split("-", 1)
        days = int(day)
    parts = [float(part) for part in text.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return days * 86400 + seconds


def process_stats(pid):
    """CPU percent, resident memory in MB, cumulative CPU seconds, and thread count for one process."""
    try:
        out = subprocess.run(["ps", "-o", "%cpu=,rss=,time=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
        if len(out) < 3:
            return None
        threads = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.count("\n") - 1
        return {"cpu": float(out[0]), "rss_mb": int(out[1]) / 1024, "cpu_seconds": parse_cputime(out[2]), "threads": max(threads, 0)}
    except (ValueError, OSError):
        return None


def footprint_mb(pid):
    """Physical footprint, the figure Activity Monitor shows as Memory. Unlike RSS, it drops when memory is freed."""
    try:
        out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            if "Footprint:" in line:
                value, unit = line.split("Footprint:")[1].split()[:2]
                return round(float(value) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}.get(unit, 1), 1)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        pass
    return None


def open_files(pid):
    try:
        return subprocess.run(["lsof", "-n", "-P", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout.count("\n") - 1
    except (OSError, subprocess.TimeoutExpired):
        return None


def free_memory_mb():
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
        page = 16384
        if "page size of" in out:
            page = int(out.split("page size of")[1].split()[0])
        free = 0
        for line in out.splitlines():
            if line.startswith(("Pages free", "Pages speculative")):
                free += int(line.split(":")[1].strip().rstrip("."))
        return free * page / (1 << 20)
    except (OSError, ValueError, IndexError):
        return None


def battery():
    try:
        out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
        for token in out.replace(";", " ").split():
            if token.endswith("%"):
                return f"{token} ({'AC' if 'AC Power' in out else 'battery'})"
    except OSError:
        pass
    return "unknown"


def thermal():
    try:
        out = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True).stdout.strip()
        warnings = [line.strip() for line in out.splitlines() if "CPU_Speed_Limit" in line or "warning level" in line.lower()]
        return "; ".join(warnings) or "no thermal warnings"
    except OSError:
        return "unknown"


class Sampler(threading.Thread):
    """Samples the app, the test sshd, and the Mac once a second while the run goes on."""

    def __init__(self, csv_path):
        super().__init__(daemon=True)
        self.app_pid = None
        self.sshd_pid = None
        self.phase = "setup"
        self.samples = []
        self.stopping = threading.Event()
        self.csv_path = csv_path
        self.lock = threading.Lock()

    def run(self):
        tick = 0
        while not self.stopping.wait(1.0):
            row = {"time": round(time.time(), 1), "phase": self.phase, "load1": round(os.getloadavg()[0], 2),
                   "free_mb": round(free_memory_mb() or 0)}
            if self.app_pid and (stats := process_stats(self.app_pid)):
                row.update({"app_cpu": stats["cpu"], "app_rss_mb": round(stats["rss_mb"], 1), "app_threads": stats["threads"]})
                if (memory := footprint_mb(self.app_pid)) is not None:
                    row["app_memory_mb"] = memory
                if tick % 5 == 0:
                    row["app_files"] = open_files(self.app_pid)
            if self.sshd_pid and (stats := process_stats(self.sshd_pid)):
                row["sshd_cpu"] = stats["cpu"]
            with self.lock:
                self.samples.append(row)
            tick += 1

    def stop(self):
        self.stopping.set()
        self.join(timeout=3)
        fields = ["time", "phase", "load1", "free_mb", "app_cpu", "app_memory_mb", "app_rss_mb", "app_threads", "app_files", "sshd_cpu"]
        with open(self.csv_path, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            for row in self.samples:
                writer.writerow({key: row.get(key, "") for key in fields})

    def window(self, phase):
        with self.lock:
            return [row for row in self.samples if row["phase"] == phase]


# MARK: The throwaway SSH server

class LocalSSHD:
    def __init__(self, folder):
        if not (Path("/usr/sbin/sshd").exists() and Path("/usr/bin/ssh-keygen").exists()):
            raise SetupError("OpenSSH (/usr/sbin/sshd) is not available.")
        self.folder = Path(folder)
        self.folder.mkdir(parents=True)
        self.user = os.environ.get("USER") or os.getlogin()
        self.port = self._free_port()
        run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.folder / "host_ed25519")])
        run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "gloamux-stress", "-f", str(self.folder / "client_ed25519")])
        shutil.copy(self.folder / "client_ed25519.pub", self.folder / "authorized_keys")
        (self.folder / "sshd_config").write_text(f"""Port {self.port}
ListenAddress 127.0.0.1
HostKey {self.folder / 'host_ed25519'}
AuthorizedKeysFile {self.folder / 'authorized_keys'}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile {self.folder / 'sshd.pid'}
AllowTcpForwarding yes
MaxStartups 64:30:128
MaxSessions 64
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
""")
        self.process = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(self.folder / "sshd_config")],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if self._accepts():
                break
            time.sleep(0.1)
        else:
            self.stop()
            raise SetupError("The test sshd did not start.")
        body = (self.folder / "host_ed25519.pub").read_text().split()
        self.host_key = f"{body[0]} {body[1]}"
        self.fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(body[1])).digest()).decode().rstrip("=")
        self.client_key = self.folder / "client_ed25519"
        self.data = self.folder / "data"
        self.data.mkdir()

    @staticmethod
    def _free_port():
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def _accepts(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.3):
                return True
        except OSError:
            return False

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


# MARK: A TCP echo server for port forwarding

class EchoServer(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(64)
        self.port = self.listener.getsockname()[1]

    def run(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.echo, args=(connection,), daemon=True).start()

    @staticmethod
    def echo(connection):
        with connection:
            while data := connection.recv(1 << 16):
                connection.sendall(data)

    def stop(self):
        self.listener.close()


def heap_live_mb(pid):
    """Bytes the app still holds in malloc, as opposed to freed memory the allocator keeps for reuse."""
    try:
        out = subprocess.run(["heap", str(pid)], capture_output=True, text=True, timeout=60).stdout
        for line in out.splitlines():
            if line.startswith("All zones:") and "bytes)" in line:
                return round(int(line.split("(")[1].split()[0]) / (1 << 20), 1)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        pass
    return None


# MARK: A web server for the browser panel

class PageServer(threading.Thread):
    """Serves numbered pages with some weight to them, and a page that keeps a cookie, on 127.0.0.1."""

    def __init__(self):
        super().__init__(daemon=True)

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if self.path.startswith("/cookie"):
                    body = ("<!doctype html><title>cookie</title><script>"
                            "if (document.cookie.includes('stress=1')) document.title = 'cookie kept';"
                            "else { document.cookie = 'stress=1; path=/'; document.title = 'cookie set'; }</script>")
                else:
                    name = self.path.strip("/").replace("page/", "Page ") or "Page 0"
                    rows = "".join(f"<tr><td>{i}</td><td>{'x' * 60}</td></tr>" for i in range(2000))
                    body = (f"<!doctype html><title>{name}</title><style>td{{padding:2px}}</style>"
                            f"<h1>{name}</h1><canvas id=c width=600 height=300></canvas><table>{rows}</table>"
                            "<script>const g=document.getElementById('c').getContext('2d');"
                            "for(let i=0;i<500;i++){g.fillStyle=`hsl(${i},70%,50%)`;g.fillRect(i%600,i%300,40,40)}</script>")
                data = body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]

    def run(self):
        self.server.serve_forever()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def webkit_processes():
    """PIDs of WebKit's page processes, which hold a page's memory apart from the app."""
    out = subprocess.run(["pgrep", "-f", "com.apple.WebKit.WebContent"], capture_output=True, text=True).stdout
    return {int(pid) for pid in out.split()}


# MARK: MCP client

class MCPClient:
    def __init__(self, workspace):
        self.process = subprocess.Popen([str(CLI), "mcp", "--workspace", str(workspace)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("gloamux mcp closed its output")
        reply = json.loads(line)
        if "error" in reply:
            raise RuntimeError(f"MCP error: {reply['error']}")
        return reply["result"]

    def notify(self, method):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.process.stdin.flush()

    def tool(self, name, arguments=None):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise RuntimeError(f"{name}: {text}")
        return json.loads(text)

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()


# MARK: The run

class StressRun:
    def __init__(self, options):
        self.options = options
        self.scale = 0.2 if options.quick else 1.0
        self.out = Path(options.out or tempfile.mkdtemp(prefix=f"gloamux-stress-{datetime.datetime.now():%Y%m%d-%H%M%S}-"))
        self.out.mkdir(parents=True, exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix="gloamux-stress-work-"))
        self.workspace = self.scratch / "workspace"
        self.cli = CLIRunner(self.workspace)
        self.sampler = Sampler(self.out / "samples.csv")
        self.results = []
        self.app = None
        self.sshd = None

    def n(self, full, minimum=1):
        return max(minimum, int(full * self.scale))

    # Each phase records pass or fail, how long it took, its own figures, and what the CLI processes it ran cost.
    def phase(self, name, function):
        print(f"▶ {name}", flush=True)
        self.sampler.phase = name
        before_children = resource.getrusage(resource.RUSAGE_CHILDREN)
        before_app = process_stats(self.app.pid) if self.app else None
        start = time.monotonic()
        entry = {"phase": name, "passed": False, "metrics": {}}
        try:
            entry["metrics"] = function() or {}
            entry["passed"] = True
        except Exception as error:  # noqa: BLE001 - every failure belongs in the report
            entry["error"] = str(error)[:600]
        if self.app and self.app.poll() is not None and not getattr(self, "app_exit_noted", False):
            self.app_exit_noted = True
            entry["passed"] = False
            entry["error"] = (f"the app exited with status {self.app.returncode} during this phase; "
                              "see ~/Library/Logs/DiagnosticReports for a crash report. " + entry.get("error", ""))[:600]
        entry["seconds"] = round(time.monotonic() - start, 2)
        after_children = resource.getrusage(resource.RUSAGE_CHILDREN)
        entry["cli_cpu_seconds"] = round((after_children.ru_utime - before_children.ru_utime)
                                         + (after_children.ru_stime - before_children.ru_stime), 2)
        after_app = process_stats(self.app.pid) if self.app else None
        if before_app and after_app:
            entry["app_cpu_seconds"] = round(after_app["cpu_seconds"] - before_app["cpu_seconds"], 2)
        time.sleep(1.1)   # one more sample inside the phase
        window = self.sampler.window(name)
        cpu = [row["app_cpu"] for row in window if "app_cpu" in row]
        rss = [row["app_memory_mb"] for row in window if "app_memory_mb" in row]
        if cpu:
            entry["app_cpu_avg"] = round(statistics.mean(cpu), 1)
            entry["app_cpu_peak"] = round(max(cpu), 1)
        if rss:
            entry["app_memory_peak_mb"] = round(max(rss), 1)
        self.results.append(entry)
        status = "✓" if entry["passed"] else "✗ " + entry.get("error", "")
        print(f"  {status}  {entry['seconds']} s  {json.dumps(entry['metrics'], ensure_ascii=False)[:300]}", flush=True)

    # MARK: Phases

    def cli_catalog(self, live):
        count = self.n(40 if live else 300, 10)
        prefix = "Live" if live else "Bulk"
        times = []
        for index in range(count):
            seconds, _ = self.cli("sessions", "add", f"{prefix} {index:04d}", "ssh", f"host{index}.invalid", "tester", 22)
            times.append(seconds)
        others = 0
        for index in range(self.n(30, 5)):
            kind = ["serial", "telnet", "mosh", "docker", "kubectl", "ssm"][index % 6]
            target = {"serial": f"/dev/cu.stress-{index}", "ssm": f"i-{index:017x}"}.get(kind, f"target{index}.invalid")
            self.cli("sessions", "add-other", f"{prefix} {kind} {index}", kind, target)
            others += 1
        list_times = [self.cli("sessions", "list")[0] for _ in range(self.n(20, 5))]
        listed = self.cli.json("sessions", "list")
        expected = sum(1 for item in listed if item["name"].startswith(prefix + " "))
        if expected != count + others:
            raise RuntimeError(f"expected {count + others} {prefix} sessions, found {expected}")
        return {"sessions_added": count + others, "add_ms_p50": round(percentile(times, 0.5) * 1000),
                "add_ms_p95": round(percentile(times, 0.95) * 1000), "list_ms_p50": round(percentile(list_times, 0.5) * 1000),
                "catalog_size": len(listed)}

    def config_round_trip(self):
        backup = self.scratch / "all.gloamuxconfig"
        seconds, _ = self.cli("config", "export", backup)
        line = (self.scratch / "all.gloamuxconfig.sha256").read_text().split()[0]
        if line != sha256_file(backup):
            raise RuntimeError("the .sha256 file does not match the export")
        if writes_installed_settings():
            # Importing writes the settings of the app's preferences domain, here the installed Gloamux's.
            return {"backup_kb": round(backup.stat().st_size / 1024), "export_s": round(seconds, 2),
                    "import": "left out: run with --app and a renamed copy to include it"}
        other = CLIRunner(self.scratch / "restored")
        restore_seconds, _ = other("config", "import", backup)
        original = sorted(item["name"] for item in self.cli.json("sessions", "list"))
        restored = sorted(item["name"] for item in other.json("sessions", "list"))
        if original != restored:
            raise RuntimeError("the restored workspace has different sessions")
        damaged = self.scratch / "damaged.gloamuxconfig"
        shutil.copy(backup, damaged)
        shutil.copy(self.scratch / "all.gloamuxconfig.sha256", self.scratch / "damaged.gloamuxconfig.sha256")
        with open(damaged, "ab") as handle:
            handle.write(b" ")
        _, _ = run([str(CLI), "config", "import", str(damaged), "--workspace", str(self.scratch / "refused")], check=False)
        if (self.scratch / "refused" / "sessions.json").exists() and \
                json.loads((self.scratch / "refused" / "sessions.json").read_text()).get("nodes"):
            raise RuntimeError("a damaged backup was imported")
        return {"backup_kb": round(backup.stat().st_size / 1024), "export_s": round(seconds, 2), "import_s": round(restore_seconds, 2)}

    def prepare_fixture(self):
        self.sshd = LocalSSHD(self.scratch / "sshd")
        self.sampler.sshd_pid = self.sshd.process.pid
        self.cli("hosts", "trust", f"[127.0.0.1]:{self.sshd.port}", self.sshd.host_key, self.sshd.fingerprint)
        self.cli("sessions", "add", "Fixture", "ssh", "127.0.0.1", self.sshd.user, self.sshd.port)
        self.cli("sessions", "auth", "Fixture", "key", self.sshd.client_key)
        return {"port": self.sshd.port}

    def files_big(self, protocol):
        megabytes = self.n(512, 32)
        source = self.scratch / f"big-{protocol}.bin"
        with open(source, "wb") as handle:
            block = os.urandom(1 << 20)
            for _ in range(megabytes):
                handle.write(block)
        remote = self.sshd.data / f"big-{protocol}.bin"
        back = self.scratch / f"big-{protocol}-back.bin"
        up, _ = self.cli("files", "put", "--session", "Fixture", "--protocol", protocol, source, remote, timeout=1800)
        down, _ = self.cli("files", "get", "--session", "Fixture", "--protocol", protocol, remote, back, timeout=1800)
        if sha256_file(source) != sha256_file(back):
            raise RuntimeError("the downloaded file differs from the upload")
        for path in (source, back, remote):
            path.unlink()
        return {"megabytes": megabytes, "upload_MBps": round(megabytes / up, 1), "download_MBps": round(megabytes / down, 1)}

    def files_tree(self):
        files = self.n(2000, 200)
        tree = self.scratch / "tree"
        for index in range(files):
            folder = tree / f"dir{index % 20:02d}" / f"sub{index % 3}"
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"file{index:05d}.txt").write_bytes(os.urandom(random.randint(0, 8192)))
        remote = self.sshd.data / "tree"
        back = self.scratch / "tree-back"
        up, _ = self.cli("files", "put", "--session", "Fixture", "--recursive", tree, remote, timeout=1800)
        down, _ = self.cli("files", "get", "--session", "Fixture", "--recursive", remote, back, timeout=1800)
        if tree_digest(tree) != tree_digest(back):
            raise RuntimeError("the downloaded folder differs from the upload")
        removed, _ = self.cli("files", "rm", "--session", "Fixture", "--recursive", remote, timeout=1800)
        if remote.exists():
            raise RuntimeError("rm --recursive left the folder behind")
        return {"files": files, "upload_files_per_s": round(files / up), "download_files_per_s": round(files / down),
                "remove_s": round(removed, 2)}

    def connection_churn(self):
        sequential = self.n(40, 10)
        times = [self.cli("files", "pwd", "--session", "Fixture")[0] for _ in range(sequential)]
        workers, rounds = 8, self.n(5, 2)

        def one(_):
            try:
                self.cli("files", "ls", "--session", "Fixture", self.sshd.data)
                return True
            except RuntimeError:
                return False

        start = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(workers) as pool:
            outcomes = list(pool.map(one, range(workers * rounds)))
        wall = time.monotonic() - start
        failures = outcomes.count(False)
        if failures:
            raise RuntimeError(f"{failures} of {len(outcomes)} parallel connections failed")
        return {"connect_ms_p50": round(percentile(times, 0.5) * 1000), "connect_ms_p95": round(percentile(times, 0.95) * 1000),
                "parallel_connections": workers * rounds, "parallel_per_s": round(workers * rounds / wall, 1), "failures": failures}

    def benchmark(self):
        megabytes = self.n(64, 8)
        _, out = run([str(CLI), "benchmark", "--megabytes", str(megabytes), "--json"], timeout=600)
        data = json.loads(out)
        figures = {"echo_p99_ms": round(data.get("echoP99", 0) * 1000, 2)}
        for item in data.get("results", []):
            figures[item["workload"] + " MB/s"] = round(item["megabytesPerSecond"], 1)
        return figures

    def start_app(self):
        access = {"enabled": True, "sessions": []}
        fixture = next(item for item in self.cli.json("sessions", "list") if item["name"] == "Fixture")
        access["sessions"].append(fixture["id"])
        # Only this throwaway workspace: the run turns agent access on here, as a user would in Settings › Agents.
        (self.workspace / "agent-access.json").write_text(json.dumps(access))
        self.app = subprocess.Popen([str(APP_BINARY), "--workspace", str(self.workspace)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.sampler.app_pid = self.app.pid
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if self.app.poll() is not None:
                raise RuntimeError("the app exited during launch")
            if self.cli("tabs", "list", check=False, timeout=30)[1].strip().startswith("["):
                launched = round(40 - (deadline - time.monotonic()), 1)
                time.sleep(3)
                return {"launch_s": launched, "idle_memory_mb": footprint_mb(self.app.pid)}
            time.sleep(0.5)
        raise RuntimeError("the app did not answer the CLI within 40 seconds")

    def wait_for(self, tab, text, seconds=120, lines=40):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            data = self.cli.json("tabs", "read", tab, lines)
            if text in data["text"]:
                return
            time.sleep(0.3)
        raise RuntimeError(f"{text} did not appear in tab {tab}")

    def live_tabs(self):
        local_count, ssh_count = self.n(20, 4), self.n(10, 2)
        lines = self.n(1_000_000, 100_000)
        tabs = []
        for _ in range(local_count):
            tabs.append(("local", self.cli.json("tabs", "local")["id"]))
        for _ in range(ssh_count):
            tabs.append(("ssh", self.cli.json("tabs", "open", "Fixture")["id"]))
        connect_start = time.monotonic()
        for kind, tab in tabs:
            deadline = time.monotonic() + 60
            while True:
                info = self.cli.json("tabs", "show", tab)
                if info.get("terminalReady"):
                    break
                if info.get("error"):
                    raise RuntimeError(f"{kind} tab: {info['error']}")
                if time.monotonic() > deadline:
                    raise RuntimeError(f"{kind} tab did not become ready")
                time.sleep(0.3)
        ready = time.monotonic() - connect_start
        time.sleep(1.5)   # let the shells print their prompts
        marker = uuid.uuid4().hex[:8]
        flood_start = time.monotonic()
        for index, (_, tab) in enumerate(tabs):
            # The shell computes the marker, so the echoed command line never matches it. -f %.0f: macOS seq
            # prints 1000000 as 1e+06.
            self.cli("tabs", "run", tab, f"seq -f %.0f 1 {lines}; echo DONE_{marker}_$(({index}+1))")
        for index, (_, tab) in enumerate(tabs):
            self.wait_for(tab, f"\nDONE_{marker}_{index + 1}\n", seconds=600, lines=5)
        flood = time.monotonic() - flood_start
        for kind, tab in tabs:
            tail = self.cli.json("tabs", "read", tab, 6)["text"]
            if f"\n{lines}\n" not in tail:
                raise RuntimeError(f"the last number of the output is missing in a {kind} tab: {tail[-160:]!r}")
        with_tabs = footprint_mb(self.app.pid)
        for _, tab in tabs:
            self.cli("tabs", "close", tab)
        # SwiftUI keeps the last values it drew until it draws again, closed tabs included; one more tab, opened
        # and closed, lets it draw and let them go, as any later change in the window would.
        nudge = self.cli.json("tabs", "local")["id"]
        time.sleep(1.5)
        self.cli("tabs", "close", nudge)
        time.sleep(3)
        after = footprint_mb(self.app.pid)
        live = heap_live_mb(self.app.pid)
        return {"local_tabs": local_count, "ssh_tabs": ssh_count, "all_ready_s": round(ready, 1),
                "lines_per_tab": lines, "output_s": round(flood, 1),
                "lines_per_s": round(lines * len(tabs) / flood), "memory_with_tabs_mb": with_tabs,
                "memory_after_close_mb": after, "heap_in_use_after_close_mb": live}

    def browser_panel(self):
        server = PageServer()
        server.start()
        base = f"http://127.0.0.1:{server.port}"
        before = webkit_processes()
        try:
            def pages():
                return self.cli.json("web", "list")["pages"]

            def settle(seconds=120):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    listed = pages()
                    if all(not page["loading"] and page["title"] for page in listed):
                        return listed
                    time.sleep(0.3)
                raise RuntimeError("pages in the browser panel did not finish loading")

            self.cli("web", "show", f"{base}/page/0")
            count = self.n(40, 25)
            open_times = []
            start = time.monotonic()
            for index in range(1, count + 1):
                open_times.append(self.cli("web", "open", f"{base}/page/{index}")[0])
            listed = settle()
            loaded = time.monotonic() - start
            limit = 20
            if len(listed) != limit:
                raise RuntimeError(f"the panel kept {len(listed)} pages, not {limit}")
            expected = {f"Page {index}" for index in range(count - limit + 1, count + 1)}
            if {page["title"] for page in listed} != expected:
                raise RuntimeError("the panel did not keep the newest pages")
            processes = webkit_processes() - before
            web_memory = round(sum(footprint_mb(pid) or 0 for pid in processes), 1)
            with_pages = footprint_mb(self.app.pid)

            # Navigation in one page: forward through pages, then back through its history.
            steps = self.n(60, 15)
            nav_start = time.monotonic()
            for index in range(steps):
                self.cli("web", "go", "current", f"{base}/page/nav{index}")
            settle()
            for _ in range(min(steps, 10)):
                self.cli("web", "back", "current")
                time.sleep(0.2)
            settle()
            navigation = time.monotonic() - nav_start

            self.cli("web", "go", "current", f"{base}/cookie")
            self.wait_title("cookie set")
            self.cli("web", "reload", "current")
            self.wait_title("cookie kept")
            self.cli("web", "clear-data")
            self.wait_title("cookie set")
            if self.cli.json("web", "zoom", "current", 150)["zoom"] != 150:
                raise RuntimeError("zoom was not set")

            for page in pages():
                self.cli("web", "close", page["id"])
            self.cli("web", "hide")
            time.sleep(4)
            left = webkit_processes() - before
            return {"pages_opened": count + 1, "pages_kept": limit, "open_ms_p50": round(percentile(open_times, 0.5) * 1000),
                    "all_loaded_s": round(loaded, 1), "navigations": steps + 10, "navigation_s": round(navigation, 1),
                    "webkit_processes": len(processes), "webkit_memory_mb": web_memory,
                    "app_memory_with_pages_mb": with_pages, "app_memory_after_close_mb": footprint_mb(self.app.pid),
                    "webkit_processes_after_close": len(left)}
        finally:
            server.stop()

    def wait_title(self, title, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            status = self.cli.json("web", "status", "current")
            if status.get("title") == title and not status.get("loading"):
                return
            time.sleep(0.2)
        raise RuntimeError(f"the page did not show {title!r}")

    def wide_text_and_images(self):
        lines = self.n(200_000, 40_000)
        images = self.n(500, 100)
        text = self.scratch / "wide.txt"
        with open(text, "w", encoding="utf-8") as handle:
            for index in range(lines):
                handle.write(f"第{index}行 終端機測試 日本語のテキスト 한국어 텍스트 ┃ ━━━ 🙂\n")
        pictures = self.scratch / "kitty.txt"
        pixel = base64.b64encode(bytes(random.randrange(256) for _ in range(16 * 16 * 3))).decode()
        with open(pictures, "w") as handle:
            for _ in range(images):
                handle.write(f"\x1b_Ga=T,f=24,s=16,v=16,q=2;{pixel}\x1b\\\n")
        tab = self.cli.json("tabs", "local")["id"]
        deadline = time.monotonic() + 60
        while not self.cli.json("tabs", "show", tab).get("terminalReady"):
            if time.monotonic() > deadline:
                raise RuntimeError("the local tab did not start")
            time.sleep(0.3)
        time.sleep(1.5)
        marker = uuid.uuid4().hex[:8]
        start = time.monotonic()
        self.cli("tabs", "run", tab, f"cat {pictures} {text}; echo DONE_{marker}_$((1+1))")
        self.wait_for(tab, f"\nDONE_{marker}_2\n", seconds=600, lines=5)
        seconds = time.monotonic() - start
        tail = self.cli.json("tabs", "read", tab, 6)["text"]
        if f"第{lines - 1}行" not in tail:
            raise RuntimeError(f"the last line of the text is missing: {tail[-160:]!r}")
        memory = footprint_mb(self.app.pid)
        self.cli("tabs", "close", tab)
        return {"lines": lines, "images": images, "seconds": round(seconds, 1),
                "megabytes_per_s": round(text.stat().st_size / (1 << 20) / seconds, 1), "app_memory_mb": memory}

    def live_forward(self):
        tab = self.cli.json("tabs", "open", "Fixture")["id"]
        deadline = time.monotonic() + 60
        while not self.cli.json("tabs", "show", tab).get("terminalReady"):
            if time.monotonic() > deadline:
                raise RuntimeError("the SSH tab did not connect")
            time.sleep(0.3)
        echo = EchoServer()
        echo.start()
        started = self.cli.json("forwards", "start", tab, "local", 0, "127.0.0.1", echo.port)
        port = started["boundPort"]
        times = []
        for index in range(self.n(200, 40)):
            start = time.monotonic()
            payload = f"ping {index}\n".encode()
            with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
                connection.sendall(payload)
                answer = b""
                while len(answer) < len(payload) and (data := connection.recv(64)):
                    answer += data
            if answer != payload:
                echo.stop()
                raise RuntimeError(f"connection {index + 1} through the forward got {answer!r} back")
            times.append(time.monotonic() - start)
        megabytes = self.n(256, 32)
        block = os.urandom(1 << 20)
        expected = hashlib.sha256(block * megabytes).hexdigest()
        with socket.create_connection(("127.0.0.1", port), timeout=30) as connection:
            digest = hashlib.sha256()
            received = 0

            def reader():
                nonlocal received
                while received < megabytes << 20 and (data := connection.recv(1 << 16)):
                    digest.update(data)
                    received += len(data)

            thread = threading.Thread(target=reader)
            start = time.monotonic()
            thread.start()
            for _ in range(megabytes):
                connection.sendall(block)
            thread.join(timeout=300)
            seconds = time.monotonic() - start
        echo.stop()
        if digest.hexdigest() != expected:
            raise RuntimeError(f"the data came back different through the forward ({received} bytes)")
        self.cli("forwards", "stop", tab, started["id"])
        self.cli("tabs", "close", tab)
        return {"forwarded_connections": len(times), "connection_ms_p50": round(percentile(times, 0.5) * 1000, 1),
                "connection_ms_p95": round(percentile(times, 0.95) * 1000, 1), "round_trip_megabytes": megabytes,
                "round_trip_MBps": round(megabytes / seconds, 1)}

    def live_catalog(self):
        return self.cli_catalog(live=True)

    def mcp(self):
        client = MCPClient(self.workspace)
        try:
            hello = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                                  "clientInfo": {"name": "gloamux-stress", "version": "1"}})
            client.notify("notifications/initialized")
            tools = [tool["name"] for tool in client.request("tools/list")["tools"]]
            times = []
            for _ in range(self.n(300, 50)):
                start = time.monotonic()
                listed = client.tool("list_sessions")
                times.append(time.monotonic() - start)
            if [item["name"] for item in listed] != ["Fixture"]:
                raise RuntimeError(f"agents saw {[item['name'] for item in listed]}, not only the allowed session")
            opened = client.tool("open_session", {"session": "Fixture"})
            deadline = time.monotonic() + 60
            while not self.cli.json("tabs", "show", opened["tab"]).get("terminalReady"):
                if time.monotonic() > deadline:
                    raise RuntimeError("the session the agent opened did not connect")
                time.sleep(0.3)
            proposal = client.tool("propose_command", {"session": "Fixture", "command": "uptime", "reason": "stress test"})
            status = client.tool("get_proposal", {"proposal": proposal["proposal"]})["status"]
            if status != "waiting":
                raise RuntimeError(f"a proposed command was {status} without review")
            refused = 0
            try:
                client.tool("open_session", {"session": "Bulk 0000"})
            except RuntimeError:
                refused = 1
            if not refused:
                raise RuntimeError("an agent opened a session that was not allowed")
            history = json.loads((self.workspace / "agent-activity.json").read_text())
            self.cli("tabs", "close", opened["tab"])
            return {"protocol": hello["protocolVersion"], "tools": len(tools), "calls": len(times),
                    "call_ms_p50": round(percentile(times, 0.5) * 1000), "call_ms_p95": round(percentile(times, 0.95) * 1000),
                    "history_events": len(history), "proposal_status": status}
        finally:
            client.close()

    # MARK: Driving it

    def execute(self):
        if not CLI.exists() or not APP_BINARY.exists():
            raise SetupError(f"{APP} is missing. Build it with Gloamux/scripts/package-app.sh first.")
        self.started = datetime.datetime.now()
        self.battery_before = battery()
        self.thermal_before = thermal()
        self.sampler.start()
        try:
            self.phase("CLI catalog (offline)", lambda: self.cli_catalog(live=False))
            self.phase("Config export and import", self.config_round_trip)
            self.phase("Test SSH server", self.prepare_fixture)
            if self.sshd:
                self.phase("SFTP large file", lambda: self.files_big("sftp"))
                self.phase("SCP large file", lambda: self.files_big("scp"))
                self.phase("Folder transfer (recursive)", self.files_tree)
                self.phase("SSH connection churn", self.connection_churn)
            self.phase("Terminal benchmark", self.benchmark)
            if not self.options.no_app:
                self.phase("App launch", self.start_app)
                if self.app and self.app.poll() is None:
                    # Phases below need the app; once it is gone they fail fast with the reason above.
                    self.phase("CLI catalog (app running)", self.live_catalog)
                    if self.sshd:
                        self.phase("Tabs and terminal output", self.live_tabs)
                        self.phase("Port forwarding", self.live_forward)
                        self.phase("MCP agents", self.mcp)
                    self.phase("Wide text and inline images", self.wide_text_and_images)
                    self.phase("Browser panel", self.browser_panel)
                    self.phase("App idle after load", lambda: (time.sleep(10), {})[1])
        finally:
            self.finish()

    def finish(self):
        if self.app and self.app.poll() is None:
            self.app.send_signal(signal.SIGTERM)
            try:
                self.app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.app.kill()
        if self.sshd:
            self.sshd.stop()
        self.sampler.stop()
        self.report()
        if not self.options.keep:
            shutil.rmtree(self.scratch, ignore_errors=True)

    def report(self):
        samples = self.sampler.samples
        app_cpu = [row["app_cpu"] for row in samples if "app_cpu" in row]
        app_rss = [row["app_memory_mb"] for row in samples if "app_memory_mb" in row]
        threads = [row["app_threads"] for row in samples if "app_threads" in row]
        files = [row["app_files"] for row in samples if row.get("app_files")]
        load = [row["load1"] for row in samples]
        summary = {
            "started": self.started.isoformat(timespec="seconds"),
            "mac": f"{platform.mac_ver()[0]} {platform.machine()}",
            "cores": os.cpu_count(),
            "mode": "quick" if self.options.quick else "full",
            "battery_before": self.battery_before, "battery_after": battery(),
            "thermal_before": self.thermal_before, "thermal_after": thermal(),
            "app_cpu_avg": round(statistics.mean(app_cpu), 1) if app_cpu else None,
            "app_cpu_peak": max(app_cpu) if app_cpu else None,
            "app_memory_peak_mb": max(app_rss) if app_rss else None,
            "app_threads_peak": max(threads) if threads else None,
            "app_open_files_peak": max(files) if files else None,
            "load_peak": max(load) if load else None,
            "passed": all(entry["passed"] for entry in self.results),
            "phases": self.results,
        }
        (self.out / "report.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
        lines = [f"# Gloamux stress test, {summary['started']}", "",
                 f"{summary['mac']}, {summary['cores']} cores, {summary['mode']} run. "
                 f"Battery {summary['battery_before']} → {summary['battery_after']}. Thermal: {summary['thermal_after']}.", "",
                 "| Phase | Result | Time (s) | App CPU avg / peak (%) | App memory peak (MB) | App CPU (s) | CLI CPU (s) | Figures |",
                 "|---|---|---|---|---|---|---|---|"]
        for entry in self.results:
            figures = ", ".join(f"{key} {value}" for key, value in entry["metrics"].items())
            if not entry["passed"]:
                figures = "**" + entry.get("error", "failed").replace("|", "/") + "**"
            cpu = f"{entry.get('app_cpu_avg', '–')} / {entry.get('app_cpu_peak', '–')}"
            lines.append(f"| {entry['phase']} | {'pass' if entry['passed'] else 'FAIL'} | {entry['seconds']} | {cpu} | "
                         f"{entry.get('app_memory_peak_mb', '–')} | {entry.get('app_cpu_seconds', '–')} | {entry['cli_cpu_seconds']} | {figures} |")
        lines += ["", "## App over the whole run", "",
                  f"- CPU: average {summary['app_cpu_avg']}%, peak {summary['app_cpu_peak']}% (100% is one core)",
                  f"- Memory: peak {summary['app_memory_peak_mb']} MB (physical footprint, as Activity Monitor shows it)",
                  f"- Threads: peak {summary['app_threads_peak']}; open files: peak {summary['app_open_files_peak']}",
                  f"- Mac load average: peak {summary['load_peak']}", "",
                  "Samples, once a second: `samples.csv`. Everything ran in a throwaway workspace against a throwaway "
                  "sshd on 127.0.0.1 with a key made for this run.", ""]
        (self.out / "report.md").write_text("\n".join(lines))
        print("\n".join(lines))
        print(f"Report: {self.out / 'report.md'}")


def main():
    parser = argparse.ArgumentParser(description="Stress-test Gloamux and report what it costs this Mac.")
    parser.add_argument("--quick", action="store_true", help="smaller loads, about a fifth of a full run")
    parser.add_argument("--no-app", action="store_true", help="skip the phases that start the app")
    parser.add_argument("--out", help="folder for report.md, report.json, and samples.csv")
    parser.add_argument("--keep", action="store_true", help="keep the throwaway workspace and server files")
    parser.add_argument("--app", help="the Gloamux app to test, such as a renamed copy (default: build/Gloamux.app)")
    options = parser.parse_args()
    if options.app:
        use_app(options.app)
    stress = StressRun(options)
    try:
        stress.execute()
    except SetupError as error:
        print(f"Setup problem: {error}", file=sys.stderr)
        return 2
    return 0 if all(entry["passed"] for entry in stress.results) else 1


if __name__ == "__main__":
    sys.exit(main())
