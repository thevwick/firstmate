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
  local c out before rc
  c=$(new_case diverged-push)
  advance_upstream "$c" 2
  advance_fork "$c" 1
  before=$(fork_head "$c")

  out=$(run_sync "$c" --push) && rc=0 || rc=$?
  assert_contains "$out" "STUCK:" "--push on a diverged fork must still report STUCK"
  [ "${rc:-0}" -ne 0 ] \
    || fail "--push refusing to advance the fork must not exit like a success"
  [ "$(fork_head "$c")" = "$before" ] \
    || fail "--push must never force a diverged fork forward"
  pass "fm-upstream-sync: --push refuses a diverged fork rather than forcing it"
}

# A report-only run is doing its job when it reports a divergence, so it stays a
# success; only --push, which was asked to advance the fork and did not, fails.
test_report_only_stuck_still_exits_zero() {
  local c rc
  c=$(new_case diverged-report-rc)
  advance_upstream "$c" 2
  advance_fork "$c" 1
  run_sync "$c" >/dev/null && rc=0 || rc=$?
  [ "${rc:-0}" -eq 0 ] \
    || fail "a report-only run that found drift should still exit 0"
  pass "fm-upstream-sync: a report-only STUCK is a successful report"
}

# The local fast-forward is a second, independent step, and running --push from a
# feature branch is the common case. When only the fork moved, the report must say
# so rather than reading as a full success and stranding the local branch silently.
test_push_reports_when_local_branch_could_not_follow() {
  local c out
  c=$(new_case push-local-blocked)
  advance_upstream "$c" 2
  git -C "$c/clone" checkout -q -b feature

  out=$(run_sync "$c" --push)
  assert_contains "$out" "updated: fork fast-forwarded 2 commits" \
    "the fork really did advance, so that fact stays in the report"
  assert_contains "$out" "local main branch not moved" \
    "the report must say the local default branch was left behind"
  assert_contains "$out" "on feature, expected main" \
    "the report should carry the concrete reason the local branch could not follow"
  [ "$(fork_head "$c")" = "$(upstream_head "$c")" ] \
    || fail "--push should still have advanced the fork itself"
  pass "fm-upstream-sync: --push reports a local branch it could not bring along"
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

# The push-failure classification must not read git's prose, because those strings
# are translated: on a non-English machine a genuine non-fast-forward would fall
# through to the benign arm and be reported as a network skip, inverting the one
# signal the STUCK line exists to raise. The cause is read off the refs instead,
# so pinning git to a non-English locale must not change the verdict.
test_push_rejection_is_classified_without_reading_git_prose() {
  local c out rc
  c=$(new_case push-rejected-locale)
  advance_upstream "$c" 2
  # The fork gains its own commit only AFTER the script has fetched and decided it
  # is a clean fast-forward, so the run gets all the way to a real push that origin
  # then refuses. A pre-receive hook on the fork is the deterministic way to land
  # that race: it advances the fork's own main and then rejects the push.
  cat > "$c/fork.git/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
# Out of the push quarantine, so the sneaked-in commit survives the rejection the
# way a concurrent push by someone else would.
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
old=$(git rev-parse refs/heads/main)
new=$(git commit-tree "$old^{tree}" -p "$old" -m "sneaked in")
git update-ref refs/heads/main "$new"
exit 1
EOF
  chmod +x "$c/fork.git/hooks/pre-receive"

  out=$(LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 LANGUAGE=de run_sync "$c" --push) && rc=0 || rc=$?
  assert_contains "$out" "STUCK: origin/main moved and no longer fast-forwards" \
    "a refused push must be classified from the refs, not from git's localized prose"
  assert_not_contains "$out" "network or credentials" \
    "a branch problem must never be downgraded to a network skip"
  [ "${rc:-0}" -ne 0 ] || fail "--push that did not advance the fork must exit non-zero"
  pass "fm-upstream-sync: push refusal is classified from refs, not localized prose"
}

# --push was asked to advance the fork. A remote it could not reach means it did
# not, so a scripted caller must be able to see that without parsing the output.
# A report-only run was not asked to advance anything, so the same skip is a
# successful report there.
test_push_exits_nonzero_when_a_remote_cannot_be_reached() {
  local c rc
  c=$(new_case push-fetch-fail)
  git -C "$c/clone" remote set-url upstream "$c/does-not-exist.git"

  run_sync "$c" --push >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc:-0}" -ne 0 ] \
    || fail "--push must exit non-zero when it could not reach a remote"

  run_sync "$c" >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc:-0}" -eq 0 ] \
    || fail "a report-only run that skipped on an unreachable remote should still exit 0"
  pass "fm-upstream-sync: an unreachable remote fails --push and is benign report-only"
}

