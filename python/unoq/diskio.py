# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Whether the eMMC is busy, read from /sys/block/<dev>/stat.

WHY THIS EXISTS AT ALL

The kernel can already do this. `mmc0`, `disk-activity` and `disk-write` are
all offered in every LED's trigger list on this board, and any one of them would
blink a LED on eMMC traffic with no userspace involvement whatsoever.

None of them fire. Measured on this board with 400 MB of O_DIRECT writes in
flight and the LED brightness sampled 400 times: on in **zero** samples, for all
three. They are registered - so they appear in the list, and selecting one is
accepted without complaint - but nothing calls into them. A trigger you can
select is not a trigger that fires.

So the count is read here instead, and the answer is pushed to the MCU, which
owns the LED that shows it. That is a round trip for something that should have
been a single kernel write, and it is worth the annoyance for one reason: it is
checkable. /sys/block/mmcblk0/stat visibly moves, which the trigger did not.

WHAT COUNTS AS BUSY

Field 1 and field 5 of the stat file are completed reads and completed writes.
Any change between two samples means the device did something. Not "how busy" -
just whether anything happened - because that is all a single LED can say, and
inventing a threshold would be inventing precision the indicator cannot show.
"""

from __future__ import annotations

from pathlib import Path

__all__ = ["DiskActivity", "STAT_PATH"]

STAT_PATH = "/sys/block/mmcblk0/stat"

# Completed reads and completed writes, in the order the kernel documents for
# /sys/block/*/stat. Discards and flushes are deliberately not counted: they
# arrive in bursts that do not correspond to anything a person would call disk
# activity, and would leave the LED on when the board is idle.
_READS_IOS = 0
_WRITES_IOS = 4


class DiskActivity:
    """Edge detector over the block device's completed-I/O counters."""

    def __init__(self, path: str = STAT_PATH) -> None:
        self._path = Path(path)
        self._last = self._read()

    def _read(self) -> int | None:
        """Total completed operations, or None if the counters are unreadable.

        None rather than 0, and never an exception: this feeds a status LED on a
        board whose whole point is staying up. A missing stat file - a different
        device name, a kernel without the counters - should cost the indicator
        and nothing else.
        """
        try:
            fields = self._path.read_text().split()
        except OSError:
            return None
        try:
            return int(fields[_READS_IOS]) + int(fields[_WRITES_IOS])
        except (IndexError, ValueError):
            return None

    def busy(self) -> bool:
        """True if anything completed since the previous call."""
        now = self._read()
        if now is None or self._last is None:
            self._last = now
            return False
        moved = now != self._last
        self._last = now
        return moved
