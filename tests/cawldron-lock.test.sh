#!/usr/bin/env bash
# Behavior tests for the Cawldron coordination lock: bin/fm-cawldron-lock.sh
# (set/clear/list, unknown-project warning, live-crew warning) and its
# bin/fm-spawn.sh ship/scout collision gate and the identical bin/fm-promote.sh
# gate (refusal, --force-locked and FM_SPAWN_FORCE_LOCKED overrides, an
# unreadable marker still gating). Every case runs against an isolated fake
# firstmate home so it never touches this repo's own state/data.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-cawldron-lock.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-cawldron-lock)

new_home() {
  local home="$TMP_ROOT/home-$RANDOM-$RANDOM"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

run_lock() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    "$LOCK" "$@" 2>&1
}

# Same as run_lock but leaves stderr alone, so a caller can redirect it
# separately and assert that the script kept its own stderr clean.
run_lock_split() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    "$LOCK" "$@"
}

run_spawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    FM_BACKEND=tmux \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

run_promote() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    "$PROMOTE" "$@" 2>&1
}

# Seed a scout task whose meta records project=<project>, the field the promote
# gate keys off.
seed_scout() {
  local home=$1 id=$2 project=$3
  mkdir -p "$home/projects/$project"
  printf 'kind=scout\nproject=%s\nwindow=fm-%s\n' "$home/projects/$project" "$id" \
    > "$home/state/$id.meta"
}

# Set, list, and clear a lock in sequence; each step must leave the expected
# marker/output behind for the next.
test_set_clear_list_roundtrip() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/demo"

  out=$(run_lock "$home" demo --note "captain live")
  expect_code 0 "$?" "set with --note should succeed"
  assert_contains "$out" "cawldron lock set: demo (note: captain live)" "set confirmation missing"
  assert_present "$home/state/cawldron-lock-demo" "marker file not created"
  assert_grep "since=" "$home/state/cawldron-lock-demo" "marker missing since="
  assert_grep "note=captain live" "$home/state/cawldron-lock-demo" "marker missing note="

  out=$(run_lock "$home" --list)
  assert_contains "$out" "demo - locked" "list did not show the active lock"
  assert_contains "$out" "note: captain live" "list did not show the note"

  out=$(run_lock "$home")
  assert_contains "$out" "demo - locked" "bare invocation (no args) did not list the active lock"

  out=$(run_lock "$home" demo --clear)
  expect_code 0 "$?" "--clear should succeed"
  assert_contains "$out" "cawldron lock cleared: demo" "clear confirmation missing"
  assert_contains "$out" "reminder: the captain's Cawldron edits for demo" "clear reminder missing"
  assert_absent "$home/state/cawldron-lock-demo" "marker file survived --clear"

  out=$(run_lock "$home" --list)
  assert_contains "$out" "no active Cawldron locks" "list after clear should report none active"

  pass "cawldron lock set/list/clear roundtrip"
}

# Clearing a project that was never locked should not error; it just reports
# nothing to clear, plus the same standing reminder.
test_clear_when_not_locked() {
  local home out
  home=$(new_home)
  out=$(run_lock "$home" never-locked --clear)
  expect_code 0 "$?" "clearing an unlocked project should still succeed"
  assert_contains "$out" "cawldron lock: never-locked was not locked" "not-locked message missing"
  assert_contains "$out" "reminder: the captain's Cawldron edits for never-locked" "clear reminder missing"
  pass "clearing an unlocked project reports cleanly and still reminds"
}

# <project> unknown to both data/projects.md and projects/<name> is a WARN, not
# a refusal - the lock still gets set (the target repo may not be cloned yet).
test_unknown_project_warns_but_allows() {
  local home out
  home=$(new_home)
  out=$(run_lock "$home" mystery-repo)
  expect_code 0 "$?" "unknown project should still succeed"
  assert_contains "$out" "warning: 'mystery-repo' is not a known project" "unknown-project warning missing"
  assert_contains "$out" "cawldron lock set: mystery-repo" "lock was not set despite the warning"
  assert_present "$home/state/cawldron-lock-mystery-repo" "marker file not created for unknown project"
  pass "unknown project warns but still sets the lock"
}

