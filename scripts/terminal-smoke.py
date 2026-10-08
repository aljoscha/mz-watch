#!/usr/bin/env python3
"""Exercise the real TUI through a PTY. Live SQL checks need a disposable endpoint."""

import codecs
import fcntl
import itertools
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

    def hover(self, col, row):
        self.send(f"\x1b[<35;{col};{row}M")

    def wheel(self, col, row, down=True):
        self.send(f"\x1b[<{65 if down else 64};{col};{row}M")

    def drag(self, col, start, end):
        self.send(f"\x1b[<0;{col};{start}M")
        step = 1 if end >= start else -1
        for row in range(start, end + step, step):
            self.send(f"\x1b[<32;{col};{row}M")
        self.send(f"\x1b[<0;{col};{end}m")

    def settle(self):
        # Negative assertions need to observe input processing, not a stale frame.
        # A quiet period also allows coalesced redraws and batched mouse events.
        deadline = time.monotonic() + 0.25
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    data = os.read(self.fd, 65536)
                except OSError as error:
                    raise AssertionError("TUI exited while settling input") from error
                self.stream.feed(self.decoder.decode(data))

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


def check_overlay(terminal, title):
    terminal.contains(title)
    terminal.settle()
    # The regular toolbar remains visible, but is dimmed and cannot be clicked.
    cells = terminal.label_cells("+ Endpoint")
    assert cells and all(luminance(cell.bg) < 0.85 for cell in cells), "dimmed backdrop"
    dialog = terminal.label_cells(title)
    assert dialog and all(cell.bg.lower() == "ffffff" for cell in dialog), (
        "bright dialog surface"
    )
    terminal.click_label("Quit")
    terminal.settle()
    terminal.contains(title)


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
                        (
                            r"ok [1-9][0-9]*  errors \d+  skipped \d+  wins \d+"
                            if status == "success"
                            else r"ok \d+  errors [1-9][0-9]*  skipped \d+  wins \d+"
                        ),
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
        terminal.send("l" if index % 2 else "\x1b[C")
        outcome(index, "secondary")
    terminal.contains("[h/l]")
    terminal.click_label("< Canary")
    outcome(len(canaries) - 2, "secondary")
    terminal.click_label("Canary >")
    outcome(len(canaries) - 1, "secondary")
    for index in range(len(canaries) - 2, -1, -1):
        terminal.send("h" if index % 2 else "\x1b[D")
        outcome(index, "secondary")

    # The pause/removal scenario needs only the primary endpoint and latency canary selected.
    terminal.send("x")
    terminal.contains("Remove selected item?")
    check_overlay(terminal, "Remove selected item?")
    terminal.send("\x1b")
    outcome(0, "secondary")
    terminal.send("x")
    terminal.contains("Remove selected item?")
    terminal.send("\r")
    outcome(0, "primary")
    terminal.send("1")
    terminal.contains("Canary: latency")


def list_rows(terminal, prefix):
    """Read item hit targets, excluding the independently selected detail title."""
    rows = []
    for row, line in enumerate(terminal.screen.display):
        if "Canary:" in line or "Endpoint:" in line or re.search(r"Canary \d+/", line):
            # Wide layouts put the list and detail title on the same line.
            line = re.split(r"Canary:|Endpoint:|Canary \d+/", line)[0]
        matches = list(re.finditer(rf"\b{prefix}-(\d{{2}})\b", line))
        assert len(matches) <= 1, "one item per list row"
        if matches:
            match = matches[0]
            rows.append((int(match[1]), match.start() + 1, row + 1))
    return rows


def viewport(terminal, prefix, first=None, count=None):
    def visible(_):
        rows = list_rows(terminal, prefix)
        indices = [item[0] for item in rows]
        return (
            len(rows) >= 2
            and indices == list(range(indices[0], indices[0] + len(rows)))
            and all(
                b[2] == a[2] + (3 if terminal.screen.columns >= 112 else 1)
                for a, b in itertools.pairwise(rows)
            )
            and (first is None or indices[0] == first)
            and (count is None or len(rows) == count)
        )

    terminal.wait(visible, f"{prefix}: consecutive viewport {first}/{count}")
    return list_rows(terminal, prefix)


