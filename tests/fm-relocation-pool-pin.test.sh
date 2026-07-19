#!/usr/bin/env bash
# Static contract test for the treehouse pool-root pin every suite that touches a
# relocating launcher needs.
#
# bin/fm-wake-lib.sh's fm_relocate_from_disposable_cwd moves a launcher out of a
# treehouse pool slot before it starts anything long-lived. A suite that runs a
# launcher from the repo checkout while pointing FM_HOME at a temp dir is exactly
# that shape whenever the checkout is itself a pool slot, which it is for any
# crewmate task worktree, so the launcher relocates and warns there but not in CI.
# tests/lib.sh pins FM_TREEHOUSE_POOL_ROOT at an absent pool to make the guard
# inert tree-wide, but a standalone suite that never reaches that library gets no
# pin, and that gap has been found by hand three separate times. This test turns
# it into an authoring-time failure instead.
#
# A suite that references a relocating launcher must do one of three things:
#   1. reach tests/lib.sh, directly or through a helper, and inherit the pin;
#   2. set FM_TREEHOUSE_POOL_ROOT itself, as a standalone suite must;
#   3. carry an explicit opt-out marker naming why it is unaffected.
# The marker exists so a suite that only mentions a launcher, or only sources one
# without executing it, records that decision in the file rather than defaulting
# into a silent exemption, and so no pin is added where it would guard nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TESTS_DIR="$ROOT/tests"
OPT_OUT_MARKER='relocation-pool-pin: not-needed'
LAUNCHER_RE='bin/fm-(watch|watch-arm|watch-checkpoint|afk-start)\.sh'

# Whether a file reaches tests/lib.sh through its own sourcing chain. Helpers such
# as tests/wake-helpers.sh and tests/secondmate-helpers.sh source it in turn, so a
# suite can inherit the pin without naming the library itself.
reaches_test_lib() {
  local file=$1 seen=${2:-} dep
  case " $seen " in *" $file "*) return 1 ;; esac
  seen="$seen $file"
  [ "$(basename "$file")" = lib.sh ] && return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ -f "$TESTS_DIR/$dep" ] || continue
    reaches_test_lib "$TESTS_DIR/$dep" "$seen" && return 0
  done < <(grep -oE '\$\{?BASH_SOURCE\[0\]\}?"?\)?/[a-zA-Z0-9._-]+\.sh' "$file" 2>/dev/null | sed 's|.*/||' | sort -u)
  return 1
}

test_every_launcher_suite_has_a_pool_pin() {
  local suite name unpinned=""
  for suite in "$TESTS_DIR"/*.test.sh; do
    name=$(basename "$suite")
    grep -qE "$LAUNCHER_RE" "$suite" || continue
    reaches_test_lib "$suite" && continue
    # An assignment only, so prose naming the variable cannot pass for a pin.
    grep -qE '(^|[[:space:];&|(])(export[[:space:]]+)?FM_TREEHOUSE_POOL_ROOT=' "$suite" && continue
    grep -qF "$OPT_OUT_MARKER" "$suite" && continue
    unpinned="$unpinned $name"
  done
  [ -z "$unpinned" ] || fail "standalone suites touch a relocating launcher with no pool-root pin and no opt-out marker:$unpinned"
  pass "every suite that touches a relocating launcher inherits, sets, or documents its pool-root pin"
}

# The pin only helps where the guard can actually fire, so a marker must not be
# used to excuse a suite that really does run a launcher from its own cwd.
test_opt_out_markers_state_a_reason() {
  local suite name line self
  self=$(basename "${BASH_SOURCE[0]}")
  for suite in "$TESTS_DIR"/*.test.sh; do
    name=$(basename "$suite")
    # This file defines the marker string, so its own occurrences are the
    # definition rather than a claimed exemption.
    [ "$name" = "$self" ] && continue
    grep -qF "$OPT_OUT_MARKER" "$suite" || continue
    line=$(grep -F "$OPT_OUT_MARKER" "$suite" | head -1)
    case "$line" in
      *"$OPT_OUT_MARKER"' - '?*) ;;
      *) fail "$name has a bare pool-pin opt-out marker with no reason after it" ;;
    esac
  done
  pass "every pool-pin opt-out marker records why the suite is unaffected"
}

test_shared_pin_is_owned_by_the_test_library() {
  assert_grep 'export FM_TREEHOUSE_POOL_ROOT=' "$TESTS_DIR/lib.sh" \
    "tests/lib.sh lost the tree-wide pool-root pin every sourcing suite relies on"
  if grep -q 'export TREEHOUSE_DIR=' "$TESTS_DIR/lib.sh"; then
    fail "tests/lib.sh must not pin TREEHOUSE_DIR, which is the real treehouse CLI's own pool root"
  fi
  pass "the tree-wide pin is owned by tests/lib.sh and leaves the real treehouse CLI alone"
}

test_every_launcher_suite_has_a_pool_pin
test_opt_out_markers_state_a_reason
test_shared_pin_is_owned_by_the_test_library
