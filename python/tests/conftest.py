# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Fakes for the hardware `unoq` talks to.

Nothing here touches /dev/ttyHS1 or a GPIO chip. That is deliberate: the test
suite has to be runnable on a board that is mid-flash, or on no board at all,
and a test that quietly drove the real BOOT0 line would be worse than no test.
The one suite that does need hardware is marked `hardware` and deselected by
default - see pyproject.toml.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import pytest

# The prompt the firmware actually prints, from CONFIG_SHELL_PROMPT_UART in
# mcu/app/prj.conf. test_contract.py parses that file and fails if the two
# drift - the same trick app_proto.h gets, for the same reason: a fake that
# imitates a prompt the firmware never sends proves nothing about the parser.
PROMPT = "unoq:~$ "


class FakeSerial:
    """Stand-in for `serial.Serial` covering exactly what MCU uses.

    Replies are driven by a command -> output-lines table. Every reply is
    wrapped the way the Zephyr shell really does it - the command is echoed
    back, then the output, then the prompt - because MCU.cmd() strips the echo
    and detects the prompt, and a fake that skipped either would test nothing.
    """

    def __init__(
        self,
        port: str = "/dev/fake",
        baud: int = 115200,
        timeout: float = 0.3,
        replies: dict[str, Sequence[str]] | None = None,
        *,
        silent: bool = False,
        ansi: bool = False,
        echo: bool = True,
        chunk_size: int | None = None,
    ) -> None:
        self.port = port
        self.baud = baud
        self.timeout = timeout
        self.is_open = True
        self.replies = dict(replies or {})
        self.silent = silent  # never answer, to exercise the timeout path
        self.ansi = ansi  # wrap output in escape codes, as a real terminal does
        self.echo = echo  # a real shell echoes; some do not
        # A real UART dribbles bytes in, so the prompt often is not in the
        # first read. Setting this forces MCU.cmd to loop and re-scan.
        self.chunk_size = chunk_size
        self.written: list[str] = []
        self.reset_count = 0
        self._pending = b""

    # -- serial.Serial surface ---------------------------------------------

    def reset_input_buffer(self) -> None:
        self.reset_count += 1
        self._pending = b""

    def write(self, data: bytes) -> int:
        command = data.decode().strip()
        self.written.append(command)
        if not self.silent:
            self._pending = self._render(command).encode()
        return len(data)

    def flush(self) -> None:
        return None

    def read(self, size: int = 1) -> bytes:
        if self.chunk_size is not None:
            size = min(size, self.chunk_size)
        chunk, self._pending = self._pending[:size], self._pending[size:]
        return chunk

    def close(self) -> None:
        self.is_open = False

    # -- helpers ------------------------------------------------------------

    def _render(self, command: str) -> str:
        lines = self.replies.get(command, [])
        body = "".join(f"{line}\r\n" for line in lines)
        if self.ansi:
            body = "".join(f"\x1b[1;32m{line}\x1b[0m\r\n" for line in lines)
        prefix = f"{command}\r\n" if self.echo else ""
        return f"{prefix}{body}{PROMPT}"


@pytest.fixture
def serial_factory(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Patch unoq.mcu.serial.Serial and hand back the FakeSerials created."""
    created: list[FakeSerial] = []

    def make(**kwargs: Any) -> list[FakeSerial]:
        def _factory(port: str, baud: int, timeout: float = 0.3) -> FakeSerial:
            fake = FakeSerial(port, baud, timeout, **kwargs)
            created.append(fake)
            return fake

        # Patched by dotted path so the patch is scoped to unoq.mcu's view of
        # these modules rather than to serial/time globally.
        monkeypatch.setattr("unoq.mcu.serial.Serial", _factory)
        # __init__ sleeps to let the UART settle; irrelevant to a fake.
        monkeypatch.setattr("unoq.mcu.time.sleep", lambda _s: None)
        return created

    return make


@pytest.fixture
def mcu_factory(serial_factory: Any) -> Any:
    """Build an MCU wired to a FakeSerial with the given command replies."""
    from unoq.mcu import MCU

    def make(replies: dict[str, Sequence[str]] | None = None, **kwargs: Any) -> MCU:
        serial_factory(replies=replies, **kwargs)
        return MCU(port="/dev/fake", ensure_link=False)

    return make


# -- gpiod ------------------------------------------------------------------


class FakeLineInfo:
    def __init__(self, direction: str) -> None:
        self.direction = f"Direction.{direction}"


class FakeRequest:
    def __init__(self) -> None:
        self.released = False

    def release(self) -> None:
        self.released = True


class FakeChip:
    def __init__(self, directions: dict[int, str]) -> None:
        self.directions = directions
        self.closed = False

    def get_line_info(self, offset: int) -> FakeLineInfo:
        return FakeLineInfo(self.directions.get(offset, "INPUT"))

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def fake_gpiod(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Replace the two gpiod entry points link.py uses.

    Only request_lines and Chip are faked; the Direction/Value enums stay real
    so a test still fails if the wrong enum member is passed.
    """
    request = FakeRequest()
    state: dict[str, Any] = {"calls": [], "request": request, "chip": None}

    def request_lines(chip: str, consumer: str = "", config: Any = None) -> FakeRequest:
        state["calls"].append({"chip": chip, "consumer": consumer, "config": config})
        return request

    def chip_factory(path: str) -> FakeChip:
        chip = FakeChip(state.get("directions", {}))
        state["chip"] = chip
        return chip

    monkeypatch.setattr("unoq.link.gpiod.request_lines", request_lines)
    monkeypatch.setattr("unoq.link.gpiod.Chip", chip_factory)
    return state
