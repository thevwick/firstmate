#!/usr/bin/env bash
# Unit tests for is_isolated_worktree, the accept-gate predicate fm-spawn.sh
# uses both inside the treehouse-get worktree-detection poll and as
# validate_spawn_worktree's final assertion.
#
# Background: the poll loop used to accept the first pane cwd that merely
# differed from the project dir. A freshly-created pane can momentarily report
# a transient/garbage cwd (observed: /private/etc/paths.d) before `treehouse
# get` has actually landed it, and that transient path also differs from the
# project dir, so the old loop broke out early and validate_spawn_worktree
# then correctly rejected it, aborting the whole spawn. The fix requires the
# poll's accept condition to be a genuine isolated-worktree check, not just an
# inequality, so a transient non-worktree cwd is skipped instead of accepted.
#
# is_isolated_worktree is defined inline in bin/fm-spawn.sh (which has no
# sourcing guard and runs top-level code immediately), so it is extracted here
# with sed by name/brace anchors and sourced standalone against a real git
# worktree fixture, rather than re-implementing or copying its logic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-race)

FUNC_SRC=$(sed -n '/^is_isolated_worktree() {/,/^}/p' "$SPAWN")
printf '%s\n' "$FUNC_SRC" | grep -q '^is_isolated_worktree() {' \
  || fail "could not extract is_isolated_worktree from $SPAWN"

REPO="$TMP_ROOT/repo"
WORKTREE="$TMP_ROOT/repo-wt"
fm_git_worktree "$REPO" "$WORKTREE" fm/race-test

# A path that exists but is not a git repo at all (mirrors the transient
# /private/etc/paths.d cwd a fresh pane can momentarily report).
NOT_A_REPO="$TMP_ROOT/not-a-repo"
mkdir -p "$NOT_A_REPO"

test_rejects_non_worktree_path() {
  local out status
  out=$(PROJ_ABS_REAL="$TMP_ROOT/repo-primary" bash -c "
    $FUNC_SRC
    is_isolated_worktree '$NOT_A_REPO'
  " 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "expected is_isolated_worktree to reject a non-git-repo path"
  [ -z "$out" ] || fail "predicate must be quiet (no output); got: $out"
  pass "is_isolated_worktree rejects a transient non-worktree path"
}

test_accepts_real_worktree() {
  local out status
  out=$(PROJ_ABS_REAL="$TMP_ROOT/repo-primary" bash -c "
    $FUNC_SRC
    is_isolated_worktree '$WORKTREE'
  " 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "expected is_isolated_worktree to accept a real isolated worktree (status=$status)"
  [ -z "$out" ] || fail "predicate must be quiet (no output); got: $out"
  pass "is_isolated_worktree accepts a genuine isolated worktree"
}

test_rejects_path_equal_to_primary() {
  local out status worktree_real
  worktree_real=$(cd "$WORKTREE" && pwd -P)
  out=$(PROJ_ABS_REAL="$worktree_real" bash -c "
    $FUNC_SRC
    is_isolated_worktree '$WORKTREE'
  " 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "expected is_isolated_worktree to reject a path equal to PROJ_ABS_REAL"
  [ -z "$out" ] || fail "predicate must be quiet (no output); got: $out"
  pass "is_isolated_worktree rejects a worktree that is the primary checkout itself"
}

test_rejects_non_worktree_path
test_accepts_real_worktree
test_rejects_path_equal_to_primary
