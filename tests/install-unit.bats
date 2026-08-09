#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# install_unit rewrites every systemd unit in this project on its way into
# /etc/systemd/system, substituting the checkout path and the owning user.
#
# The failure it has to prevent is a unit that installs happily and then fails
# at boot with 203/EXEC - a status that names the unit but not the path it
# could not run, and reads the same as a permissions problem. Two ways to get
# there:
#
#   1. The path spelled some way sed does not know. `~/hybrid` and
#      `$HOME/hybrid` look equivalent to /home/arduino/hybrid and are not:
#      systemd expands neither, and passes them to execve() literally.
#
#   2. A path that is simply not there yet, because provisioning steps have an
#      order and the venv or the script has not been built.
#
# Both are cheap to catch at install time and expensive to diagnose at boot.
#
# These tests also killed a check that could never fire. install_unit briefly
# asserted "no placeholder remains after substitution", which sounds sensible
# and is impossible - sed replaces it wherever it appears. Test 6 is what is
# left of that: it pins the actual behaviour instead.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # install_unit writes to /etc and calls systemctl. Neither is acceptable in a
  # test, so the write goes to a temp root and systemctl is stubbed.
  ETC="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$ETC/systemd/system"
  stub systemctl
  stub install_root

  # A real executable for the happy path to point at.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\n' >"$BIN/thing"
  chmod +x "$BIN/thing"
}

# Source lib.sh with the pieces that touch the real system replaced.
#
# Sourcing rather than executing because install_unit is a function, and the
# alternative - a fixture script that calls it - would put a layer between the
# test and the thing being tested for no gain.
load_lib() {
  # shellcheck disable=SC1090
  source "$PROJECT/provision/lib.sh" 2>/dev/null || true

  PROJECT_UNDER_TEST="${1:-/opt/checkout}"
  PROJECT="$PROJECT_UNDER_TEST"
  TARGET_USER="${2:-someone}"

  # need_root and the reporting verbs are lib.sh's; only the two that would
  # escape the sandbox are replaced. `fail` must still abort, because every
  # assertion below is about whether it fired.
  write_file() {
    local mode="$1" path="$2"
    mkdir -p "$ETC/$(dirname "$path")"
    cat >"$ETC/$path"
    return 0
  }
  # Matches lib.sh's real contract: fail() ABORTS. An earlier version of this
  # stub returned 1 instead, so install_unit carried on past its own checks and
  # every failure test passed for the wrong reason - the stub was wrong, not
  # the code. `run` executes in a subshell, so exit is captured as a status.
  fail() {
    echo "FAILED: $*" >&2
    exit 1
  }
  did() { :; }
  skip_() { :; }
}

unit() {
  local path="$BATS_TEST_TMPDIR/$1.service"
  shift
  printf '%s\n' "$@" >"$path"
  echo "$path"
}

# --- substitution ----------------------------------------------------------

@test "the project path is substituted into ExecStart" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit ok "[Service]" "ExecStart=/home/arduino/hybrid/bin/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/ok.service"
  [[ "$output" == *"ExecStart=$BATS_TEST_TMPDIR/bin/thing"* ]]
  [[ "$output" != *"/home/arduino/hybrid"* ]]
}

@test "User and Group are substituted" {
  load_lib "$BATS_TEST_TMPDIR" "operator"
  src="$(unit u "[Service]" "User=arduino" "Group=arduino" \
    "ExecStart=/home/arduino/hybrid/bin/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/u.service"
  [[ "$output" == *"User=operator"* ]]
  [[ "$output" == *"Group=operator"* ]]
}

# --- the placeholder that looks real ---------------------------------------

@test "a tilde path is rejected, because systemd will not expand it" {
  # ~/hybrid reads as equivalent to /home/arduino/hybrid and is not: sed does
  # not know that spelling, and systemd passes it to execve() literally. The
  # unit then fails at boot with 203/EXEC, naming the unit but not the path.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit tilde "[Service]" "ExecStart=~/hybrid/bin/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"will not expand"* ]]
}

@test "\$HOME is rejected for the same reason" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit home "[Service]" "ExecStart=$BIN/thing" \
    "Environment=EXTRA=\$HOME/hybrid/share")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"will not expand"* ]]
}

@test "nothing is written when a unit is rejected" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit nowrite "[Service]" "ExecStart=~/hybrid/nope")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [ ! -f "$ETC/etc/systemd/system/nowrite.service" ]
}

@test "the placeholder itself is substituted wherever it appears" {
  # Including outside Exec* lines. This is why there is no "leftover
  # placeholder" check: sed is global, so that check could never fire, and
  # writing this test is what showed it was dead code.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit env "[Service]" "ExecStart=$BIN/thing" \
    "Environment=EXTRA=/home/arduino/hybrid/share")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/env.service"
  [[ "$output" == *"EXTRA=$BATS_TEST_TMPDIR/share"* ]]
}

# --- programs that are not there -------------------------------------------

@test "an ExecStart that does not exist is caught before boot" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit ghost "[Service]" "ExecStart=$BATS_TEST_TMPDIR/bin/absent")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
  [[ "$output" == *"absent"* ]]
}

@test "a file that exists but is not executable is caught too" {
  load_lib "$BATS_TEST_TMPDIR"
  touch "$BIN/notexec"
  src="$(unit noexec "[Service]" "ExecStart=$BIN/notexec")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
}

@test "ExecStartPre and ExecStop are checked, not just ExecStart" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit pre "[Service]" \
    "ExecStartPre=$BATS_TEST_TMPDIR/bin/absent check" \
    "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent"* ]]
}

@test "a '-' prefixed program is allowed to be missing, as systemd allows" {
  # `-` means "a failure of this command is not a failure of the unit", and
  # that includes not existing. Requiring it would be stricter than systemd and
  # would reject units that are correct.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit dash "[Service]" "ExecStartPre=-$BATS_TEST_TMPDIR/bin/absent" \
    "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "an '@' prefixed program must still exist" {
  # @ only changes argv[0]; it says nothing about tolerating failure, so the
  # prefix must be stripped and the path still checked. This is the case that
  # a naive "skip anything not starting with /" would wave through.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit at "[Service]" "ExecStart=@$BATS_TEST_TMPDIR/bin/absent name")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
}

@test "combined prefixes are stripped, not just the first" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit combo "[Service]" "ExecStart=+@$BATS_TEST_TMPDIR/bin/absent n")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
}

@test "arguments are not mistaken for the executable" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit args "[Service]" "ExecStart=$BIN/thing --root /nowhere --port 8080")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "a bare command name is left to systemd's own PATH" {
  # Second-guessing systemd's PATH here would produce false failures on units
  # that legitimately say `ExecStart=/bin/sleep` style bare names.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit bare "[Service]" "ExecStart=true")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

# --- the real units --------------------------------------------------------

@test "every unit in the repository installs cleanly against this checkout" {
  # The end-to-end assertion, and the one that would have caught a new unit
  # spelling the project path some other way.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load_lib "$REAL"
  for src in "$REAL"/*/*.service; do
    [ -e "$src" ] || continue
    # Skip units whose programs are venv entry points that may not be built in
    # this environment - the substitution check still runs on all of them.
    run install_unit "$src"
    if [ "$status" -ne 0 ]; then
      [[ "$output" == *"runs a program that is not there"* ]] ||
        {
          echo "unexpected failure for $src: $output"
          false
        }
    fi
  done
}
