#!/usr/bin/env python3
"""Controller TUI contract checks, without a SQL server or HTTP mutations.

Run after building mz-watch:
    /tmp/mz-watch-terminal-env/bin/python scripts/controller-smoke.py

Requires pyte, like terminal-smoke.py. Only temporary configuration is written.
Failures deliberately omit frames, configuration and connection diagnostics.
"""

import copy
import importlib.util
import json
import os
import re
import select
import tempfile
import threading
import time
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "terminal_smoke", ROOT / "scripts/terminal-smoke.py"
)
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)

NAME_PATTERN = r"%report\_% +&é"
ID_PATTERN = "u_%"
SHARED = "shared.invalid:41001"
UNIQUE = "unique.invalid:41002"
SECRET = "controller-smoke-secret"
CONNINFO = f"user=smoke dbname=smoke password={SECRET} connect_timeout=1"
MAX_U64 = 18446744073709551615


class Terminal(SMOKE.Terminal):
    """Evaluate assertions after complete, settled frames, not PTY fragments."""

    def pump(self, timeout):
        readable, _, _ = select.select([self.fd], [], [], timeout)
        while readable:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                raise AssertionError("TUI exited while awaiting a frame") from None
            assert data, "TUI closed its terminal"
            self.stream.feed(self.decoder.decode(data))
            if b"\x1b[6n" in data:
                self.send(
                    f"\x1b[{self.screen.cursor.y + 1};{self.screen.cursor.x + 1}R"
                )
            readable, _, _ = select.select([self.fd], [], [], 0)

    def settle(self):
        deadline = time.monotonic() + 0.3
        while time.monotonic() < deadline:
            self.pump(0.02)

    def wait(self, predicate, promise, timeout=12):
        deadline = time.monotonic() + timeout
        candidate = None
        since = time.monotonic()
        while time.monotonic() < deadline:
            self.pump(0.02)
            frame = "\n".join(self.screen.display)
            if "ADD CONTROLLER" not in frame:
                assert SECRET not in frame, "connection credentials must be redacted"
            if frame != candidate or not predicate(frame):
                candidate = frame
                since = time.monotonic()
            elif time.monotonic() - since >= 0.12:
                return
        raise AssertionError(f"Timed out: {promise}")


def sql_like(value, pattern):
    """Fixture-side SQL LIKE, including backslash escapes, never client filtering."""
    parts = []
    escaped = False
    for char in pattern:
        if escaped:
            parts.append(re.escape(char))
            escaped = False
        elif char == "\\":
            escaped = True
        else:
            parts.append({"%": ".*", "_": "."}.get(char, re.escape(char)))
    if escaped:
        parts.append(re.escape("\\"))
    return re.fullmatch("".join(parts), value, re.DOTALL) is not None


def processes():
    return [{"process_id": 0, "status": "online", "restart_count": 3}]


def adapter(index, address, generation):
    return {
        "id": f"a{index}",
        "name": f"front{index}",
        "generation": generation,
        "service": f"adapter-{index}",
        "endpoints": {
            "sql-external": [address],
            "sql-internal": ["internal.invalid:41003"],
            "http-external": ["http.invalid:41004"],
            "sql-custom": ["custom.invalid:41005"],
        },
        "observed_processes": processes(),
        "readiness": {"ready": False, "error": "warming", "changed_at": 1},
        "provisioning_error": None,
    }


def inventory(unique, generation=7):
    return {
        "generation": generation,
        "adapters": [adapter(1, SHARED, generation)]
        + ([adapter(2, UNIQUE, generation)] if unique else []),
        "replicas": [
            {
                "cluster_id": "u1",
                "replica_id": "u2",
                "cluster_name": "compute",
                "replica_name": "worker",
                "generation": generation,
                "service": "replica",
                "endpoints": {"compute": ["replica.invalid:41006"]},
                "observed_processes": processes(),
                "provisioning_error": None,
            }
        ],
        "pubsub": {
            "service": "pubsub",
            "cpu_limit": None,
            "memory_limit": None,
            "endpoints": {"pubsub": ["pubsub.invalid:41007"]},
            "observed_processes": {"0": processes()[0]},
            "provisioning_error": None,
        },
    }