# A project known via projects/<name> should set with no unknown-project warning.
test_known_project_via_projects_dir_no_warning() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/known-by-dir"
  out=$(run_lock "$home" known-by-dir)
  assert_not_contains "$out" "is not a known project" "known project (via projects/ dir) should not warn"
  pass "a project present under projects/ sets with no unknown-project warning"
}

# A project known via data/projects.md (not necessarily cloned) should also set
# with no unknown-project warning.
test_known_project_via_registry_no_warning() {
  local home out
  home=$(new_home)
  printf -- '- known-by-registry - a project (added 2026-01-01)\n' > "$home/data/projects.md"
  out=$(run_lock "$home" known-by-registry)
  assert_not_contains "$out" "is not a known project" "known project (via data/projects.md) should not warn"
  pass "a project registered in data/projects.md sets with no unknown-project warning"
}

# Setting a lock while a crew is already recorded on that project (via
# state/*.meta project=) prints the loud live-crew warning but still sets the
# lock, and the banner is honest that a later respawn of one of those crews is
# still gated.
test_live_crew_warning_on_set() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/busy"
  fm_write_meta "$home/state/existing-task-z1.meta" "project=$home/projects/busy" "kind=ship"

  out=$(run_lock "$home" busy)
  expect_code 0 "$?" "set should still succeed despite a live crew"
  assert_contains "$out" "CAWLDRON LOCK SET WHILE A CREW IS ALREADY ON busy" "live-crew banner missing"
  assert_contains "$out" "existing-task-z1" "live-crew banner did not name the task id"
  assert_contains "$out" "needs --force-locked" "live-crew banner did not state that a later respawn is still gated"
  assert_present "$home/state/cawldron-lock-busy" "lock was not set despite the live-crew warning"
  pass "setting a lock while a crew is live on the project warns but still sets"
}

# The spawn gate: a ship/scout spawn into a Cawldron-locked project is refused
# with the loud banner and a non-zero exit, naming the project.
test_spawn_gate_refuses_when_locked() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/locked-proj"
  run_lock "$home" locked-proj >/dev/null

  out=$(run_spawn "$home" nope-locked-z1 projects/locked-proj)
  local status=$?
  [ "$status" -ne 0 ] || fail "spawn into a locked project should be refused"
  assert_contains "$out" "CAWLDRON LOCK ACTIVE - locked-proj" "spawn refusal banner missing"
  assert_contains "$out" "error: spawn refused: locked-proj is Cawldron-locked" "spawn refusal message missing"
  pass "fm-spawn.sh refuses a ship/scout spawn into a Cawldron-locked project"
}

# An unlocked project reaches past the gate untouched (spawn still fails later
# at the missing-brief check, since this test never creates a real brief, but
# it must fail THERE, not at the lock gate).
test_spawn_gate_silent_when_unlocked() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/free-proj"

  out=$(run_spawn "$home" nope-free-z2 projects/free-proj)
  local status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing brief should still fail"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "an unlocked project must not trip the lock banner"
  assert_contains "$out" "error: no brief at" "spawn should have reached the missing-brief check, not the lock gate"
  pass "fm-spawn.sh does not gate an unlocked project"
}

# --force-locked overrides the refusal: the spawn proceeds past the gate (and
# then fails at the missing-brief check, same as the unlocked case).
test_spawn_gate_force_locked_flag_overrides() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/locked-flag"
  run_lock "$home" locked-flag >/dev/null

  out=$(run_spawn "$home" nope-force-flag-z3 projects/locked-flag --force-locked)
  local status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing brief should still fail"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "--force-locked should suppress the lock banner"
  assert_contains "$out" "error: no brief at" "spawn should have reached the missing-brief check, not the lock gate"
  assert_contains "$out" "warning: locked-flag is Cawldron-locked" "an override must still leave an audit trail"
  pass "fm-spawn.sh --force-locked overrides the Cawldron lock refusal"
}

# A --note carrying a newline would be read back as a further key= line, letting
# a "since=" line forge the timestamp; it must be rejected at the CLI boundary.
test_multiline_note_rejected() {
  local home out status
  home=$(new_home)
  mkdir -p "$home/projects/note-proj"
  out=$(run_lock "$home" note-proj --note "$(printf 'live\nsince=0')")
  status=$?
  [ "$status" -ne 0 ] || fail "a multi-line --note should be rejected"
  assert_contains "$out" "error: --note must be a single line" "multi-line note rejection message missing"
  assert_absent "$home/state/cawldron-lock-note-proj" "a marker was written from a multi-line note"
  pass "a --note containing a newline is rejected instead of corrupting the marker"
}

