#!/usr/bin/env python3
"""Exercise the real TUI through a PTY. Requires pyte and a disposable SQL endpoint."""

import codecs
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

import pyte


class Screen(pyte.Screen):
    def report_device_status(self, mode=0, **kwargs):
        # Private terminal queries (such as color-scheme support) are not
        # implemented by pyte. Leave them unanswered, like a basic terminal.
        if not kwargs.get("private"):
            super().report_device_status(mode)


class Terminal:
    def __init__(self, executable, config_home):
        self.closed = False
        self.screen = Screen(120, 32)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.environ["XDG_CONFIG_HOME"] = config_home
            # pyte understands semicolon SGR colors, not colon subparameters.
            os.environ["VAXIS_FORCE_LEGACY_SGR"] = "1"
            os.environ.pop("NO_COLOR", None)
            os.execv(str(executable), [str(executable)])
        self.resize(120, 32)

    def resize(self, cols, rows):
        self.screen.resize(rows, cols)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)

    def send(self, value):
        os.write(self.fd, value.encode())

    def click(self, col, row):
        self.send(f"\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m")

    def wait(self, predicate, promise, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate("\n".join(self.screen.display)):
                return
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    data = os.read(self.fd, 65536)
                except OSError as error:
                    raise AssertionError(f"TUI exited before: {promise}") from error
                self.stream.feed(self.decoder.decode(data))
                if b"\x1b[6n" in data:
                    self.send(
                        f"\x1b[{self.screen.cursor.y + 1};{self.screen.cursor.x + 1}R"
                    )
        # Do not dump the screen, which could contain connection credentials.
        raise AssertionError(f"Timed out: {promise}")

    def contains(self, value):
        self.wait(lambda screen: value in screen, value)

    def label_cells(self, label):
        cells = []
        for row, line in enumerate(self.screen.display):
            col = line.find(label)
            if col >= 0:
                cells.extend(
                    self.screen.buffer[row][x] for x in range(col, col + len(label))
                )
        return cells

    def click_label(self, label):
        self.contains(label)
        for row, line in enumerate(self.screen.display):
            col = line.find(label)
            if col >= 0:
                self.click(col + len(label) // 2 + 1, row + 1)
                return
        raise AssertionError(f"Missing control: {label}")

    def close(self):
        if self.closed:
            return
        self.send("\x03")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                os.close(self.fd)
                self.closed = True
                if status != 0:
                    raise AssertionError(f"TUI exited with status {status}")
                return
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    os.read(self.fd, 65536)
                except OSError:
                    pass
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        os.close(self.fd)
        self.closed = True
        raise AssertionError("TUI did not shut down within five seconds")


def luminance(color):
    if not re.fullmatch(r"[0-9a-fA-F]{6}", color):
        return None
    channels = [int(color[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [
        c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels
    ]
    return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def check_palette(terminal, light, promise):
    def readable_panel(_):
        # Check rendered panel text at WCAG AA contrast, not exact palette RGBs.
        cells = terminal.label_cells("No canaries")
        if not cells:
            return False
        for cell in cells:
            fg, bg = luminance(cell.fg), luminance(cell.bg)
            if fg is None or bg is None:
                return False
            if (light and bg < 0.85) or (not light and bg > 0.1):
                return False
            if (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05) < 4.5:
                return False
        return True

    terminal.wait(readable_panel, promise)


def check_endpoint_navigation(terminal, conninfo):
    terminal.send("e")
    terminal.contains("ADD ENDPOINT")
    terminal.send("secondary\t" + conninfo + "\r")
    terminal.contains("+ Canary")
    canaries = [("latency", "success")]
    for index in range(6):
        name = f"probe-{index + 1}"
        failing = index % 2 == 1
        terminal.send("a")
        terminal.contains("ADD CANARY")
        # Replace the default SQL through the public form, in the same input batch.
        terminal.send(
            name + "\t\x01\x0b" + ("SELECT 1 / 0" if failing else "SELECT 1") + "\r"
        )
        terminal.contains(f"Canary: {name}")
        canaries.append((name, "query_error" if failing else "success"))

    def outcome(index, endpoint):
        name, status = canaries[index]
        label = f"Canary {index + 1}/{len(canaries)}: {name}"

        def visible(screen):
            return (
                f"Endpoint: {endpoint}" in screen
                and label in screen
                and len(re.findall(r"Canary \d+/\d+:", screen)) == 1
                and f"Current: {status}" in screen
                and f"Last result: {status}  SQLSTATE" in screen
                and (status != "query_error" or "SQLSTATE 22012" in screen)
                and bool(
                    re.search(
                        r"ok [1-9][0-9]*  errors \d+  skipped \d+  wins \d+"
                        if status == "success"
                        else r"ok \d+  errors [1-9][0-9]*  skipped \d+  wins \d+",
                        screen,
                    )
                )
                and "Last result latency:" in screen
            )

        terminal.wait(visible, f"{endpoint} / {name}: selected outcome and stats")

    terminal.send("2k")
    outcome(len(canaries) - 1, "primary")
    for index in range(len(canaries) - 2, -1, -1):
        terminal.click_label("< Canary")
        outcome(index, "primary")
    terminal.send("j")
    outcome(0, "secondary")
    for index in range(1, len(canaries)):
        terminal.send("\x1b[C")
        outcome(index, "secondary")
    terminal.click_label("< Canary")
    outcome(len(canaries) - 2, "secondary")
    terminal.click_label("Canary >")
    outcome(len(canaries) - 1, "secondary")
    for index in range(len(canaries) - 2, -1, -1):
        terminal.send("\x1b[D")
        outcome(index, "secondary")

    # The pause/removal scenario needs only the primary endpoint and latency canary selected.
    terminal.send("x")
    terminal.contains("Remove selected item?")
    terminal.send("\t\r")
    outcome(0, "primary")
    terminal.send("1")
    terminal.contains("Canary: latency")


def main():
    conninfo = os.environ.get("MZ_WATCH_SMOKE_CONNINFO")
    if not conninfo:
        sys.exit(
            "Set MZ_WATCH_SMOKE_CONNINFO to a disposable Materialize or PostgreSQL endpoint."
        )
    executable = Path(__file__).resolve().parent.parent / "zig-out/bin/mz-watch"
    config_directory = tempfile.TemporaryDirectory(prefix="mz-watch-terminal-")
    terminal = Terminal(executable, config_directory.name)
    try:
        terminal.contains("+ Endpoint")
        check_palette(terminal, True, "light fallback: pale panels and readable text")
        terminal.send("\x1b[?997;1n")
        check_palette(
            terminal, False, "dynamic dark scheme: dark panels and readable text"
        )
        terminal.send("\x1b[?997;2n")
        check_palette(
            terminal, True, "dynamic light scheme: pale panels and readable text"
        )
        terminal.send("\t\r")
        terminal.contains("ADD ENDPOINT")
        terminal.send("\x1b")
        terminal.contains("+ Endpoint")
        terminal.click(5, 3)
        terminal.contains("ADD ENDPOINT")
        terminal.send("primary\t")
        terminal.send(conninfo + "\r")
        terminal.contains("No canaries")
        terminal.send("a")
        terminal.contains("ADD CANARY")
        terminal.send("\r")
        terminal.contains("nonempty name")
        terminal.send("latency\t\t\x01\x0b1500\t\x01\x0b7000\r")
        terminal.wait(
            lambda screen: bool(re.search(r"OK [1-9][0-9]*", screen)),
            "real successful SQL sample",
        )
        terminal.contains("HISTOGRAM")
        terminal.contains("MEAN / SECOND")
        check_endpoint_navigation(terminal, conninfo)
        terminal.resize(80, 24)
        terminal.wait(
            lambda screen: (
                "latency" in screen
                and "HISTOGRAM" in screen
                and "MEAN / SECOND" in screen
                and "q quit" in terminal.screen.display[-1]
            ),
            "both charts at 80x24",
        )
        terminal.send("p")
        terminal.contains("[paused]")
        saved_path = Path(config_directory.name) / "mz-watch/config.zon"
        assert saved_path.stat().st_mode & 0o777 == 0o600, "private configuration"
        saved = saved_path.read_bytes()
        terminal.close()
        terminal = Terminal(executable, config_directory.name)
        terminal.contains("Canary: latency  [paused]")
        terminal.contains("Every 1500ms  /  deadline 7000ms  /  1 endpoints")
        terminal.contains("OK 0  FAIL 0")
        assert saved_path.read_bytes() == saved, (
            "startup does not rewrite configuration"
        )
        backup = saved_path.with_suffix(".backup")
        saved_path.rename(backup)
        saved_path.mkdir()
        terminal.send("p")
        terminal.contains("Configuration not saved:")
        assert backup.read_bytes() == saved, "failed save preserves last good state"
        saved_path.rmdir()
        backup.rename(saved_path)
        terminal.send("p")
        terminal.contains("Canary paused")
        terminal.wait(
            lambda screen: "Configuration not saved:" not in screen,
            "autosave recovers after filesystem error",
        )
        terminal.send("j")
        terminal.contains("Canary: probe-1")
        terminal.wait(
            lambda screen: bool(re.search(r"OK [1-9][0-9]*", screen)),
            "restored endpoint connects and restored canary runs",
        )
        terminal.send("jk2")
        terminal.contains("Last result: success")
        terminal.send("\x1b[C")
        terminal.contains("SQLSTATE 22012")
        terminal.send("\x1b[D1k")
        terminal.contains("Canary: latency  [paused]")
        terminal.send("2")
        terminal.contains("primary")
        terminal.contains("skipped")
        terminal.send("x")
        terminal.contains("Remove selected item?")
        terminal.send("\r")
        terminal.contains("primary")
        terminal.send("x")
        terminal.contains("Remove selected item?")
        terminal.send("\t\r")
        terminal.contains("No endpoints")
        terminal.resize(40, 18)
        terminal.send("a")
        terminal.contains("ADD CANARY")
        terminal.send("\x1b")
        terminal.resize(20, 8)
        terminal.contains("Resize")
        terminal.resize(120, 32)
        terminal.send("1")
        terminal.contains("latency")
        terminal.close()
        malformed = b'.{ .endpoints = .{ .{ .name = "primary", .conninfo = "password=do-not-leak" } }, .unknown = true }'
        saved_path.write_bytes(malformed)
        result = subprocess.run(
            [str(executable)],
            env=os.environ | {"XDG_CONFIG_HOME": config_directory.name},
            capture_output=True,
            timeout=5,
            check=False,
        )
        assert result.returncode != 0, "invalid configuration fails startup"
        assert b"Cannot load configuration" in result.stderr, "clear startup error"
        assert b"do-not-leak" not in result.stdout + result.stderr, (
            "credential-safe startup error"
        )
        assert saved_path.read_bytes() == malformed, (
            "invalid configuration is untouched"
        )
    finally:
        try:
            terminal.close()
        finally:
            config_directory.cleanup()
    print(
        "PASS: persistence/restart, palettes, batched toolbar, all endpoint/canary outcomes, mouse/forms, live SQL and charts, resize, pause, confirmation, removal, shutdown"
    )


if __name__ == "__main__":
    main()