# Git shell-parses GIT_SSH_COMMAND, so a quoted program path containing spaces is
# legitimate. Splitting it on whitespace would leave an unrunnable command and the
# sweep would blame the network for a failure it caused itself.
test_sweep_preserves_a_quoted_ssh_program_path() {
  local c prog out
  c=$(make_ssh_case ssh-quoted-path)
  prog="$c/My Tools/report-ssh"
  mkdir -p "$c/My Tools"
  cp "$c/report-ssh" "$prog"

  REPORT_FILE="$c/ssh-args" FM_ROOT_OVERRIDE="$c/clone" \
    GIT_SSH_COMMAND="\"$prog\" -F /dev/null" "$SYNC" --sweep >/dev/null 2>&1 || true
  out=$(cat "$c/ssh-args")
  assert_contains "$out" "SSH_ARGS:" \
    "a quoted ssh program path must still be runnable after BatchMode is prepended"
  assert_contains "$out" "-F /dev/null" \
    "the operator's own ssh options must be preserved"
  pass "fm-upstream-sync: the sweep preserves a quoted ssh program path"
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

# The prompt-free guarantee belongs to the unattended sweep, where nobody can
# answer a prompt and stderr is thrown away. A human who deliberately typed the
# command must keep ordinary interactive authentication, so the guard must not
# leak onto that path.
# A fake ssh that records the arguments git handed it, so the tests observe the
# environment git actually used rather than re-deriving what the script exported.
# Its ssh:// remote never connects, which is the point: the run fails, and what is
# under test is what it did on the way there.
make_ssh_case() {  # <name>
  local c=$1
  c=$(new_case "$c")
  cat > "$c/report-ssh" <<'EOF'
#!/usr/bin/env bash
echo "SSH_ARGS: $*" >> "$REPORT_FILE"
echo "ssh: could not authenticate" >&2
exit 255
EOF
  chmod +x "$c/report-ssh"
  git -C "$c/clone" remote set-url upstream "ssh://host.invalid/upstream.git"
  : > "$c/ssh-args"
  printf '%s\n' "$c"
}

# ssh takes the FIRST value it obtains for a parameter, so an option appended
# after an operator's own -o BatchMode=no would be silently ignored and the
# unattended run could still hang on a passphrase prompt.
test_sweep_prepends_batchmode_ahead_of_operator_options() {
  local c out
  c=$(make_ssh_case batchmode-order)

  REPORT_FILE="$c/ssh-args" FM_ROOT_OVERRIDE="$c/clone" \
    GIT_SSH_COMMAND="$c/report-ssh -o BatchMode=no" "$SYNC" --sweep >/dev/null 2>&1 || true
  out=$(cat "$c/ssh-args")
  assert_contains "$out" "-o BatchMode=yes" \
    "the unattended sweep should force BatchMode on"
  case "$out" in
    *"BatchMode=yes"*"BatchMode=no"*) ;;
    *) fail "BatchMode=yes must come BEFORE the operator's own option, since ssh takes the first value it obtains (got: $out)" ;;
  esac
  pass "fm-upstream-sync: the sweep prepends BatchMode ahead of operator options"
}