def collections(name):
    return [
        {"id": "u10", "name": f"{name}.report_null +&é", "since": None},
        {"id": "u11", "name": f"{name}.report_empty +&é", "since": []},
        {
            "id": "u12",
            "name": f"{name}.report_large +&é",
            "since": [9007199254740993, MAX_U64],
        },
        {"id": "u13", "name": f"{name}.other", "since": [1]},
        {"id": "s10", "name": f"{name}.report_wrong_id +&é", "since": [2]},
    ]


class Fixture:
    def __init__(self, name, unique):
        self.lock = threading.Lock()
        self.inventory = inventory(unique)
        self.collections = collections(name)
        self.failure = False
        self.slow_next = False
        self.slow_started = threading.Event()
        self.slow_done = threading.Event()
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            do_PUT = do_POST
            do_PATCH = do_POST
            do_DELETE = do_POST
            do_HEAD = do_POST
            do_OPTIONS = do_POST
            do_CONNECT = do_POST
            do_TRACE = do_POST

            def respond(self):
                parsed = urlsplit(self.path)
                with fixture.lock:
                    fixture.requests.append((self.command, self.path))
                    is_inventory = parsed.path == "/fixture/api/inventory"
                    slow = is_inventory and fixture.slow_next
                    if slow:
                        fixture.slow_next = False
                    failure = is_inventory and fixture.failure
                    payload = copy.deepcopy(
                        fixture.inventory if is_inventory else fixture.collections
                    )
                if slow:
                    fixture.slow_started.set()
                    fixture.slow_done.wait(4)
                    fixture.slow_done.set()
                status = 200
                if self.command != "GET" or parsed.path not in (
                    "/fixture/api/inventory",
                    "/fixture/api/collections",
                ):
                    status, payload = 405, {}
                elif failure:
                    status, payload = 503, {}
                elif not is_inventory:
                    query = parse_qs(parsed.query, keep_blank_values=True)
                    payload = [
                        row
                        for row in payload
                        if all(
                            key not in query or sql_like(row[key], query[key][0])
                            for key in ("id", "name")
                        )
                    ]
                body = json.dumps(payload, ensure_ascii=False).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/fixture"

    def close(self):
        self.slow_done.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def calls(self):
        with self.lock:
            return list(self.requests)

    def filtered(self, since=0):
        expected = {"id": [ID_PATTERN], "name": [NAME_PATTERN]}
        for method, target in self.calls()[since:]:
            parsed = urlsplit(target)
            if method == "GET" and parse_qs(parsed.query) == expected:
                # The decoded patterns alone would miss a literal + sent as +.
                return all(
                    f"{key}={quote(value[0], safe='')}" in parsed.query
                    for key, value in expected.items()
                )
        return False


def cards(frame):
    lines = frame.splitlines()
    return [
        lines[row : row + 6] for row, line in enumerate(lines) if "Endpoint: " in line
    ]


def check_cards(terminal, count, sources, absent=()):
    def correct(frame):
        found = cards(frame)
        if len(found) != count or any(len(card) != 6 for card in found):
            return False
        source_lines = "\n".join(card[1] for card in found)
        return (
            all(source in source_lines for source in sources)
            and all(source not in source_lines for source in absent)
            and all("[discovered " in card[1] for card in found)
            and all(re.search(r"\w+/g\d+/a\d+ \(front\d+\)", card[0]) for card in found)
            and all(
                re.search(r"ok 0  errors \d+  skipped \d+  wins 0", card[4])
                for card in found
            )
            and "internal.invalid" not in frame
            and "custom.invalid" not in frame
        )

    terminal.wait(correct, "deduplicated endpoint cards with current discovery sources")


def add_controller(terminal, name, url):
    terminal.send("c")
    terminal.contains("ADD CONTROLLER")
    terminal.send(name + "\t\x01\x0b" + url + "\t\x01\x0b" + CONNINFO + "\r")
    terminal.wait(
        lambda frame: "ADD CONTROLLER" not in frame and f"Controller: {name}" in frame,
        "Enter saves the controller form",
    )


def check_collections(terminal, name, filtered=False):
    def correct(frame):
        if f"{name} [live] [h/l]" not in frame:
            return False
        rows = frame.splitlines()
        for ident, value in (("u10", "unknown"), ("u11", "[]"), ("u12", str(MAX_U64))):
            row = next((line for line in rows if re.search(rf"\b{ident}\b", line)), "")
            if f"{name}.report_" not in row or value not in row:
                return False
            if ident == "u12" and "9007199254740993" not in row:
                return False
        return all((ident not in frame) == filtered for ident in ("u13", "s10"))

    terminal.wait(
        correct, "selected controller collections and exact catalog since frontiers"
    )


