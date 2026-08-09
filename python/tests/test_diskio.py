# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""DiskActivity: an edge detector over /sys/block/<dev>/stat.

The kernel's own mmc0/disk-activity triggers would have made this unnecessary,
and are offered by this board's kernel, and do not fire. These tests pin the
replacement's two awkward properties: it reports CHANGE rather than level, and
it never raises, because it feeds a status LED on a board whose whole point is
staying reachable.
"""

from __future__ import annotations

from pathlib import Path

from unoq.diskio import DiskActivity

# reads_ios is field 1, writes_ios is field 5 - a real line, trimmed.
STAT = "  {reads}  0  100  50  {writes}  0  200  80  0  60  120"


def write_stat(path: Path, reads: int, writes: int) -> None:
    path.write_text(STAT.format(reads=reads, writes=writes) + "\n")


def test_no_change_is_idle(tmp_path: Path) -> None:
    stat = tmp_path / "stat"
    write_stat(stat, 10, 20)
    d = DiskActivity(str(stat))
    assert d.busy() is False


def test_a_completed_read_counts(tmp_path: Path) -> None:
    stat = tmp_path / "stat"
    write_stat(stat, 10, 20)
    d = DiskActivity(str(stat))
    write_stat(stat, 11, 20)
    assert d.busy() is True
    assert d.busy() is False  # and settles again


def test_a_completed_write_counts(tmp_path: Path) -> None:
    stat = tmp_path / "stat"
    write_stat(stat, 10, 20)
    d = DiskActivity(str(stat))
    write_stat(stat, 10, 25)
    assert d.busy() is True


def test_missing_file_is_idle_not_an_exception(tmp_path: Path) -> None:
    # A different device name or a kernel without the counters should cost the
    # indicator and nothing else.
    d = DiskActivity(str(tmp_path / "nope"))
    assert d.busy() is False


def test_unparseable_stat_is_idle(tmp_path: Path) -> None:
    stat = tmp_path / "stat"
    stat.write_text("not numbers at all\n")
    d = DiskActivity(str(stat))
    assert d.busy() is False


def test_recovers_when_the_file_appears(tmp_path: Path) -> None:
    stat = tmp_path / "stat"
    d = DiskActivity(str(stat))
    write_stat(stat, 5, 5)
    assert d.busy() is False  # first real reading is a baseline, not an edge
    write_stat(stat, 6, 5)
    assert d.busy() is True
