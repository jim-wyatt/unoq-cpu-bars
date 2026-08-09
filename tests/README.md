<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The shell test suite

```bash
tools/check.sh shell        # what CI runs
bats tests/                 # just these
bats tests/bind-guard.bats  # one file
```

Shell is the largest thing in this project — about **5,200 lines across 40
scripts**, five times the Python and the C put together — and until this suite
existed it was checked only by `shellcheck` and `shfmt`. Those are linters. They
will tell you a variable is unquoted; they will never tell you the bind guard
counts wrong.

Meanwhile the Python is held at 100% branch coverage by a gate that fails the
build. That gap was the wrong way round: **every one of the twenty-one findings
in [the findings log](../docs/reference/clean-board-findings.md) was in shell or
in a systemd unit.** Not one was in Python or C.

## How it works: no refactor, no board

The obvious way to make shell testable is to split every script into a "decide"
half and a "do" half and test the first. That is a large change to scripts that
currently work, made *before* there are any tests to catch it going wrong —
which is the wrong order.

These scripts already have a seam, because everything they actually do is
another program: `ip`, `nmcli`, `systemctl`, `logger`, `sync`. Putting a
directory of fakes at the front of `PATH` lets the **real script run,
unmodified**, while nothing reaches the board. What you assert on is the `argv`
it would have used.

```bash
stub_body ip <<'SH'
case "$1 $2" in "link show") exit 1 ;; esac   # pretend the bridge is gone
exit 0
SH

run "$PROJECT/usb/usb-route.sh" add 02:00:00:00:00:01 192.168.137.1
[ "$status" -eq 0 ]
! ran_like 'ip route'
```

Everything else is environment variables the scripts already accept —
`UNOQ_STATE_DIR`, `UNOQ_USB_BIND_MAX_ATTEMPTS`, `UNOQ_USB_DEFAULT_ROUTE` — so a
test can point the state directory at a temporary one and set a limit of 3
without touching `/var/lib`.

> **The limit, stated plainly.** This proves what a script *decides to run*, not
> that running it has the intended effect on a kernel. `ip route replace` being
> called with the right arguments is not the same as the route existing. That
> second half is what the board is for, and no amount of this replaces it.

## What is covered, and why those first

| suite | tests | why it was picked |
|---|---:|---|
| [`bind-guard.bats`](bind-guard.bats) | 21 | The worst failure mode in the project. It exists to stop a browning-out USB bind becoming a permanent reboot loop — and if its own counting is wrong it *causes* that outage, on a board that then cannot be reached over USB to fix it. It has been wrong once already. |
| [`usb-route.bats`](usb-route.bats) | 14 | Runs as root, with an address off the wire, and moves the board's **default route** — the setting most able to break a machine remotely while leaving it looking fine. It has been wrong once already. |

Both of those "already" cases are written down as tests:

- udev triggers the bind unit **three times** on a healthy plug-in, so an
  earlier version that counted invocations hit its limit of 3 during the first
  *successful* plug-in and refused to bind ever again.
- the route metric was 500, which **beat** NetworkManager's 600 for wifi, so
  plugging the board into a computer silently handed that computer the default
  route. SSH survived, so nothing looked wrong, while `apt` and `git` stopped.

## Adding a suite

Pick by blast radius, not by line count. The question is *what happens when this
is wrong*, and the scripts worth doing next are the ones where the answer is "a
board nobody can reach".

1. `load helpers/stub` and `stub_setup` in `setup()`.
2. `stub <name>` for anything the script shells out to. Use `stub_body` when it
   needs to answer differently for different arguments.
3. Point the script's own environment variables at `$BATS_TEST_TMPDIR`.
4. **Check the test fails.** A suite that passes the first time it is run may be
   asserting nothing. Break the script on purpose, confirm the right test goes
   red, then put it back.

That last step is not optional. Both suites here were mutation-tested against
the two historical bugs above before being committed.