# The prompt-free guarantee belongs to the unattended sweep, where nobody can
# answer a prompt and the caller discards stderr. A human who deliberately typed
# the command keeps ordinary interactive authentication and gets git's own
# diagnostic, which is the only place the real cause is spelled out.
test_manual_run_stays_interactive_and_shows_git_errors() {
  local c out
  c=$(make_ssh_case manual-interactive)

  out=$(REPORT_FILE="$c/ssh-args" FM_ROOT_OVERRIDE="$c/clone" \
        GIT_SSH_COMMAND="$c/report-ssh" "$SYNC" 2>&1)
  assert_contains "$out" "could not authenticate" \
    "a manual run should surface git's own diagnostic instead of swallowing it"
  assert_not_contains "$(cat "$c/ssh-args")" "BatchMode" \
    "a manual run must not force BatchMode onto the operator's own ssh command"

  out=$(REPORT_FILE="$c/ssh-args" FM_ROOT_OVERRIDE="$c/clone" \
        GIT_SSH_COMMAND="$c/report-ssh" "$SYNC" --sweep 2>&1)
  assert_not_contains "$out" "could not authenticate" \
    "an unattended run should keep git's own stderr out of its report"
  pass "fm-upstream-sync: non-interactive git is scoped to the unattended sweep"
}

# An unreachable or unauthenticated remote is not a branch problem, so calling it
# STUCK would send the operator to read history over what is actually a key.
test_unreachable_remote_is_a_skip_not_stuck() {
  local c out
  c=$(new_case unreachable)
  git -C "$c/clone" remote set-url upstream "$c/does-not-exist.git"
  out=$(run_sync "$c" --sweep)
  assert_contains "$out" "cannot reach upstream (network or credentials)" \
    "an unreachable remote should name the real cause"
  assert_not_contains "$out" "STUCK" \
    "an unreachable remote is not a divergence and must not be reported as STUCK"
  pass "fm-upstream-sync: an unreachable remote reports as a skip, not STUCK"
}

# --sweep exists to guarantee no prompt can hang an unattended run; --push is a
# human action that may legitimately need to authenticate interactively.
test_sweep_and_push_are_mutually_exclusive() {
  local c out rc
  c=$(new_case sweep-push)
  out=$(run_sync "$c" --push --sweep) && rc=0 || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "--push --sweep should be rejected"
  assert_contains "$out" "cannot be combined" \
    "the rejection should say why the combination is refused"
  pass "fm-upstream-sync: --sweep and --push are mutually exclusive"
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

# A timeout is the one skip worth saying out loud: unlike the free skips, it
# spends its whole budget at every single session start until the remote is
# reachable again, and an unexplained recurring startup delay is exactly what
# nobody manages to diagnose later.
test_bootstrap_relays_drift_check_timeout() {
  local c out stub
  c=$(new_case bootstrap-timeout)
  stub="$c/stubbin"
  mkdir -p "$stub"
  # Copy bootstrap's whole bin next to a drift check that never returns, so the
  # SCRIPT_DIR-resolved sweep is the slow one while everything else is genuine.
  cp "$ROOT"/bin/*.sh "$stub/"
  cat > "$stub/fm-upstream-sync.sh" <<'EOF'
#!/usr/bin/env bash
sleep 120
EOF
  chmod +x "$stub/fm-upstream-sync.sh"

  out=$(FM_ROOT_OVERRIDE="$c/clone" FM_HOME="$c/clone" \
        FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=1 "$stub/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "UPSTREAM_SYNC: firstmate: skipped: drift check timed out" \
    "a timed-out drift check should be relayed rather than silently costing time"
  pass "fm-bootstrap: relays a drift-check timeout as its own line"
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
test_report_only_stuck_still_exits_zero
test_push_fast_forwards_the_fork
test_push_reports_when_local_branch_could_not_follow
test_push_rejection_is_classified_without_reading_git_prose
test_push_exits_nonzero_when_a_remote_cannot_be_reached
test_sweep_preserves_a_quoted_ssh_program_path
test_push_is_idempotent
test_sweep_prepends_batchmode_ahead_of_operator_options
test_manual_run_stays_interactive_and_shows_git_errors
test_unreachable_remote_is_a_skip_not_stuck
test_sweep_and_push_are_mutually_exclusive
test_unknown_argument_is_rejected
test_bootstrap_relays_behind_and_stuck_only
test_bootstrap_relays_drift_check_timeout