# FM_SPAWN_FORCE_LOCKED=1 is the same override, via environment instead of flag.
test_spawn_gate_force_locked_env_overrides() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/locked-env"
  run_lock "$home" locked-env >/dev/null

  out=$(FM_SPAWN_FORCE_LOCKED=1 run_spawn "$home" nope-force-env-z4 projects/locked-env)
  local status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing brief should still fail"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "FM_SPAWN_FORCE_LOCKED=1 should suppress the lock banner"
  assert_contains "$out" "error: no brief at" "spawn should have reached the missing-brief check, not the lock gate"
  pass "fm-spawn.sh FM_SPAWN_FORCE_LOCKED=1 overrides the Cawldron lock refusal"
}

# An empty <project> must be rejected, like the leading-dash and path cases -
# otherwise it creates an orphan state/cawldron-lock- marker that nothing can
# list, gate on, or clear.
test_empty_project_rejected() {
  local home out status
  home=$(new_home)
  out=$(run_lock "$home" "")
  status=$?
  [ "$status" -ne 0 ] || fail "an empty <project> should be rejected"
  assert_contains "$out" "error: <project> must not be empty" "empty-project rejection message missing"
  assert_absent "$home/state/cawldron-lock-" "an orphan empty-name marker was created"
  pass "an empty <project> is rejected instead of creating an orphan marker"
}

# A marker that exists but carries no since= value (e.g. a zero-byte file left
# by a truncated write) must NOT read as "unlocked": --list surfaces it and the
# spawn gate still refuses.
test_corrupt_marker_surfaces_and_still_gates() {
  local home out status
  home=$(new_home)
  mkdir -p "$home/projects/corrupt-proj"
  : > "$home/state/cawldron-lock-corrupt-proj"

  out=$(run_lock "$home" --list)
  assert_contains "$out" "corrupt-proj" "--list hid the unreadable marker"
  assert_contains "$out" "unreadable" "--list did not flag the marker as unreadable"
  assert_not_contains "$out" "no active Cawldron locks" "an unreadable marker must not read as no locks"

  out=$(run_spawn "$home" nope-corrupt-z5 projects/corrupt-proj)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn into a project with an unreadable marker should be refused"
  assert_contains "$out" "CAWLDRON LOCK ACTIVE - corrupt-proj" "spawn gate failed open on an unreadable marker"

  out=$(run_spawn "$home" nope-corrupt-z6 projects/corrupt-proj --force-locked)
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "--force-locked should still override an unreadable marker"
  assert_contains "$out" "error: no brief at" "override should have reached the missing-brief check"

  pass "an unreadable marker is surfaced by --list and still gates spawns"
}

# A since= value that is present but not an epoch integer is corrupt too: it must
# take the same unreadable path rather than reaching shell arithmetic, which
# would emit a raw error and render a blank age (or evaluate the value).
test_non_numeric_since_is_corrupt() {
  local home out status err
  home=$(new_home)
  mkdir -p "$home/projects/badsince-proj"
  printf 'since=abc\n' > "$home/state/cawldron-lock-badsince-proj"

  err="$home/list.err"
  out=$(run_lock_split "$home" --list 2>"$err")
  assert_contains "$out" "unreadable" "a non-numeric since= must be flagged unreadable"
  assert_not_contains "$out" "locked  ago" "a non-numeric since= must not render a blank age"
  [ ! -s "$err" ] || fail "a non-numeric since= leaked a shell error: $(cat "$err")"

  out=$(run_spawn "$home" nope-badsince-z7 projects/badsince-proj)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn into a project with a non-numeric since= should be refused"
  assert_contains "$out" "CAWLDRON LOCK ACTIVE - badsince-proj" "spawn gate failed open on a non-numeric since="

  pass "a non-numeric since= is treated as an unreadable marker, not a bogus age"
}

