<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# What a clean board revealed

A running log, kept while taking a factory-restored UNO Q back to a working
board with `bootstrap.sh`. It exists because **none of these are visible on a
board that is already provisioned** — which is every board the scripts had been
tested on until then.

The common shape is worth stating up front, because it is what to look for
next: of the nine findings below, **four reported success** and three more
printed a warning that read as noise. Only two announced themselves as errors.
A check that cannot pass is indistinguishable from a check that always passes,
unless you run it somewhere it matters.

Status as of the run on 2026-08-08/09. Fixed items link to the commit.

| # | What | How it presented | Status |
|---|---|---|---|
| 1 | Stock firmware backup globbed `variants/`, image is in `firmwares/` | `warn` then carried on into the purge, deleting the only copy | fixed |
| 2 | SDK 1.0.1 nests toolchains under `gnu/` | verify failed on a good install; **and** the idempotency check never matched, so every re-run re-downloaded ~1 GB | fixed |
| 3 | `tr -d '\0'` on the devicetree `compatible` | `unrecognised board` on every UNO Q and VENTUNO Q ever | fixed |
| 4 | avahi advertises *both* bridge addresses | `<host>.local` resolved to the unreachable `10.55.0.1` half the time | fixed |
| 5 | `flash-all.sh` ran `west build` outside the workspace | `unknown command "build"` at the last step of a 45-minute run | fixed |
| 6 | `env.sh` hardcoded `$HOME/hybrid` | `zbuild`/`zflash`/`hpy`/`mcucon` broken on any other clone path | fixed |
| 7 | Alias check ran in a non-interactive shell | `command -v zbuild` can never see an alias there; had never passed | fixed |
| 8 | No host C compiler on the image at all | `check.sh mcu` and `ztest.sh` could never have run | fixed |
| 9 | Venv check tested 3 of the 5 packages it installs | `smbus2` and `spidev` absent, reported `0 changed, 5 already correct` | fixed |

---

## The ones worth understanding, not just fixing

### 2 and 9 — checks that make their own gap unreachable

Both are worse than a missed check, and in the same way.

`20-zephyr-sdk.sh` used the wrong path in **two** places: the verify at the end,
and the "already installed?" test before the download. The first is a loud
failure. The second means the install branch runs every time, re-downloading
~1 GB, and *a run that re-downloads looks exactly like one that skipped, only
slower*. Nobody would ever have reported it.

`40-python-venv.sh` is the mirror image. It installs five packages and tests
three. Satisfy the three and the install branch never runs again — so the two
missing ones are not merely undetected, they are **unreachable**. The board
reported `0 changed, 5 already correct` while two libraries were absent.

The rule both break: *a check must cover everything the thing it guards does.*
Where a list drives an action, derive the check from the same list.

### 8 — the dependency nothing declares

The stock image has no `cc` at all. `gcc` is `un` in dpkg, not merely absent.

Everything cross-compiled kept working, because the Zephyr SDK carries its own
`arm-zephyr-eabi`. Only two things wanted the *host* compiler — `native_sim`
ztest builds, and the `spidev` C extension — and both are the kind of thing you
run once and rarely.

The tell was sitting in the tree the whole time: `10-optimize-board.sh` installs
`python3-dev` *for spidev*, i.e. the headers, without the compiler that consumes
them. Half a dependency is a stronger signal than none.

### 1 — the only unrecoverable one

The stock MCU firmware is Arduino's build: not in this repo, not in apt. The
backup step globbed a path that has not existed since core 0.55.2, warned, and
continued into `apt_remove arduino-*`.

Now: `bootstrap.sh` takes the copy during **preflight**, while the tree is
certainly still there, and the purge **refuses** without one. The find logic
lives in `lib.sh` because two callers need the same answer and the path has
already moved once.

Worth recording, because it was not obvious at the time: the image is
**recoverable**. It ships in the `arduino-*` debs, so a factory restore brings
it back. Losing it costs a restore, not the board.

---

## Still unvalidated on this board

Not bugs — features nobody has run since the restore. Each is a plausible home
for finding #10.

| Feature | State |
|---|---|
| `--with-cpu-bars` | Never run. The LED matrix demo — the worked example the README leads with. |
| Fileshare image | Never built. `drive backing file <none>`, so the USB drive appears **empty**. |
| `--with-purge` | Never run. Now safe: the firmware backup exists and the guard works. |
| `--with-learning` | Never run. |
| FOTA | Never exercised end to end on this board. |

## Decisions taken, for the refactor

- **Keep the `10.55.0.0/24` server mode.** It is not legacy; it is what makes
  the board work with a host that is not sharing its internet. `UNOQ_USB_MODE`
  already makes the unused half inert at runtime, which is the cleanup.
- **Keep `10.55.0.1` on the bridge in client mode.** It is the one address that
  survives ICS being switched off, one `route add` from the host away.
- **`docs/usb.md` should lead with client mode.** For a dev board plugged into a
  laptop that shares its connection, client is the common case; server mode is
  currently the default and client reads as the exception. Not yet done.
