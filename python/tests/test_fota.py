# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for MCUboot image staging over SMP.

The dangerous mistakes here are silent ones: staging an unsigned image, or
confirming the wrong slot. Both are guarded below without touching a board.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from unoq import fota


class FakeImage:
    def __init__(
        self,
        slot: int,
        version: str = "0.0.0",
        *,
        active: bool = False,
        confirmed: bool = False,
        pending: bool = False,
        digest: bytes = b"\xab\xcd",
    ) -> None:
        self.slot = slot
        self.version = version
        self.active = active
        self.confirmed = confirmed
        self.pending = pending
        self.hash = digest


class FakeReply:
    def __init__(self, images: list[FakeImage] | None) -> None:
        if images is not None:
            self.images = images


class FakeTransport:
    def __init__(self) -> None:
        self.disconnected = False

    async def disconnect(self) -> None:
        self.disconnected = True


class FakeClient:
    def __init__(
        self,
        images: list[FakeImage] | None = None,
        *,
        offsets: list[int] | None = None,
        fail: Exception | None = None,
    ) -> None:
        self.images = images if images is not None else []
        self.offsets = offsets or [0]
        self.fail = fail
        self.requests: list[Any] = []

    async def request(self, req: Any, timeout_s: float | None = None) -> FakeReply:
        self.requests.append(req)
        if self.fail is not None:
            raise self.fail
        return FakeReply(self.images)

    async def upload(self, blob: bytes) -> AsyncIterator[int]:
        for off in self.offsets:
            yield off


@pytest.fixture
def smp(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Patch the SMP connection helper and the request types fota builds."""
    state: dict[str, Any] = {"client": FakeClient(), "transport": FakeTransport()}

    async def _client(port: str, timeout: float) -> tuple[Any, Any]:
        state["port"] = port
        return state["client"], state["transport"]

    class RecordingWrite:
        def __init__(self, **kwargs: Any) -> None:
            self.kwargs = kwargs

    monkeypatch.setattr(fota, "_client", _client)
    monkeypatch.setattr(fota, "ImageStatesWrite", RecordingWrite)
    monkeypatch.setattr(fota, "ImageStatesRead", RecordingWrite)
    monkeypatch.setattr(fota, "ResetWrite", RecordingWrite)
    return state


# -- images ------------------------------------------------------------------


def test_images_maps_the_slot_table(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(
        [FakeImage(0, "1.2.3", active=True, confirmed=True, digest=b"\x01\x02")]
    )
    assert fota.images() == [
        {
            "slot": 0,
            "version": "1.2.3",
            "active": True,
            "confirmed": True,
            "pending": False,
            "hash": "0102",
        }
    ]


def test_images_is_empty_when_the_reply_has_none(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(None)
    assert fota.images() == []


def test_images_always_disconnects(smp: dict[str, Any]) -> None:
    fota.images()
    assert smp["transport"].disconnected is True


def test_images_disconnects_even_when_the_request_fails(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(fail=RuntimeError("link dropped"))
    with pytest.raises(RuntimeError, match="link dropped"):
        fota.images()
    assert smp["transport"].disconnected is True


# -- upload ------------------------------------------------------------------


def test_upload_rejects_a_missing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        fota.upload(tmp_path / "nope.signed.bin")


def test_upload_refuses_an_unsigned_image(tmp_path: Path) -> None:
    """The guard that stops you bricking the MCUboot chain.

    An unsigned image links into slot0 with no header, so the bootloader
    refuses it and the board stops booting.
    """
    raw = tmp_path / "zephyr.bin"
    raw.write_bytes(b"\x00" * 16)
    with pytest.raises(ValueError, match="does not look signed"):
        fota.upload(raw)


def test_upload_returns_the_staged_slot_hash(smp: dict[str, Any], tmp_path: Path) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 32)
    smp["client"] = FakeClient(
        [
            FakeImage(0, active=True, digest=b"\xaa"),
            FakeImage(1, active=False, digest=b"\xbe\xef"),
        ]
    )
    assert fota.upload(image, progress=False) == "beef"


def test_upload_returns_empty_when_no_inactive_slot_exists(
    smp: dict[str, Any], tmp_path: Path
) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 8)
    smp["client"] = FakeClient([FakeImage(0, active=True)])
    assert fota.upload(image, progress=False) == ""


def test_upload_reports_progress(
    smp: dict[str, Any], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 100)
    smp["client"] = FakeClient([FakeImage(1)], offsets=[0, 50, 100])
    fota.upload(image, progress=True)
    out = capsys.readouterr().out
    assert "upload" in out
    assert "100%" in out


def test_upload_is_silent_when_progress_is_off(
    smp: dict[str, Any], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 100)
    smp["client"] = FakeClient([FakeImage(1)], offsets=[0, 100])
    fota.upload(image, progress=False)
    assert capsys.readouterr().out == ""


# -- test / confirm / reset --------------------------------------------------


def test_test_marks_the_given_hash_pending(smp: dict[str, Any]) -> None:
    fota.test("beef")
    write = smp["client"].requests[-1]
    assert write.kwargs["hash"] == bytes.fromhex("beef")
    # confirm=False is what makes this a *test* boot that reverts on failure.
    assert write.kwargs["confirm"] is False


def test_test_finds_the_inactive_slot_when_no_hash_is_given(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(
        [
            FakeImage(0, active=True, digest=b"\xaa"),
            FakeImage(1, active=False, digest=b"\xbe\xef"),
        ]
    )
    fota.test()
    assert smp["client"].requests[-1].kwargs["hash"] == bytes.fromhex("beef")


def test_test_raises_when_nothing_is_staged(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient([FakeImage(0, active=True)])
    with pytest.raises(RuntimeError, match="no staged image"):
        fota.test()


def test_confirm_keeps_the_running_image(smp: dict[str, Any]) -> None:
    fota.confirm()
    assert smp["client"].requests[-1].kwargs == {"confirm": True}


def test_reset_treats_a_missing_reply_as_success(smp: dict[str, Any]) -> None:
    # The device reboots instead of answering, so the request never completes.
    smp["client"] = FakeClient(fail=TimeoutError("no reply"))
    fota.reset()
    assert smp["transport"].disconnected is True


def test_reset_still_disconnects(smp: dict[str, Any]) -> None:
    fota.reset()
    assert smp["transport"].disconnected is True


def test_client_builds_a_connected_smp_pair(monkeypatch: pytest.MonkeyPatch) -> None:
    """Cover the connection helper the other tests patch out."""
    import asyncio

    connected: list[float] = []

    class _Transport:
        def __init__(self, baudrate: int = 0) -> None:
            self.baudrate = baudrate

    class _Client:
        def __init__(self, transport: Any, port: str, timeout_s: float = 0) -> None:
            self.transport = transport
            self.port = port

        async def connect(self, connect_timeout_s: float = 0) -> None:
            connected.append(connect_timeout_s)

    monkeypatch.setattr(fota, "SMPSerialTransport", _Transport)
    monkeypatch.setattr(fota, "SMPClient", _Client)

    pair: tuple[Any, Any] = asyncio.run(fota._client("/dev/fake", 5.0))
    client, transport = pair
    assert client.port == "/dev/fake"
    assert transport.baudrate == 115200
    assert connected == [5.0]