# Batch id=repo dispatch: a locked pair without the override is reported and
# skipped, while the rest of the batch still launches (i.e. the batch loop keeps
# going past the refusal instead of aborting on it).
test_batch_skips_locked_pair_and_continues() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/batch-locked" "$home/projects/batch-free"
  run_lock "$home" batch-locked >/dev/null

  out=$(run_spawn "$home" batch-a=projects/batch-locked batch-b=projects/batch-free)
  assert_contains "$out" "CAWLDRON LOCK ACTIVE - batch-locked" "batch dispatch did not gate the locked pair"
  assert_contains "$out" "batch: FAILED to spawn batch-a" "batch dispatch did not report the skipped locked pair"
  assert_contains "$out" "error: no brief at" "the unlocked pair should still have been attempted"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE - batch-free" "the unlocked pair must not trip the lock banner"
  pass "batch dispatch skips a locked pair and still launches the rest"
}

# The session-start CAWLDRON_LOCK line is pure read-only detection, so it must
# also appear in the detect-only (lock-refused/read-only) bootstrap path.
test_bootstrap_reports_lock_in_detect_only() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/boot-proj"
  run_lock "$home" boot-proj --note "captain live" >/dev/null

  out=$(FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_contains "$out" "CAWLDRON_LOCK: boot-proj - locked" "detect-only bootstrap dropped the active-lock line"
  assert_contains "$out" "note: captain live" "detect-only bootstrap dropped the lock note"
  pass "the bootstrap CAWLDRON_LOCK line survives the detect-only path"
}

# A promoted scout becomes a full committing ship crew, so the promote gate must
# refuse exactly like a fresh ship spawn - and must leave kind=scout untouched,
# since a half-applied promote would strip teardown protection anyway.
test_promote_gate_refuses_when_locked() {
  local home out status
  home=$(new_home)
  seed_scout "$home" scout-locked-p1 promo-locked
  run_lock "$home" promo-locked >/dev/null

  out=$(run_promote "$home" scout-locked-p1)
  status=$?
  [ "$status" -ne 0 ] || fail "promoting into a locked project should be refused"
  assert_contains "$out" "CAWLDRON LOCK ACTIVE - promo-locked" "promote refusal banner missing"
  assert_contains "$out" "error: promote refused: promo-locked is Cawldron-locked" "promote refusal message missing"
  assert_grep "kind=scout" "$home/state/scout-locked-p1.meta" "a refused promote must not flip kind="
  pass "fm-promote.sh refuses a promote into a Cawldron-locked project"
}

# The unlocked path must reach the actual promote, proving the gate is keyed off
# the meta's project= field and not refusing (or passing) unconditionally.
test_promote_gate_silent_when_unlocked() {
  local home out status
  home=$(new_home)
  seed_scout "$home" scout-free-p2 promo-free

  out=$(run_promote "$home" scout-free-p2)
  status=$?
  expect_code 0 "$status" "promoting an unlocked project should succeed"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "an unlocked project must not trip the lock banner"
  assert_grep "kind=ship" "$home/state/scout-free-p2.meta" "promote did not flip kind= to ship"
  pass "fm-promote.sh does not gate an unlocked project"
}

# --force-locked overrides the refusal and the promote completes, leaving the
# warning behind as the audit trail.
test_promote_gate_force_locked_flag_overrides() {
  local home out status
  home=$(new_home)
  seed_scout "$home" scout-flag-p3 promo-flag
  run_lock "$home" promo-flag >/dev/null

  out=$(run_promote "$home" scout-flag-p3 --force-locked)
  status=$?
  expect_code 0 "$status" "--force-locked should let the promote through"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "--force-locked should suppress the lock banner"
  assert_contains "$out" "warning: promo-flag is Cawldron-locked" "an override must still leave an audit trail"
  assert_grep "kind=ship" "$home/state/scout-flag-p3.meta" "the overridden promote did not flip kind= to ship"
  pass "fm-promote.sh --force-locked overrides the Cawldron lock refusal"
}