def scrollbar(terminal, rows, total):
    # Locate the visible track beside the list, not a panel border or chart.
    # The thumb and track must be distinguishable in the rendered terminal.
    top = rows[0][2]
    bottom = rows[-1][2] + (3 if terminal.screen.columns >= 112 else 1) - 1
    for col in range(rows[0][1] + 9, terminal.screen.columns):
        cells = [terminal.screen.buffer[row - 1][col] for row in range(top, bottom + 1)]
        glyphs = [cell.data for cell in cells]
        if not all(glyph in "█░▒▓┃│▐▌▎▕" for glyph in glyphs):
            continue
        styles = [(cell.data, cell.fg, cell.bg) for cell in cells]
        if len(set(styles)) != 2:
            continue
        # At the initial viewport the thumb occupies the top of the track.
        thumb_style = styles[0]
        thumb = [top + i for i, style in enumerate(styles) if style == thumb_style]
        if thumb != list(range(top, top + len(thumb))):
            continue
        assert 0 < len(thumb) < bottom - top + 1, "visible non-full scrollbar thumb"
        assert abs(len(thumb) - (bottom - top + 1) * len(rows) / total) <= 1, (
            "proportional thumb"
        )
        return col + 1, top, bottom, thumb_style, thumb
    raise AssertionError("Missing proportional scrollbar beside overflowing list")


def check_tab_colors(terminal, active, focused=None):
    def correct(_):
        for label in ("Canaries", "Endpoints"):
            cells = terminal.label_cells(label)
            if not cells:
                return False
            for cell in cells:
                if label == active:
                    if cell.bg.lower() != "ffffff":
                        return False
                else:
                    if not re.fullmatch(r"[0-9a-fA-F]{6}", cell.bg):
                        return False
                    red, green, blue = (int(cell.bg[i : i + 2], 16) for i in (0, 2, 4))
                    if not (
                        200 <= red < green and 200 <= blue <= green and green >= 230
                    ):
                        return False
                if label == focused and not cell.underscore:
                    return False
        return True

    terminal.wait(
        correct, f"{active}: white active / pale teal inactive tabs, focus {focused}"
    )


