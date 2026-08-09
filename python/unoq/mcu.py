# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
MCU interface: the Zephyr shell over /dev/ttyHS1.

The shell is a line protocol - send a command, read until the prompt comes
back. SMP/MCUmgr frames share the same UART (the shell detects them in the byte
stream, so there is no `mcumgr` shell command), but that half lives in fota.py.

This wraps only the `app` command group the firmware defines. Everything else
the shell offers - `gpio`, `i2c`, `device`, `kernel`, `devmem` - is reachable
through cmd() or by typing it at `tio /dev/ttyHS1`, and needs no wrapper here.
"""

from __future__ import annotations

import contextlib
import re
import time
from collections.abc import Sequence

import serial

from .link import link_up

PORT = "/dev/ttyHS1"

# The panel's limits, mirroring APP_BARS_* / APP_MATRIX_* in
# mcu/app/include/app_proto.h. They cannot be imported from C, so
# tests/test_contract.py reads that header and fails if these drift.
BARS_MAX = 7
BARS_PCT_MAX = 100
MATRIX_ROWS = 8
MATRIX_COLS = 13
MATRIX_MAX_LEVEL = 7
BAUD = 115200
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_PROMPT = re.compile(r"^\s*\S*:~\$\s*$")


class MCUError(RuntimeError):
    """The MCU reported an error, or returned something unparseable."""


class ShellTimeout(MCUError):
    """No prompt came back before the deadline."""


def _clean(text: str) -> list[str]:
    """Strip ANSI, drop echoed input and prompts, return meaningful lines."""
    lines = []
    for raw in _ANSI.sub("", text).replace("\r", "\n").splitlines():
        line = raw.strip()
        if not line or _PROMPT.match(line):
            continue
        lines.append(line)
    return lines


class MCU:
    """Synchronous handle on the MCU's Zephyr shell.

    Use as a context manager so the port is always released - the UART is a
    single shared resource and a stale handle blocks `tio`, `mcucon` and SMP.
    """

    def __init__(
        self, port: str = PORT, baud: int = BAUD, timeout: float = 0.3, ensure_link: bool = True
    ):
        if ensure_link:
            # Cheap, idempotent; without it every read silently returns b"".
            # Not fatal - the link may already be up, or permissions may differ.
            with contextlib.suppress(Exception):
                link_up()
        # exclusive=True, because the alternative is not "the second opener
        # fails" - it is "both succeed and interleave".
        #
        # Nothing in the kernel stops two processes opening a tty. Measured on
        # this board with unoq-cpu-bars.service running and eight status reads
        # attempted alongside it: six returned correctly and two failed with
        #
        #   device reports readiness to read but returned no data
        #   (device disconnected or multiple access on port?)
        #
        # which is a confusing way to be told you are sharing a serial port -
        # it reads like the cable fell out. Mostly-working with occasional
        # corruption is worse than a clean refusal, because it survives
        # testing.
        #
        # TIOCEXCL makes any later open fail immediately for a non-root
        # process, so whoever gets there first keeps the port and the second
        # one is told plainly. The documentation has always said to stop the
        # service before using the shell; this is what makes that true rather
        # than merely advisable.
        self._s = serial.Serial(port, baud, timeout=timeout, exclusive=True)
        self._port = port
        time.sleep(0.15)
        self._s.reset_input_buffer()

    # -- lifecycle ---------------------------------------------------------

    def close(self) -> None:
        if self._s.is_open:
            self._s.close()

    def __enter__(self) -> MCU:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- raw shell ---------------------------------------------------------

    def cmd(self, command: str, timeout: float = 2.0) -> list[str]:
        """Run any shell command, return its output lines (prompt/echo removed).

        Reads until the prompt reappears rather than sleeping a fixed time, so
        slow commands (`device list`) and fast ones cost what they should.
        """
        self._s.reset_input_buffer()
        self._s.write((command + "\r\n").encode())
        self._s.flush()

        buf, deadline = "", time.time() + timeout
        while time.time() < deadline:
            chunk = self._s.read(4096)
            if chunk:
                buf += chunk.decode("utf-8", "replace")
                # The prompt is the reliable end-of-response marker.
                if re.search(r":~\$\s*$", _ANSI.sub("", buf).replace("\r", "\n")):
                    break
        else:
            raise ShellTimeout(f"no prompt after {timeout}s for {command!r}")

        lines = _clean(buf)
        # Drop the echoed command itself.
        if lines and lines[0] == command:
            lines = lines[1:]
        for line in lines:
            if "command not found" in line or line.startswith("Error:"):
                raise MCUError(f"{command!r}: {line}")
        return lines

    # -- the `app` command group -------------------------------------------

    def status(self) -> dict[str, int | str]:
        """Parse `app status` into a dict, values converted to int where possible.

        Values are ints in practice - the firmware emits counters - but a field
        it cannot parse is kept as the raw string rather than dropped, so a
        firmware change surfaces as an odd value instead of a missing key.
        """
        out = self.cmd("app status")
        if not out:
            raise MCUError("app status returned nothing")
        fields: dict[str, int | str] = {}
        for token in out[0].split():
            if "=" in token:
                k, _, v = token.partition("=")
                try:
                    fields[k] = int(v)
                except ValueError:
                    fields[k] = v
        if not fields:
            raise MCUError(f"could not parse: {out[0]!r}")
        return fields

    # -- LED matrix --------------------------------------------------------

    def bars(self, pct: Sequence[float]) -> None:
        """Draw one vertical bar per value on the 8x13 LED matrix.

        Values are percentages, one per bar, left to right. They are rounded
        and clamped rather than validated: the caller is normally a live
        measurement, and a reading that arrives as 100.4 should light a full
        bar, not raise. A wrong *number* of bars is a different matter - that
        is a programming error, so it raises.
        """
        if not 1 <= len(pct) <= BARS_MAX:
            raise ValueError(f"need 1..{BARS_MAX} values, got {len(pct)}")
        values = " ".join(str(max(0, min(BARS_PCT_MAX, round(v)))) for v in pct)
        self.cmd(f"app bars {values}")

    def matrix_px(self, row: int, col: int, level: int = MATRIX_MAX_LEVEL) -> None:
        """Light a single LED and blank the rest. Use it to find out which
        corner row 0, column 0 is on a board in front of you."""
        self.cmd(f"app matrix px {int(row)} {int(col)} {int(level)}")

    def matrix_flip(self) -> bool:
        """Rotate the panel 180 degrees and persist that. Returns the new state.

        This is how you correct a display that reads upside down because of
        how the board is mounted; the MCU remembers it across reboots.
        """
        out = self.cmd("app matrix flip")
        m = re.search(r"flip=(\d+)", out[0] if out else "")
        if not m:
            raise MCUError(f"could not parse matrix flip: {out!r}")
        return m.group(1) != "0"

    def matrix_off(self) -> None:
        """Blank the panel and stop its refresh timer."""
        self.cmd("app matrix off")
