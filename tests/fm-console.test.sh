#!/usr/bin/env bash
# Smoke tests for fm-console: the launcher self-locates and ensures deps, the
# app boots headlessly without a crash, and the Node package's own unit +
# render suite passes. The deep logic (state parsing, ticket extraction, card
# grouping, command composition, bridge target resolution) lives in the Node
# tests this script drives; it does not re-encode that logic in bash.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/fm-console.sh"
PKG="$ROOT/bin/fm-console"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# --- launcher --help works and names the bridge env knobs -------------------
help_out=$("$LAUNCHER" --help 2>&1) || fail "launcher --help exited non-zero"
assert_contains "$help_out" "fm-console" "help output names the tool"
assert_contains "$help_out" "FM_SUPERVISOR_TARGET" "help documents the bridge target knob"
pass "launcher --help self-locates and prints usage"

# --- ensure Node deps are present so --check can boot ------------------------
# node_modules is gitignored; install once if missing, mirroring the launcher.
if [ ! -d "$PKG/node_modules/ink" ]; then
  ( cd "$PKG" && npm install --silent ) || fail "npm install for fm-console failed"
fi
pass "fm-console dependencies present"

# --- headless boot against a throwaway home with a stub snapshot ------------
# The app shells fm-fleet-snapshot.sh; point FM_HOME at a temp home whose bin/
# has a stub so the boot touches no real fleet.
TMP_HOME=$(fm_test_tmproot fm-console)
mkdir -p "$TMP_HOME/bin" "$TMP_HOME/state"
cat > "$TMP_HOME/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "schema": "fm-fleet-snapshot.v1", "tasks": [], "backlog": { "records": [] } }
JSON
SH
chmod +x "$TMP_HOME/bin/fm-fleet-snapshot.sh"

# --check renders once, then exits 0. It must not require a TTY.
if FM_HOME="$TMP_HOME" "$LAUNCHER" --check </dev/null >/dev/null 2>&1; then
  pass "app boots headlessly and exits cleanly (empty fleet)"
else
  fail "app --check did not boot/exit cleanly"
fi

# --- Node unit + render suite ----------------------------------------------
if ( cd "$PKG" && npm test --silent >/dev/null 2>&1 ); then
  pass "fm-console Node unit + render suite passes"
else
  fail "fm-console Node test suite failed"
fi

pass "fm-console smoke tests complete"
