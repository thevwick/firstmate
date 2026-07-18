#!/usr/bin/env bash
# Behavior tests for the Cawldron coordination lock: bin/fm-cawldron-lock.sh
# (set/clear/list, unknown-project warning, live-crew warning) and its
# bin/fm-spawn.sh ship/scout collision gate (refusal, --force-locked and
# FM_SPAWN_FORCE_LOCKED overrides). Every case runs against an isolated fake
# firstmate home so it never touches this repo's own state/data.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-cawldron-lock.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
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

run_spawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    FM_BACKEND=tmux \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
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
# lock - it is informational only.
test_live_crew_warning_on_set() {
  local home out
  home=$(new_home)
  mkdir -p "$home/projects/busy"
  fm_write_meta "$home/state/existing-task-z1.meta" "project=$home/projects/busy" "kind=ship"

  out=$(run_lock "$home" busy)
  expect_code 0 "$?" "set should still succeed despite a live crew"
  assert_contains "$out" "CAWLDRON LOCK SET WHILE A CREW IS ALREADY ON busy" "live-crew banner missing"
  assert_contains "$out" "existing-task-z1" "live-crew banner did not name the task id"
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
  pass "fm-spawn.sh --force-locked overrides the Cawldron lock refusal"
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

test_set_clear_list_roundtrip
test_clear_when_not_locked
test_unknown_project_warns_but_allows
test_known_project_via_projects_dir_no_warning
test_known_project_via_registry_no_warning
test_live_crew_warning_on_set
test_spawn_gate_refuses_when_locked
test_spawn_gate_silent_when_unlocked
test_spawn_gate_force_locked_flag_overrides
test_spawn_gate_force_locked_env_overrides
