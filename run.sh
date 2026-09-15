#!/usr/bin/env bash
#
# lean-prime — single entry point.
#
#   ./run.sh "fix the failing authentication tests"
#   ./run.sh --list-models
#   ./run.sh --show-prompt
#   ./run.sh test
#
# Lean is compiled rather than interpreted, so this cannot be quite what
# `python main.py` is: something has to build the binary. What this script
# does is make that invisible — it finds the toolchain, brings the build up
# to date, then execs the real program with your arguments. After the first
# build that check costs well under a second and prints nothing.
#
# Nothing here is required: `lake build && .lake/build/bin/lean-prime …`
# does the same thing. This is the convenience wrapper, not a layer the
# program depends on.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

BIN=".lake/build/bin/lean-prime"

die() { printf 'run.sh: %s\n' "$*" >&2; exit 1; }

# --- toolchain ---------------------------------------------------------

if ! command -v lake >/dev/null 2>&1; then
  for candidate in "$HOME/.elan/bin" /root/.elan/bin /usr/local/bin; do
    if [ -x "$candidate/lake" ]; then
      PATH="$candidate:$PATH"
      export PATH
      break
    fi
  done
fi

command -v lake >/dev/null 2>&1 || die \
"lake not found.

Lean's build tool is needed to compile the agent. Install the toolchain with:

    curl https://elan.lean-lang.org/elan-init.sh -sSf | sh

then open a new shell, or add ~/.elan/bin to PATH in this one."

# --- build --------------------------------------------------------------
#
# `lake build` is the staleness check. Deciding for it — comparing source
# mtimes against the binary — gets this wrong: Lean's build is
# content-addressed, so a file whose mtime moved but whose content did not
# produces an identical object and the binary is never relinked. Its mtime
# then stays behind the source's forever and a naive check rebuilds on
# every single run.
#
# A no-op `lake build` is well under a second, so the honest thing is to
# call it every time and keep quiet when it does nothing.

if [ "${LEANPRIME_SKIP_BUILD:-0}" = "1" ]; then
  [ -x "$BIN" ] || die "LEANPRIME_SKIP_BUILD=1 but $BIN does not exist yet"
elif [ ! -x "$BIN" ]; then
  # No binary: this is a full build and takes minutes. Stream it, so the
  # first run does not look like a hang.
  printf 'building for the first time — this takes a few minutes…\n' >&2
  lake build || die "build failed"
else
  # Incremental. Capture, and show the log only when there was something to
  # report: Lake prints a single completion line when it did no work.
  if ! build_log="$(lake build 2>&1)"; then
    printf '%s\n' "$build_log" >&2
    die "build failed"
  fi
  if [ "$(printf '%s\n' "$build_log" | wc -l)" -gt 1 ]; then
    printf '%s\n' "$build_log" >&2
  fi
fi

# --- subcommands this wrapper owns -------------------------------------

case "${1:-}" in
  test|--test)
    exec lake exe lean-prime-tests
    ;;
  build|--build)
    lake build
    exit 0
    ;;
esac

# --- API key ------------------------------------------------------------
#
# Checked here only to fail with an explanation rather than a provider
# error several seconds into a run. Commands that never call the model are
# exempt, so `--help` and `--list-models` work with no key at all.

key_var="${LEANPRIME_API_KEY_ENV:-LEANPRIME_API_KEY}"
needs_key=1
for arg in "$@"; do
  case "$arg" in
    --help|-h|--version|--list-models|--doctor|--show-prompt|--sessions)
      needs_key=0
      break
      ;;
  esac
done
[ "$#" -eq 0 ] && needs_key=0

if [ "$needs_key" -eq 1 ] && [ -z "${!key_var:-}" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  die "no API key in \$$key_var.

Set it for this shell:

    export $key_var='your-key-here'

or put it in a file only you can read and source that. Run ./run.sh --doctor
to check the rest of the configuration."
fi

# --- run ----------------------------------------------------------------

exec "$BIN" "$@"
