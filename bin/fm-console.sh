#!/usr/bin/env bash
# fm-console.sh - launch the full-screen firstmate control console.
#
# A pure terminal UI (Ink) that reads this firstmate home's on-disk state and
# bridges captain commands into the running primary session via bin/fm-send.sh.
# There is no server, no browser, and no network port - see docs/fm-console.md.
#
# This launcher self-locates the repo, ensures the Ink package's deps are
# installed (once), and execs the Node app. FM_HOME selects the home to operate
# on (defaults to this repo root); FM_SUPERVISOR_TARGET selects the primary
# firstmate pane the command bridge sends into (see docs/fm-console.md).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/fm-console"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to run fm-console (Node + Ink); install node and retry" >&2
  exit 1
fi

# Ensure deps are present. node_modules is gitignored, so a fresh checkout needs
# one install. Use npm ci when the lockfile is present for a reproducible tree,
# falling back to npm install otherwise.
if [ ! -d "$PKG_DIR/node_modules/ink" ]; then
  echo "fm-console: installing dependencies (one-time)..." >&2
  if [ -f "$PKG_DIR/package-lock.json" ]; then
    ( cd "$PKG_DIR" && npm ci --silent ) || ( cd "$PKG_DIR" && npm install --silent )
  else
    ( cd "$PKG_DIR" && npm install --silent )
  fi
fi

# Export the resolved bin dir so the app never has to guess it from its own path.
export FM_CONSOLE_BIN="$SCRIPT_DIR"

exec node "$PKG_DIR/src/cli.js" "$@"
