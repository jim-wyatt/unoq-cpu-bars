# Quality gates

One command runs everything:

```bash
~/hybrid/tools/check.sh              # all gates
~/hybrid/tools/check.sh --fast       # skip the MCU suite (~70s of Zephyr build)
~/hybrid/tools/check.sh --fix        # reformat in place, then check
~/hybrid/tools/check.sh python       # one area: python | shell | c | mcu
```

Gates keep running after a failure, so one pass shows you all the work rather
than the first thing to break. Exit status is non-zero if any failed.

| Gate | Tool | Covers |
|---|---|---|
| lint | `ruff check` | `python/` |
| format | `ruff format` | `python/` |
| types | `mypy --strict` | `python/` incl. tests |
| tests | `pytest` + coverage | `python/`, gate at **100%** |
| shell lint | `shellcheck -x` | every tracked `*.sh` |
| shell format | `shfmt -i 2 -ci` | every tracked `*.sh` |
| C format | `clang-format` | `mcu/**/*.[ch]`, Zephyr's own style |
| MCU tests | `ztest` on `native_sim` | `mcu/app/include/app_proto.h`, `mcu/app/src/bars.c` |

---

## Setup

```bash
~/hybrid/tools/install-dev-tools.sh   # no sudo, no apt
~/hybrid/tools/install-hooks.sh       # pre-commit -> check.sh --fast
```

`install-dev-tools.sh` puts ruff, mypy, pytest and clang-format in the project
venv (mypy has to import `gpiod`/`pyserial`/`smpclient` to check the code that
uses them), and fetches `shellcheck` and `shfmt` from upstream releases into
`~/.local/bin` — Debian's packages would need root. It detects the
architecture, so the same script works on the board (aarch64) and in CI
(x86_64).

The pre-commit hook runs `--fast`; the MCU suite is too slow to sit in front of
every commit. Skip it once with `git commit --no-verify`.

> The `pre-commit` framework is deliberately not used. It fetches its own
> pinned copies of ruff and shellcheck — a second toolchain to keep in step
> with the one `check.sh` uses, on a board with 3.6 GiB of RAM.

---

## Tests

```bash
cd ~/hybrid/python && ../.venv/bin/pytest      # 110 tests, 100% coverage
../.venv/bin/pytest -m hardware                # opt-in: needs a live MCU
~/hybrid/mcu/ztest.sh                          # MCU suites on native_sim (30 cases)
```

**Nothing in the default suite touches hardware.** Every serial port and GPIO
chip is faked, because the suite has to be runnable on a board that is
mid-flash, and a test that quietly drove the real BOOT0 line would be worse
than no test. The fakes imitate the awkward parts of the real thing — the shell
echoes your command back, wraps output in ANSI, and dribbles bytes in so the
prompt rarely lands in the first read.

Checks that genuinely need a board live behind `-m hardware` and are deselected
by default.

Three suites are not about behaviour at all:

- **The GPIO line numbers** (`test_link.py`) are pinned because nothing
  upstream records them. A "tidy up" has no source of truth to check against
  except that test.
- **The unsigned-image guard** (`test_fota.py`) is pinned because getting it
  wrong stops the board booting.
- **The panel constants** (`test_contract.py`) are pinned across languages: C
  macros cannot be imported into Python, so `unoq/mcu.py` holds a second copy
  of the LED matrix geometry. That test parses `app_proto.h` and fails if the
  two drift, which is what makes the duplication safe to have.

Coverage gates at 100%, which is where it currently sits. That is a deliberate
ratchet — new code needs a test — and it is one line in `pyproject.toml` if you
want it lower.

### The MCU suite tests the firmware, not a copy of it

`mcu/app/include/app_proto.h` holds the MPU↔MCU contract: the blink bounds, the
`app status` format string, the settings key, the watchdog timeout. Three
parties depend on it agreeing —

```
mcu/app/src/main.c        produces the status line, validates blink
mcu/tests/link_protocol/  tests these definitions directly
python/unoq/mcu.py        parses the status line, calls `app blink`
```

— so the test includes the same header `main.c` does. It used to keep its own
copy of the range check and format string, which meant it could not fail when
the firmware changed. Confirmed by mutation: renaming `uptime_ms=` in the
header now fails the suite.

**A change to that header is a protocol change.** Update `unoq/mcu.py` and its
tests in the same commit.

---

## CI

`.github/workflows/ci.yml` runs `tools/check.sh python shell c` on push and
pull request, so green CI means the same thing as a clean local run.

`ztest` is the one gate CI skips: it needs a Zephyr workspace and SDK (~5 GB)
that is not worth installing per job. Run it on the board with
`tools/check.sh mcu`.

The runner is x86_64 while the board is aarch64. That is fine here — `gpiod`
ships manylinux wheels for both, and the tests use fakes, so nothing in the job
depends on the architecture.

---

## Conventions worth knowing

- **`unoq/*` ignores the `PT` rules.** They are pytest-style checks and misfire
  on `fota.test()` — MCUboot's "mark this image pending", not a test.
- **`__all__` is not sorted** (`RUF022` off). It is grouped by meaning, which is
  the useful order for a reader.
- **Blind `except Exception` is `contextlib.suppress`**, with the reason in a
  comment at each site. There are three, all on hardware paths where raising
  would make the API unusable on a board whose link is already up.
- **C follows Zephyr's own `.clang-format`**, copied from the Zephyr tree like
  `mcu/board-support/`. Re-copy it after a Zephyr version bump.
