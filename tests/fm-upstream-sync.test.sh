#!/usr/bin/env bash
# Behavior tests for fm-upstream-sync.sh, the fork-vs-upstream drift sweep.
#
# The safety contract is the point of this suite: a fork that has DIVERGED from
# upstream may hold real unlanded work, so it must be left completely untouched
# and reported loudly, never rebased and never force pushed. A fork that is
# strictly behind is an ordinary fast-forward and is reported with the command
# that advances it, but the default run still pushes nothing.
#
# It also pins the inertness that keeps this invisible for everyone who has not
# forked: a single-remote install (no upstream remote) and an already-current
# fork both stay silent, including through bootstrap's UPSTREAM_SYNC relay.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-tests)
SYNC="$ROOT/bin/fm-upstream-sync.sh"

# --- fixtures ---------------------------------------------------------------

commit_file() {  # <repo> <name> <content>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# new_case <name>: an upstream bare repo, a fork bare repo seeded from it, and a
# local clone wired origin=fork / upstream=upstream. Echoes the case dir.
# Layout: <case>/upstream.git, <case>/fork.git, <case>/clone, <case>/seed
# The caller names its own case rather than a shared counter incrementing one:
# callers use `c=$(new_case ...)`, whose command substitution runs in a subshell,
# so a counter would never advance in the parent and every case would collide on
# one directory. Each case dir is cleared first so a rerun starts clean.
new_case() {  # <name>
  local c=$TMP_ROOT/$1 seed
  rm -rf "$c"
  mkdir -p "$c"
  seed="$c/seed"
  git init -q --bare --initial-branch=main "$c/upstream.git"
  git init -q --bare --initial-branch=main "$c/fork.git"

  git init -q --initial-branch=main "$seed"
  commit_file "$seed" base.txt base
  git -C "$seed" push -q "$c/upstream.git" main
  git -C "$seed" push -q "$c/fork.git" main

  git clone -q "$c/fork.git" "$c/clone"
  git -C "$c/clone" remote add upstream "$c/upstream.git"
  git -C "$c/clone" fetch -q upstream
  printf '%s\n' "$c"
}

# The advance_* fixtures deliberately leave the clone's remote-tracking refs
# stale. Refreshing them here would pre-fetch the very refs the script is
# responsible for refreshing, hiding a stale-ref misclassification from the suite.
#
# advance_upstream <case> <n>: add n commits to upstream only.
advance_upstream() {  # <case> <n>
  local c=$1 n=$2 work="$1/up-work" i
  rm -rf "$work"
  git clone -q "$c/upstream.git" "$work"
  for i in $(seq 1 "$n"); do
    commit_file "$work" "up-$i.txt" "upstream $i"
  done
  git -C "$work" push -q origin main
}

# advance_fork <case> <n>: add n commits to the fork only (creates divergence
# when upstream has also moved).
advance_fork() {  # <case> <n>
  local c=$1 n=$2 work="$1/fork-work" i
  rm -rf "$work"
  git clone -q "$c/fork.git" "$work"
  for i in $(seq 1 "$n"); do
    commit_file "$work" "fork-$i.txt" "fork $i"
  done
  git -C "$work" push -q origin main
}

run_sync() {  # <case> [args...]
  local c=$1; shift
  FM_ROOT_OVERRIDE="$c/clone" "$SYNC" "$@" 2>&1
}

fork_head() {  # <case>
  git -C "$1/fork.git" rev-parse main
}

upstream_head() {  # <case>
  git -C "$1/upstream.git" rev-parse main
}

# --- tests ------------------------------------------------------------------

test_no_upstream_remote_is_silent_skip() {
  local c out
  c=$(new_case no-upstream)
  git -C "$c/clone" remote remove upstream
  out=$(run_sync "$c")
  assert_contains "$out" "skipped: no upstream remote" \
    "a single-remote install should skip, not error"
  pass "fm-upstream-sync: no upstream remote is a benign skip"
}

test_current_fork_reports_current() {
  local c out
  c=$(new_case current)
  out=$(run_sync "$c")
  assert_contains "$out" "firstmate: current" \
    "a fork level with upstream should report current"
  pass "fm-upstream-sync: an already-current fork reports current"
}

# A fork carrying its own work on top of a fully-merged upstream is AHEAD but
# not behind. That is the normal resting state of any fork, not drift, so it
# must read as current; reporting it as STUCK would false-alarm at every single
# session start for as long as the fork carries work.
test_ahead_only_fork_is_current_not_stuck() {
  local c out
  c=$(new_case ahead-only)
  advance_fork "$c" 3
  out=$(run_sync "$c")
  assert_contains "$out" "firstmate: current" \
    "a fork that is only ahead of upstream should read as current"
  assert_not_contains "$out" "STUCK" \
    "a fork that is only ahead has not diverged and must not be reported as STUCK"
  pass "fm-upstream-sync: an ahead-only fork is current, not drift"
}

test_behind_fork_reports_and_pushes_nothing() {
  local c out before
  c=$(new_case behind)
  advance_upstream "$c" 3
  before=$(fork_head "$c")
  out=$(run_sync "$c")
  assert_contains "$out" "behind: fork is 3 commits behind upstream/main" \
    "a behind fork should be reported with its exact distance"
  assert_contains "$out" "--push" \
    "the behind report should name the command that advances the fork"
  [ "$(fork_head "$c")" = "$before" ] \
    || fail "the default run must not push anything to the fork"
  pass "fm-upstream-sync: a behind fork is reported and nothing is pushed"
}

# The default run is REPORT ONLY. A routine session-start sweep must never move a
# branch nobody asked it to move, and advancing local main past the fork's origin
# would also push upstream code into anything based on this checkout.
test_default_run_leaves_local_default_branch_unmoved() {
  local c before
  c=$(new_case behind-local-ff)
  advance_upstream "$c" 2
  before=$(git -C "$c/clone" rev-parse main)
  run_sync "$c" >/dev/null
  [ "$(git -C "$c/clone" rev-parse main)" = "$before" ] \
    || fail "the default run must not move the local default branch"
  pass "fm-upstream-sync: the default run reports drift without moving the local branch"
}

# --push is the deliberate, human-invoked action, so it is the one path allowed to
# bring the local checkout along with the fork it just advanced.
test_push_fast_forwards_local_default_branch() {
  local c
  c=$(new_case push-local-ff)
  advance_upstream "$c" 2
  run_sync "$c" --push >/dev/null
  [ "$(git -C "$c/clone" rev-parse main)" = "$(upstream_head "$c")" ] \
    || fail "--push should leave the local default branch level with upstream"
  pass "fm-upstream-sync: --push fast-forwards the local default branch too"
}

# Classification is read off origin/<default>, so the script must refresh that ref
# itself. If it trusted a stale one, a fork that gained commits behind its back
# would read as 0 ahead and be misreported as a clean fast-forward - defeating the
# STUCK path that is the whole safety guarantee.
test_stale_origin_ref_still_classifies_divergence() {
  local c out stale
  c=$(new_case stale-origin)
  advance_upstream "$c" 2
  advance_fork "$c" 1
  stale=$(git -C "$c/clone" rev-parse origin/main)
  [ "$stale" != "$(fork_head "$c")" ] \
    || fail "fixture bug: origin/main should still be stale before the run"

  out=$(run_sync "$c")
  assert_contains "$out" "STUCK:" \
    "a fork advanced behind the script's back must still be seen as diverged"
  assert_contains "$out" "1 ahead and 2 behind" \
    "the refreshed comparison should count the fork's unfetched commits"
  pass "fm-upstream-sync: a stale origin ref is refreshed before classifying"
}

# The safety-critical case. A diverged fork holds commits upstream does not;
# advancing it would need a rebase and a force push, which is never automatic.
test_diverged_fork_is_stuck_and_untouched() {
  local c out before_fork before_local
  c=$(new_case diverged)
  advance_upstream "$c" 2
  advance_fork "$c" 1
  before_fork=$(fork_head "$c")
  before_local=$(git -C "$c/clone" rev-parse main)

  out=$(run_sync "$c")
  assert_contains "$out" "STUCK:" "a diverged fork must be reported as STUCK"
  assert_contains "$out" "1 ahead and 2 behind" \
    "the STUCK report should quantify the divergence in both directions"
  assert_contains "$out" "needs attention" \
    "the STUCK report should read as loud, per fm-fleet-sync's convention"
  [ "$(fork_head "$c")" = "$before_fork" ] \
    || fail "a diverged fork must never be pushed"
  [ "$(git -C "$c/clone" rev-parse main)" = "$before_local" ] \
    || fail "a diverged fork must not have its local default branch moved either"
  pass "fm-upstream-sync: a diverged fork is STUCK and left completely untouched"
}

test_diverged_fork_refuses_push_too() {
  local c out before
  c=$(new_case diverged-push)
  advance_upstream "$c" 2
  advance_fork "$c" 1
  before=$(fork_head "$c")

  out=$(run_sync "$c" --push)
  assert_contains "$out" "STUCK:" "--push on a diverged fork must still report STUCK"
  [ "$(fork_head "$c")" = "$before" ] \
    || fail "--push must never force a diverged fork forward"
  pass "fm-upstream-sync: --push refuses a diverged fork rather than forcing it"
}

test_push_fast_forwards_the_fork() {
  local c out
  c=$(new_case push-ff)
  advance_upstream "$c" 2
  out=$(run_sync "$c" --push)
  assert_contains "$out" "updated: fork fast-forwarded 2 commits" \
    "--push on a behind fork should report the fast-forward"
  [ "$(fork_head "$c")" = "$(upstream_head "$c")" ] \
    || fail "--push should leave the fork level with upstream"
  pass "fm-upstream-sync: --push fast-forwards a behind fork to upstream"
}

test_push_is_idempotent() {
  local c out
  c=$(new_case push-idem)
  advance_upstream "$c" 1
  run_sync "$c" --push >/dev/null
  out=$(run_sync "$c" --push)
  assert_contains "$out" "firstmate: current" \
    "a second --push with nothing to do should report current"
  pass "fm-upstream-sync: --push is idempotent once the fork is level"
}

test_unknown_argument_is_rejected() {
  local c out rc
  c=$(new_case bad-arg)
  out=$(FM_ROOT_OVERRIDE="$c/clone" "$SYNC" --rebase 2>&1) && rc=0 || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "an unknown argument should exit non-zero"
  assert_contains "$out" "unknown argument" "an unknown argument should say so"
  pass "fm-upstream-sync: an unknown argument is rejected"
}

# Bootstrap relays only the actionable outcomes, so a non-forked install and a
# current fork add no noise to the session-start digest.
test_bootstrap_relays_behind_and_stuck_only() {
  local c out
  c=$(new_case bootstrap-relay)

  # Current fork: no UPSTREAM_SYNC line at all.
  out=$(FM_ROOT_OVERRIDE="$c/clone" FM_HOME="$c/clone" \
        "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "UPSTREAM_SYNC:" \
    "a current fork should add no UPSTREAM_SYNC line to the digest"

  # Behind fork: one actionable line.
  advance_upstream "$c" 2
  out=$(FM_ROOT_OVERRIDE="$c/clone" FM_HOME="$c/clone" \
        "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "UPSTREAM_SYNC: firstmate: behind:" \
    "bootstrap should relay a behind fork as an UPSTREAM_SYNC line"
  pass "fm-bootstrap: relays actionable UPSTREAM_SYNC outcomes and stays quiet otherwise"
}

test_no_upstream_remote_is_silent_skip
test_current_fork_reports_current
test_ahead_only_fork_is_current_not_stuck
test_behind_fork_reports_and_pushes_nothing
test_default_run_leaves_local_default_branch_unmoved
test_push_fast_forwards_local_default_branch
test_stale_origin_ref_still_classifies_divergence
test_diverged_fork_is_stuck_and_untouched
test_diverged_fork_refuses_push_too
test_push_fast_forwards_the_fork
test_push_is_idempotent
test_unknown_argument_is_rejected
test_bootstrap_relays_behind_and_stuck_only