def assert_saved(path, east, west):
    saved = path.read_text()
    assert path.stat().st_mode & 0o777 == 0o600, "private saved configuration"
    assert east.url in saved and west.url in saved, "both controllers persisted"
    for address in (SHARED, UNIQUE, "internal.invalid", "custom.invalid", "/g7/a1"):
        assert address not in saved, (
            "derived discovery addresses and sources are not persisted"
        )
    return saved


def main():
    executable = ROOT / "zig-out/bin/mz-watch"
    assert executable.is_file(), "Build mz-watch before running controller-smoke.py"
    with ExitStack() as stack:
        east = Fixture("east", unique=True)
        stack.callback(east.close)
        west = Fixture("west", unique=False)
        stack.callback(west.close)
        home = stack.enter_context(
            tempfile.TemporaryDirectory(prefix="mz-watch-controllers-")
        )
        path = Path(home) / "mz-watch/config.zon"
        path.parent.mkdir(mode=0o700)
        path.write_text(".{}")
        path.chmod(0o600)
        terminal = Terminal(executable, home)
        stack.callback(lambda: terminal.close())
        terminal.resize(220, 52)
        terminal.contains("+ Controller")
        terminal.send("3")
        terminal.contains("No controllers")
        add_controller(terminal, "east", east.url)
        terminal.contains("Adapter: front2 (a2)")
        add_controller(terminal, "west", west.url)
        terminal.send("3" + "k" * 12)
        terminal.wait(
            lambda frame: all(
                label in frame
                for label in (
                    "Controller: east  [live]",
                    "Controller: west  [live]",
                    "Adapter: front1 (a1)",
                    "Adapter: front2 (a2)",
                    "Replica: compute.worker (u1/u2)",
                    "Pubsub",
                    "p0: online restarts 3  SQL not ready",
                    "sql-external=",
                    "sql-internal=",
                    "http-external=",
                    "sql-custom=",
                    "compute=replica.invalid:41006",
                    "pubsub=pubsub.invalid:41007",
                )
            ),
            "Services groups, distinct process/SQL readiness, and listener labels",
        )
        saved = assert_saved(path, east, west)
        terminal.close()

        # Seed a paused canary only after proving addition from an empty ZON.
        # No SQL runs in either phase: first no canaries, then only a paused one.
        saved, replacements = re.subn(
            r"\.canaries\s*=\s*\.\{\s*\}",
            '.canaries = .{ .{ .name = "paused", .sql = "SELECT 1", .paused = true } }',
            saved,
        )
        assert replacements == 1, "saved empty canary list can be seeded safely"
        path.write_text(saved)
        terminal = Terminal(executable, home)
        terminal.resize(220, 52)
        terminal.contains("Canary: paused  [paused]")
        terminal.send("2")
        check_cards(
            terminal,
            2,
            ("east/g7/a1 (front1)", "west/g7/a1 (front1)", "east/g7/a2 (front2)"),
        )
        terminal.send("4h")
        check_collections(terminal, "east")
        terminal.send("l")
        check_collections(terminal, "west")
        terminal.send("/")
        terminal.contains("COLLECTION FILTERS")
        terminal.send("\x1b]52;c;YmFkCmZpbHRlcg==\x1b\\\r")
        terminal.contains("Filters must be UTF-8 text without control characters.")
        terminal.send("\x1b")
        check_collections(terminal, "west")
        terminal.send("/")
        terminal.contains("COLLECTION FILTERS")
        terminal.send(NAME_PATTERN + "\t" + ID_PATTERN + "\r")
        check_collections(terminal, "west", filtered=True)
        terminal.wait(
            lambda _: east.filtered() and west.filtered(),
            "URL-encoded name AND ID filters sent to both servers",
        )
        # Restore a non-default selection, not the last controller loaded.
        terminal.send("h")
        check_collections(terminal, "east", filtered=True)
        saved = assert_saved(path, east, west)
        assert f'.collections_controller = "{east.url}"' in saved, (
            "selection persisted by URL"
        )
        assert (
            ".collection_name_filter" in saved and ".collection_id_filter" in saved
        ), "filter settings persisted"
        terminal.close()
        east_before, west_before = len(east.calls()), len(west.calls())
        terminal = Terminal(executable, home)
        terminal.resize(220, 52)
        terminal.contains("+ Controller")
        terminal.send("4")
        check_collections(terminal, "east", filtered=True)
        terminal.wait(
            lambda frame: (
                NAME_PATTERN in frame
                and ID_PATTERN in frame
                and east.filtered(east_before)
                and west.filtered(west_before)
            ),
            "restart restores selected controller and both server filters",
        )
        assert path.read_text() == saved, "restart does not rewrite configuration"
        terminal.send("l")
        check_collections(terminal, "west", filtered=True)

        with east.lock:
            east.slow_next = True
        terminal.wait(
            lambda _: east.slow_started.is_set(), "slow inventory request entered"
        )
        started = time.monotonic()
        with west.lock:
            west.collections[0]["since"] = [123456789]
        terminal.send("3")
        terminal.contains("SERVICES")
        terminal.send("4")
        terminal.wait(
            lambda frame: "west [live] [h/l]" in frame and "123456789" in frame,
            "UI navigation and other controller polling continue during slow HTTP",
            timeout=3,
        )
        assert time.monotonic() - started < 3 and not east.slow_done.is_set(), (
            "slow controller does not block UI or peer updates"
        )
        terminal.wait(lambda _: east.slow_done.is_set(), "slow fixture completed")

        with east.lock:
            east.failure = True
        terminal.send("3" + "k" * 12)
        terminal.contains("Controller: east  [stale / unavailable]")
        terminal.send("2")
        check_cards(
            terminal,
            2,
            ("east/g7/a1 (front1)", "west/g7/a1 (front1)", "east/g7/a2 (front2)"),
        )
        with east.lock:
            east.inventory = inventory(True, generation=8)
            east.failure = False
        check_cards(
            terminal,
            2,
            ("east/g8/a1 (front1)", "east/g8/a2 (front2)", "west/g7/a1 (front1)"),
            ("east/g7/",),
        )
        terminal.wait(
            lambda frame: all("east/g7/" not in card[0] for card in cards(frame)),
            "generation change refreshes card titles without duplicating targets",
        )
        with east.lock:
            east.inventory["adapters"] = []
        check_cards(terminal, 1, ("west/g7/a1 (front1)",), ("east/",))
        with east.lock:
            east.inventory = inventory(True, generation=9)
        check_cards(
            terminal,
            2,
            ("east/g9/a1 (front1)", "east/g9/a2 (front2)", "west/g7/a1 (front1)"),
        )

        terminal.send("3" + "k" * 12 + "jjjjk")
        terminal.contains("> Replica: compute.worker (u1/u2)")
        terminal.send("x")
        terminal.contains("Remove selected item?")
        terminal.contains("Controller (monitoring only): east")
        terminal.send("\x1b")
        terminal.wait(
            lambda frame: "Remove selected item?" not in frame,
            "cancel closes controller removal",
        )
        terminal.send("4")
        terminal.contains("west [live] [h/l]")
        terminal.send("3x")
        terminal.contains("Controller (monitoring only): east")
        terminal.send("\r")
        terminal.wait(
            lambda frame: (
                "Controller: east" not in frame and "Controller: west" in frame
            ),
            "removing a selected service stops its controller monitoring",
        )
        terminal.send("2")
        check_cards(terminal, 1, ("west/g7/a1 (front1)",), ("east/",))
        assert east.url not in path.read_text() and west.url in path.read_text(), (
            "removal persists only remaining controller"
        )
        # Drain any request already in flight, then observe a full polling interval.
        terminal.settle()
        east_count, west_count = len(east.calls()), len(west.calls())
        until = time.monotonic() + 1.6
        while time.monotonic() < until:
            terminal.pump(0.05)
        assert len(east.calls()) == east_count, "removed controller is no longer polled"
        assert len(west.calls()) > west_count, "other controller remains monitored"
        terminal.send("3kx\r2")
        terminal.contains("No endpoints")
        terminal.send("1")
        terminal.contains("OK 0  FAIL 0")
        assert SHARED not in path.read_text() and UNIQUE not in path.read_text(), (
            "derived SQL addresses never enter configuration"
        )
        terminal.close()
        for fixture in (east, west):
            assert all(
                method == "GET"
                and urlsplit(target).path
                in ("/fixture/api/inventory", "/fixture/api/collections")
                for method, target in fixture.calls()
            ), "monitoring never sends HTTP mutations"
    print(
        "PASS: controller forms/persistence, Services, collection filters/frontiers/restore, responsive polling, discovery dedup/staleness/removal, read-only HTTP"
    )


if __name__ == "__main__":
    main()