def check_list_navigation(executable, endpoints=False):
    total = 48
    prefix = "target" if endpoints else "check"
    page = "2" if endpoints else "1"
    detail = "Endpoint:" if endpoints else "Canary:"
    active = "Endpoints" if endpoints else "Canaries"
    inactive = "Canaries" if endpoints else "Endpoints"
    with tempfile.TemporaryDirectory(prefix="mz-watch-lists-") as home:
        path = Path(home) / "mz-watch/config.zon"
        path.parent.mkdir(mode=0o700)
        # No canary/endpoint cross product. Paused canaries never query the
        # numeric loopback endpoint, whose low port is not a database service.
        eps = ",".join(
            f'.{{ .name = "target-{i:02}", .conninfo = "host=127.0.0.1 port=1 connect_timeout=1" }}'
            for i in range(total if endpoints else 0)
        )
        canaries = ",".join(
            f'.{{ .name = "check-{i:02}", .sql = "SELECT 1", .paused = true }}'
            for i in range(2 if endpoints else total)
        )
        with os.fdopen(
            os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w"
        ) as config:
            config.write(f".{{ .endpoints = .{{{eps}}}, .canaries = .{{{canaries}}} }}")
        terminal = Terminal(executable, home)
        try:
            terminal.contains("+ Endpoint")
            terminal.send(page)
            terminal.contains(f"{detail} {prefix}-00")
            terminal.settle()
            rows = viewport(terminal, prefix, first=0)
            assert len(rows) >= 7, (
                "wide active list uses available height for labels and summaries"
            )
            assert all(col == rows[0][1] for _, col, _ in rows), "left-aligned names"
            for _, col, row in rows:
                line = terminal.screen.display[row + 1]
                assert "────" in line[:32], "separator below each summary"
                label = terminal.screen.buffer[row - 1][col - 1]
                rule = terminal.screen.buffer[row + 1][col - 1]
                assert luminance(rule.fg) > luminance(label.fg), "faint separators"
            capacity = len(rows)
            bar_col, top, bottom, thumb_style, initial_thumb = scrollbar(
                terminal, rows, total
            )
            check_tab_colors(terminal, active)
            terminal.click_label(inactive)
            check_tab_colors(terminal, inactive)
            assert not list_rows(terminal, prefix), (
                "only the active tab's list is rendered"
            )
            terminal.click_label(active)
            check_tab_colors(terminal, active)
            for label in (active, inactive):
                for row, line in enumerate(terminal.screen.display):
                    col = line.find(label)
                    if col >= 0:
                        terminal.hover(col + 1, row + 1)
                        break
                terminal.settle()
                check_tab_colors(terminal, active)
            terminal.hover(1, 1)
            # Toolbar order is public keyboard navigation. Cycle until each tab
            # has keyboard focus, without activating the inactive one.
            for label in (active, inactive):
                for _ in range(12):
                    terminal.send("\t")
                    terminal.settle()
                    cells = terminal.label_cells(label)
                    if cells and all(cell.underscore for cell in cells):
                        break
                else:
                    raise AssertionError(f"Cannot keyboard-focus {label} tab")
                check_tab_colors(terminal, active, focused=label)
            terminal.send(page)
            terminal.wheel(rows[0][1], rows[0][2])
            viewport(terminal, prefix, first=1, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            terminal.wheel(rows[0][1], rows[0][2], down=False)
            viewport(terminal, prefix, first=0, count=capacity)
            terminal.wheel(rows[0][1], rows[0][2], down=False)
            terminal.settle()
            viewport(terminal, prefix, first=0, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            terminal.wheel(rows[0][1], rows[0][2])
            viewport(terminal, prefix, first=1, count=capacity)
            for _ in range(5):
                terminal.wheel(rows[0][1], rows[0][2])
            rows = viewport(terminal, prefix, first=6, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            moved_thumb = []
            for row in range(top, bottom + 1):
                cell = terminal.screen.buffer[row - 1][bar_col - 1]
                if (cell.data, cell.fg, cell.bg) == thumb_style:
                    moved_thumb.append(row)
            assert moved_thumb and moved_thumb[0] > initial_thumb[0], (
                "wheel moves scrollbar thumb"
            )
            terminal.send("1" if endpoints else "2")
            terminal.settle()
            assert not list_rows(terminal, prefix), (
                "inactive list is hidden after scrolling"
            )
            if endpoints:
                terminal.send("j")
                terminal.contains("Canary: check-01")
            terminal.send(page)
            viewport(terminal, prefix, first=6, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            if endpoints:
                terminal.contains("Canary 2/2: check-01")
            terminal.send("k")
            viewport(terminal, prefix, first=0, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            terminal.send("\x1b[A")
            terminal.settle()
            viewport(terminal, prefix, first=0, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            terminal.send("j")
            terminal.contains(f"{detail} {prefix}-01")
            terminal.send("\x1b[B")
            terminal.contains(f"{detail} {prefix}-02")
            terminal.send("j" * total)
            terminal.contains(f"{detail} {prefix}-{total - 1:02}")
            viewport(terminal, prefix, first=total - capacity, count=capacity)
            terminal.send("j\x1b[B")
            terminal.settle()
            terminal.contains(f"{detail} {prefix}-{total - 1:02}")
            viewport(terminal, prefix, first=total - capacity, count=capacity)
            terminal.send("k" * total)
            terminal.contains(f"{detail} {prefix}-00")
            viewport(terminal, prefix, first=0, count=capacity)
            terminal.click(bar_col, bottom)
            terminal.settle()
            rows = viewport(terminal, prefix)
            assert rows[0][0] > 0, "track click scrolls viewport"
            terminal.contains(f"{detail} {prefix}-00")
            # Drag from the track's bottom to top, then drag the thumb to bottom.
            terminal.drag(bar_col, bottom, top)
            viewport(terminal, prefix, first=0, count=capacity)
            terminal.drag(bar_col, top, bottom)
            rows = viewport(terminal, prefix, first=total - capacity, count=capacity)
            terminal.contains(f"{detail} {prefix}-00")
            clicked, col, row = rows[1]
            terminal.click(col, row)
            terminal.contains(f"{detail} {prefix}-{clicked:02}")
            for cols, height in (
                (80, 24),
                (120, 32),
                (80, 24),
                (120, 32),
                (112, 32),
                (80, 40),
                (120, 32),
            ):
                terminal.resize(cols, height)
                terminal.settle()
                rows = viewport(
                    terminal,
                    prefix,
                    count=(2 if height == 24 else None) if cols == 80 else capacity,
                )
                assert clicked in [item[0] for item in rows], (
                    "resize keeps selection visible"
                )
                terminal.contains(f"{detail} {prefix}-{clicked:02}")
                detail_row = next(
                    y
                    for y, line in enumerate(terminal.screen.display)
                    if f"{detail} {prefix}-" in line
                )
                if cols == 80:
                    assert len(rows) <= 6, "narrow list reserves detail space"
                    assert detail_row + 1 > rows[-1][2], "narrow details below list"
                    if not endpoints:
                        terminal.contains("HISTOGRAM")
                        terminal.contains("MEAN / SECOND")
                else:
                    line = terminal.screen.display[detail_row]
                    assert line.index(detail) > rows[0][1] + 9, (
                        "wide details right of list"
                    )
                assert "q quit" in terminal.screen.display[-1], "footer survives resize"
            if endpoints:
                terminal.send("h")
                terminal.contains("Canary 1/2: check-00")
                terminal.send("l")
                terminal.contains("Canary 2/2: check-01")
                terminal.contains("[h/l]")
                terminal.send("\x1b[D")
                terminal.contains("Canary 1/2: check-00")
                terminal.send("\x1b[C")
                terminal.contains("Canary 2/2: check-01")
            else:
                terminal.resize(80, 24)
                terminal.settle()
                terminal.send("k" * total)
                terminal.contains("Canary: check-00")
                viewport(terminal, prefix, first=0, count=2)
                terminal.send("jj")
                terminal.contains("Canary: check-02")
                rows = viewport(terminal, prefix, first=1, count=2)
                terminal.send("x")
                terminal.contains("Remove selected item?")
                modal_col = next(
                    line.index("Remove selected item?") + 1
                    for line in terminal.screen.display
                    if "Remove selected item?" in line
                )
                terminal.send("\x1b")
                terminal.wait(
                    lambda screen: "Remove selected item?" not in screen,
                    "confirmation cancelled",
                )
                _, _, row = rows[0]
                # Hit-testing still uses the regular frame for this input batch.
                # Its row falls inside the previous modal's rectangle.
                terminal.send(f"x\x1b[<0;{modal_col};{row}M\x1b[<0;{modal_col};{row}m")
                terminal.wait(
                    lambda screen: (
                        "Remove selected item?" in screen
                        and "Canary: check-02" in screen
                    ),
                    "batched background click cannot change removal target",
                )
                terminal.send("\r")
                terminal.contains("Canary: check-03")
                assert '"check-02"' not in path.read_text(), (
                    "Enter removes only the confirmed target"
                )
        finally:
            terminal.close()


def main():
    executable = Path(__file__).resolve().parent.parent / "zig-out/bin/mz-watch"
    check_list_navigation(executable)
    check_list_navigation(executable, endpoints=True)
    if sys.argv[1:] == ["--lists-only"]:
        print(
            "PASS: seeded list PTYs, scrolling, selection, tabs, colors/focus, resize, h/l"
        )
        return
    conninfo = os.environ.get("MZ_WATCH_SMOKE_CONNINFO")
    if not conninfo:
        sys.exit(
            "Set MZ_WATCH_SMOKE_CONNINFO to a disposable Materialize or PostgreSQL endpoint."
        )
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
        check_overlay(terminal, "ADD ENDPOINT")
        terminal.send("primary\t")
        terminal.send(conninfo + "\r")
        terminal.contains("No canaries")
        terminal.send("a")
        terminal.contains("ADD CANARY")
        check_overlay(terminal, "ADD CANARY")
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
        terminal.send("\t\r")
        terminal.contains("primary")
        terminal.send("x")
        terminal.contains("Remove selected item?")
        terminal.send("\r")
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
        "PASS: seeded lists/scrollbars/tabs, persistence/restart, palettes, batched toolbar, all endpoint/canary outcomes, mouse/forms, live SQL and charts, resize, pause, confirmation, removal, shutdown"
    )


if __name__ == "__main__":
    main()