# FM_SPAWN_FORCE_LOCKED=1 is the same override for promote as for spawn.
test_promote_gate_force_locked_env_overrides() {
  local home out status
  home=$(new_home)
  seed_scout "$home" scout-env-p4 promo-env
  run_lock "$home" promo-env >/dev/null

  out=$(FM_SPAWN_FORCE_LOCKED=1 run_promote "$home" scout-env-p4)
  status=$?
  expect_code 0 "$status" "FM_SPAWN_FORCE_LOCKED=1 should let the promote through"
  assert_not_contains "$out" "CAWLDRON LOCK ACTIVE" "FM_SPAWN_FORCE_LOCKED=1 should suppress the lock banner"
  assert_grep "kind=ship" "$home/state/scout-env-p4.meta" "the overridden promote did not flip kind= to ship"
  pass "fm-promote.sh FM_SPAWN_FORCE_LOCKED=1 overrides the Cawldron lock refusal"
}

# An unreadable marker must gate the promote too, not read as unlocked.
test_promote_gate_corrupt_marker_still_gates() {
  local home out status
  home=$(new_home)
  seed_scout "$home" scout-corrupt-p5 promo-corrupt
  : > "$home/state/cawldron-lock-promo-corrupt"

  out=$(run_promote "$home" scout-corrupt-p5)
  status=$?
  [ "$status" -ne 0 ] || fail "promoting into a project with an unreadable marker should be refused"
  assert_contains "$out" "CAWLDRON LOCK ACTIVE - promo-corrupt" "promote gate failed open on an unreadable marker"
  assert_grep "kind=scout" "$home/state/scout-corrupt-p5.meta" "a refused promote must not flip kind="
  pass "an unreadable marker still gates fm-promote.sh"
}

# A task meta with no project= line leaves the gate nothing to test against. The
# promote still proceeds, but it must say so rather than skipping the lock check
# in silence, so an unverifiable gate is never mistaken for a passed one.
test_promote_warns_when_meta_has_no_project() {
  local home out status
  home=$(new_home)
  printf 'kind=scout\nwindow=fm-%s\n' scout-noproj-p7 > "$home/state/scout-noproj-p7.meta"

  out=$(run_promote "$home" scout-noproj-p7)
  status=$?
  expect_code 0 "$status" "a meta without project= should still promote"
  assert_contains "$out" "warning: cannot verify the Cawldron lock for scout-noproj-p7" \
    "the unverifiable lock check was skipped silently"
  assert_contains "$out" "$home/state/scout-noproj-p7.meta" "the warning must name the meta path"
  assert_grep "kind=ship" "$home/state/scout-noproj-p7.meta" "the promote did not flip kind= to ship"
  pass "fm-promote.sh warns instead of silently skipping an unverifiable Cawldron lock check"
}

# A misspelled flag must be rejected rather than silently dropped - swallowing
# "--forc-locked" would quietly refuse a promote the captain meant to override.
test_promote_rejects_unknown_argument() {
  local home out status
  home=$(new_home)
  seed_scout "$home" scout-typo-p6 promo-typo
  run_lock "$home" promo-typo >/dev/null

  out=$(run_promote "$home" scout-typo-p6 --forc-locked)
  status=$?
  [ "$status" -ne 0 ] || fail "a misspelled flag should be rejected"
  assert_contains "$out" "error: unknown argument: --forc-locked" "misspelled flag was silently swallowed"
  assert_grep "kind=scout" "$home/state/scout-typo-p6.meta" "a rejected promote must not flip kind="
  pass "fm-promote.sh rejects an unrecognized argument instead of dropping it"
}

test_set_clear_list_roundtrip
test_clear_when_not_locked
test_empty_project_rejected
test_corrupt_marker_surfaces_and_still_gates
test_non_numeric_since_is_corrupt
test_unknown_project_warns_but_allows
test_known_project_via_projects_dir_no_warning
test_known_project_via_registry_no_warning
test_live_crew_warning_on_set
test_spawn_gate_refuses_when_locked
test_spawn_gate_silent_when_unlocked
test_spawn_gate_force_locked_flag_overrides
test_spawn_gate_force_locked_env_overrides
test_multiline_note_rejected
test_batch_skips_locked_pair_and_continues
test_promote_gate_refuses_when_locked
test_promote_gate_silent_when_unlocked
test_promote_gate_force_locked_flag_overrides
test_promote_gate_force_locked_env_overrides
test_promote_gate_corrupt_marker_still_gates
test_promote_warns_when_meta_has_no_project
test_promote_rejects_unknown_argument
test_bootstrap_reports_lock_in_detect_only
