"""
MCU interface: the Zephyr shell, plus SMP/MCUmgr, over /dev/ttyHS1.

Both share one UART (lpuart1). The shell is a line protocol; SMP frames are
detected by the shell out of the same byte stream, so there is no `mcumgr`
shell command - that is expected, not a misconfiguration.
"""

from __future__ import annotations

import re
import time

import serial

from .link import link_up

PORT = "/dev/ttyHS1"
# Seconds to let the UART settle between the shell handle and the SMP handle.
SMP_SETTLE_S = 0.4
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

    def __init__(self, port: str = PORT, baud: int = BAUD, timeout: float = 0.3,
                 ensure_link: bool = True):
        if ensure_link:
            # Cheap, idempotent; without it every read silently returns b"".
            try:
                link_up()
            except Exception:
                pass  # not fatal - the link may already be up, or perms differ
        self._s = serial.Serial(port, baud, timeout=timeout)
        self._port = port
        time.sleep(0.15)
        self._s.reset_input_buffer()

    # -- lifecycle ---------------------------------------------------------

    def close(self) -> None:
        if self._s.is_open:
            self._s.close()

    def __enter__(self) -> "MCU":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # -- raw shell ---------------------------------------------------------

    def cmd(self, command: str, timeout: float = 2.0) -> list[str]:
        """Run a shell command, return its output lines (prompt/echo removed).

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

    # -- application commands ---------------------------------------------

    def status(self) -> dict[str, int]:
        """Parse `app status` into a dict of ints."""
        out = self.cmd("app status")
        if not out:
            raise MCUError("app status returned nothing")
        fields = {}
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

    def blink(self, ms: int) -> None:
        """Set the LED blink period in milliseconds (10..10000)."""
        self.cmd(f"app blink {int(ms)}")

    def uptime_ms(self) -> int:
        out = self.cmd("kernel uptime")
        m = re.search(r"(\d+)", out[0] if out else "")
        if not m:
            raise MCUError("could not parse kernel uptime")
        return int(m.group(1))

    def devices(self) -> list[tuple[str, str]]:
        """Return [(device_name, state), ...] from `device list`."""
        found = []
        for line in self.cmd("device list", timeout=4.0):
            m = re.match(r"-\s+(\S+)\s+\((\w+)\)", line)
            if m:
                found.append((m.group(1), m.group(2)))
        return found

    # -- GPIO (MCU-side pins, i.e. the Arduino headers) --------------------

    def gpio_conf(self, port: str, pin: int, mode: str = "o") -> None:
        """Configure an MCU pin. mode: 'i' or 'o' (+ u/d, h/l, 0/1)."""
        self.cmd(f"gpio conf {port} {int(pin)} {mode}")

    def gpio_set(self, port: str, pin: int, value: int) -> None:
        self.cmd(f"gpio set {port} {int(pin)} {1 if value else 0}")

    def gpio_get(self, port: str, pin: int) -> int:
        out = self.cmd(f"gpio get {port} {int(pin)}")
        m = re.search(r"(\d+)\s*$", out[0] if out else "")
        if not m:
            raise MCUError(f"could not parse gpio get: {out!r}")
        return int(m.group(1))

    def i2c_scan(self, bus: str) -> list[int]:
        """Scan an MCU-side I2C bus, returning 7-bit addresses."""
        addrs = []
        for line in self.cmd(f"i2c scan {bus}", timeout=6.0):
            for tok in line.split():
                if re.fullmatch(r"[0-9a-f]{2}", tok):
                    addrs.append(int(tok, 16))
        return addrs

    def reboot(self) -> None:
        """Reboot the MCU. The serial link drops; reopen afterwards."""
        try:
            self.cmd("kernel reboot cold", timeout=1.0)
        except ShellTimeout:
            pass  # expected - it reboots instead of printing a prompt

    # -- SMP / MCUmgr ------------------------------------------------------

    def echo(self, text: str, timeout: float = 10.0) -> str:
        """Round-trip a string through SMP (not the shell). Proves the
        MCUmgr transport is alive independently of shell parsing."""
        import asyncio

        from smpclient import SMPClient
        from smpclient.requests.os_management import EchoWrite
        from smpclient.transport.serial import SMPSerialTransport

        was_open = self._s.is_open
        if was_open:
            self.close()
        # The UART needs a moment to settle between handles. Reopening it
        # immediately makes the first SMP frame vanish and the request times
        # out - which looks like a firmware fault but is purely a host race.
        time.sleep(SMP_SETTLE_S)

        async def _run() -> str:
            transport = SMPSerialTransport(baudrate=BAUD)
            client = SMPClient(transport, self._port, timeout_s=timeout)
            await client.connect(connect_timeout_s=timeout)
            try:
                reply = await client.request(EchoWrite(d=text), timeout_s=timeout)
                return getattr(reply, "r", "")
            finally:
                await transport.disconnect()

        try:
            last: Exception | None = None
            for attempt in range(2):
                try:
                    return asyncio.run(asyncio.wait_for(_run(), timeout * 3))
                except Exception as exc:  # noqa: BLE001 - retried below
                    last = exc
                    time.sleep(SMP_SETTLE_S * (attempt + 2))
            raise MCUError(f"SMP echo failed after retry: {last}") from last
        finally:
            if was_open:
                time.sleep(SMP_SETTLE_S)
                self._s = serial.Serial(self._port, BAUD, timeout=0.3)
                time.sleep(0.15)
                self._s.reset_input_buffer()
