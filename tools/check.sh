#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Run every quality gate in the project. This is what CI runs.
#
#   ~/hybrid/tools/check.sh              # everything
#   ~/hybrid/tools/check.sh --fix        # reformat in place, then check
#   ~/hybrid/tools/check.sh --fast       # skip the MCU suite (~70s of build)
#   ~/hybrid/tools/check.sh python       # one area: python | shell | c | docs | mcu
#
# Every gate runs even if an earlier one fails, so one pass shows you all the
# work rather than the first thing to break. Exit status is non-zero if any
# gate failed.
#
# Missing tools are failures, not skips: a gate that silently does nothing is
# worse than no gate. Install them with tools/install-dev-tools.sh.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"
export PATH="$HOME/.local/bin:$PATH"

FIX=0
FAST=0
AREAS=()
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    python | shell | c | mcu | docs) AREAS+=("$arg") ;;
    *)
      echo "unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done
[ ${#AREAS[@]} -eq 0 ] && AREAS=(python shell c docs mcu)

if [ -t 1 ]; then
  RED=$'\033[31m' GREEN=$'\033[32m' DIM=$'\033[2m' BOLD=$'\033[1m' OFF=$'\033[0m'
else
  RED="" GREEN="" DIM="" BOLD="" OFF=""
fi

FAILED=()
PASSED=()

# run <name> <command...> - report and record, never abort the script.
run() {
  local name="$1"
  shift
  printf '%s>>> %s%s\n' "$BOLD" "$name" "$OFF"
  if "$@"; then
    PASSED+=("$name")
  else
    FAILED+=("$name")
    printf '%s    FAILED: %s%s\n' "$RED" "$name" "$OFF"
  fi
  echo
}

# need <tool> <gate name> - a missing tool fails its gate rather than
# vanishing from the report. For tools expected on PATH.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  FAILED+=("$2 (missing tool: $1)")
  printf '%s    MISSING: %s - run tools/install-dev-tools.sh%s\n' "$RED" "$1" "$OFF"
  return 1
}

# have <tool> <gate name> - the same contract for tools in the project venv.
# Without this, a venv missing mypy or pytest reported "All 2 gates passed" and
# exited 0, having type-checked nothing and run no tests at all.
have() {
  [ -x "$VENV/bin/$1" ] && return 0
  FAILED+=("$2 (missing tool: $VENV/bin/$1)")
  printf '%s    MISSING: %s/bin/%s - run tools/install-dev-tools.sh%s\n' "$RED" "$VENV" "$1" "$OFF"
  return 1
}

wanted() {
  local a
  for a in "${AREAS[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# --- python ----------------------------------------------------------------

if wanted python; then
  cd "$PROJECT/python" || exit 1
  if have ruff "ruff"; then
    if [ "$FIX" = 1 ]; then
      run "ruff format" "$VENV/bin/ruff" format .
      run "ruff --fix" "$VENV/bin/ruff" check --fix .
    else
      run "ruff lint" "$VENV/bin/ruff" check .
      run "ruff format" "$VENV/bin/ruff" format --check .
    fi
  fi
  have mypy "mypy (strict)" && run "mypy (strict)" "$VENV/bin/mypy"
  # Coverage threshold lives in pyproject.toml, so it fails here too.
  have pytest "pytest + coverage" && run "pytest + coverage" "$VENV/bin/pytest"
fi

# --- shell -----------------------------------------------------------------

if wanted shell; then
  cd "$PROJECT" || exit 1
  mapfile -t SCRIPTS < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.venv/*')
  if [ ${#SCRIPTS[@]} -gt 0 ]; then
    need shellcheck "shellcheck" && run "shellcheck" shellcheck -x "${SCRIPTS[@]}"
    if need shfmt "shfmt"; then
      if [ "$FIX" = 1 ]; then
        run "shfmt (write)" shfmt -i 2 -ci -w "${SCRIPTS[@]}"
      else
        run "shfmt" shfmt -i 2 -ci -d "${SCRIPTS[@]}"
      fi
    fi
  fi
fi

# --- c ---------------------------------------------------------------------

if wanted c; then
  cd "$PROJECT" || exit 1
  mapfile -t CFILES < <(git ls-files 'mcu/**/*.c' 'mcu/**/*.h' 2>/dev/null)
  CF="$VENV/bin/clang-format"
  command -v clang-format >/dev/null 2>&1 && [ ! -x "$CF" ] && CF=clang-format
  if [ ${#CFILES[@]} -gt 0 ]; then
    if [ ! -x "$CF" ] && ! command -v "$CF" >/dev/null 2>&1; then
      FAILED+=("clang-format (missing tool)")
      printf '%s    MISSING: clang-format - run tools/install-dev-tools.sh%s\n' "$RED" "$OFF"
    elif [ "$FIX" = 1 ]; then
      run "clang-format (write)" "$CF" -i "${CFILES[@]}"
    else
      run "clang-format" "$CF" --dry-run --Werror "${CFILES[@]}"
    fi
  fi
fi

# --- docs ------------------------------------------------------------------

if wanted docs; then
  cd "$PROJECT" || exit 1
  # --strict, so a link to a page that moved fails here instead of 404ing for
  # a reader. This gate is the reason the docs tree can be reorganised at all.
  have mkdocs "docs (mkdocs --strict)" &&
    run "docs (mkdocs --strict)" "$PROJECT/tools/build-docs.sh"
fi

# --- mcu -------------------------------------------------------------------

if wanted mcu; then
  if [ "$FAST" = 1 ]; then
    printf '%s>>> ztest (skipped: --fast)%s\n\n' "$DIM" "$OFF"
  else
    # Builds Zephyr for native_sim, so this is the slow one (~70s).
    run "ztest (native_sim)" "$PROJECT/mcu/ztest.sh"
  fi
fi

# --- summary ---------------------------------------------------------------

printf '%s--- summary ---%s\n' "$BOLD" "$OFF"
for p in "${PASSED[@]}"; do printf '  %sPASS%s  %s\n' "$GREEN" "$OFF" "$p"; done
for f in "${FAILED[@]}"; do printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$f"; done

if [ ${#FAILED[@]} -gt 0 ]; then
  printf '\n%d gate(s) failed.\n' "${#FAILED[@]}"
  exit 1
fi
printf '\nAll %d gates passed.\n' "${#PASSED[@]}"
