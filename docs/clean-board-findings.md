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
next: of the twelve findings below, **five reported success** and four more
printed a warning that read as noise. Only two announced themselves as errors.
A check that cannot pass is indistinguishable from a check that always passes,
unless you run it somewhere it matters.

Status as of the runs on 2026-08-08/09. Fixed items link to the commit.

| # | What | How it presented | Status |
|---|---|---|---|
| 1 | Stock firmware backup globbed `variants/`, image is in `firmwares/` | `warn`, then carried on into the purge having saved nothing — see #12 for what that does and does not cost | fixed |
| 2 | SDK 1.0.1 nests toolchains under `gnu/` | verify failed on a good install; **and** the idempotency check never matched, so every re-run re-downloaded ~1 GB | fixed |
| 3 | `tr -d '\0'` on the devicetree `compatible` | `unrecognised board` on every UNO Q and VENTUNO Q ever | fixed |
| 4 | avahi advertises *both* bridge addresses | `<host>.local` resolved to the unreachable `10.55.0.1` half the time | fixed |
| 5 | `flash-all.sh` ran `west build` outside the workspace | `unknown command "build"` at the last step of a 45-minute run | fixed |
| 6 | `env.sh` hardcoded `$HOME/hybrid` | `zbuild`/`zflash`/`hpy`/`mcucon` broken on any other clone path | fixed |
| 7 | Alias check ran in a non-interactive shell | `command -v zbuild` can never see an alias there; had never passed | fixed |
| 8 | No host C compiler on the image at all | `check.sh mcu` and `ztest.sh` could never have run | fixed |
| 9 | Venv check tested 3 of the 5 packages it installs | `smbus2` and `spidev` absent, reported `0 changed, 5 already correct` | fixed |
| 10 | VS Code machine settings lived only in `~/.vscode-server` | restore wiped them; nothing said so, the board just swapped sooner | fixed |
| 11 | `70-learning-web.sh` printed only the first address per interface, and ignored link state | advertised `10.55.0.1` and a **down** `docker0`, hid the one address the host can reach | fixed |
| 12 | `40-purge-arduino.sh` claimed the purge deletes `~/.arduino15` | it does not — apt removes packages, not `$HOME`. 621 MB still there after a real run | fixed |

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

### 10 — configuration that only existed on the machine

`.vscode/settings.json` says the board-wide tuning lives in
`~/.vscode-server/data/Machine/settings.json`. After the restore that file did
not exist, and nothing anywhere said so.

Every setting in it is one whose default merely *costs* something rather than
breaking anything: `extensions.autoUpdate` came back on (which the README
explicitly calls out as deliberately off), the file watcher went back to
watching ~4 GB of Zephyr checkout and toolchain, and project-wide search walked
all of it. The board simply ran hotter and swapped sooner.

It now lives in `provision/user/vscode-machine-settings.json` and is installed
by `50-shell-env.sh` if absent. The general rule: **configuration that is not in
the repo does not survive a restore, and configuration whose absence is silent
will not be noticed when it does not.**

For scale, on this board VS Code Server plus its Claude Code instances was
1875 MB of 3.6 GB, of which ~620 MB was a second extension host left behind by a
window whose connection had gone away.

### 1 — a guard that saved nothing, and how bad that actually was

The stock MCU firmware is Arduino's build: not in this repo, not in apt. The
backup step globbed a path that has not existed since core 0.55.2, warned, and
continued into `apt_remove arduino-*` having saved nothing.

Now: `bootstrap.sh` takes the copy during **preflight**, while the tree is
certainly still there, and the purge **refuses** without one. The find logic
lives in `lib.sh` because two callers need the same answer and the path has
already moved once.

Two corrections to how this was first written up, both in the direction of it
being *less* dramatic — recorded because #12 is about exactly this failure mode:

- The purge does **not** delete `~/.arduino15`, so the image survives it. What
  the broken glob cost was the *deliberate* copy, not the last one.
- The image is **recoverable** regardless: it ships in the `arduino-*` debs, so
  a factory restore brings it back. Losing it costs a restore, not the board.

The guard still earns its place, for a narrower reason than "otherwise it is
gone forever": the purge is the point after which nobody thinks to look for the
image again, and a restore months later will not feel connected to it.

---

### 12 — a warning that was worse than wrong

`40-purge-arduino.sh` said the purge takes `~/.arduino15` with it, so the stock
image is gone forever. Measured after a real run: `~/.arduino15` is still there,
**621 MB of it**, stock `.hex` included. apt removes packages, not files in
`$HOME`.

Overstating a danger is its own failure mode. The reader who checks and finds it
untrue learns to discount everything else the file says — and this file is one
where the other warnings are real.

What actually eats the image is a **factory restore**, which is also what puts
it back. The guard still belongs here, for a different reason than stated: not
because this script deletes the image, but because it is the point after which
nobody thinks to look for it again.

---

## Validated on this board

Everything below was run end to end after the fixes above, on 2026-08-09.

| Feature | Result |
|---|---|
| CPU-bars demo | Drives the panel: MCU sweep counter `0 → 29,627`, and `+10,554` across a controlled 20-frame run. Boot service stable, 0 restarts, holds `/dev/ttyHS1` as documented. |
| Fileshare image | Builds with MBR + FAT32 at `+1048576`, mounts read-only, and attaches to the live gadget by **re-inserting the medium** — no unbind, so an SSH session over the same cable survives it. |
| Learning web | `HTTP 200`, reachable on the leased USB address. |
| **FOTA** | Full cycle *and* the safety property: upload → staged; `test`+`reset` → swapped with `confirmed: False`; **reset without confirming reverted automatically**; `test`+`reset`+`confirm` survived a further reset. |
| `--with-purge` | Removed four packages, reclaimed ~400 MB, OpenOCD verified working afterwards, all services still up. |
| MCU suites | 26/26 cases, 2/2 suites (needs the `gcc` from finding #8). |
| Host suites | 106 tests, 100% coverage, all 7 gates. |

Nothing in this table had been run on this board before today.

## Decisions taken, for the refactor

- **Keep the `10.55.0.0/24` server mode.** It is not legacy; it is what makes
  the board work with a host that is not sharing its internet. `UNOQ_USB_MODE`
  already makes the unused half inert at runtime, which is the cleanup.
- **Keep `10.55.0.1` on the bridge in client mode.** It is the one address that
  survives ICS being switched off, one `route add` from the host away.
- **`docs/usb.md` should lead with client mode.** For a dev board plugged into a
  laptop that shares its connection, client is the common case; server mode is
  currently the default and client reads as the exception. Not yet done.
