#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-reap.sh, the idle-pool-slot reaper.
#
# Why this exists: fm-teardown.sh RETURNS a worktree to the treehouse pool
# rather than removing it, so a pool grows to the high-water mark of concurrent
# crews and never shrinks. One 8-slot mobile pool was observed holding 22.6 GiB
# across 4 slots idle since a one-off burst.
#
# The load-bearing safety properties asserted here:
#   1. A floor of idle slots is ALWAYS kept pre-warmed. `treehouse prune` has no
#      floor and would empty the pool (verified against v2.0.0: a prune dry run
#      on a 1-slot pool offered to reclaim the only slot), which is why the reaper
#      drives per-slot `treehouse destroy` under its own floor instead.
#   2. No --include-* flag is EVER passed. Bare `treehouse destroy` skips
#      anything not genuinely disposable; --include-unlanded/--include-in-use
#      would cause unrecoverable data loss and no captain approval exists for it.
#   3. Dirty and in-use slots are never targeted, and dirty slots are SURFACED
#      so un-rescued work cannot sit invisible forever.
#   4. Housekeeping never fails its caller: every path exits 0.
#
# The real treehouse CLI is never invoked. FM_TREEHOUSE_STATUS_CMD and
# FM_TREEHOUSE_DESTROY_CMD inject stubs, so no worktree is ever destroyed by
# this suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAP="$ROOT/bin/fm-worktree-reap.sh"
TMP=$(fm_test_tmproot fm-reap)
FM_TEST_HOME="$TMP/home"
mkdir -p "$FM_TEST_HOME/config" "$FM_TEST_HOME/projects/demo"

DESTROY_LOG="$TMP/destroy.log"

# A stub `treehouse status` printing the pool shape given as "<n>:<state>" args,
# including the upgrade banner and an in-use continuation line that the parser
# must skip. Mirrors real v2.0.0 output captured on 2026-08-03.
write_status_stub() {
  local file=$1 spec n state
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "A new version of treehouse is available: v2.0.0 → v2.1.1\\n"\n'
    printf 'printf "Run \\"treehouse update\\" to update\\n\\n"\n'
    for spec in "$@"; do
      n=${spec%%:*}
      state=${spec#*:}
      printf 'printf "%s     %s        ~/.treehouse/demo/%s/demo\\n"\n' "$n" "$state" "$n"
      if [ "$state" = "in-use" ]; then
        printf 'printf "                   zsh (111), node (222)\\n"\n'
      fi
    done
  } > "$file"
  chmod +x "$file"
}

# A stub `treehouse destroy` that records its exact argv and reports the given
# exit code, so the suite can assert what the reaper would really have run.
write_destroy_stub() {
  local file=$1 rc=$2
  cat > "$file" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DESTROY_LOG"
exit $rc
EOF
  chmod +x "$file"
}

STATUS_STUB="$TMP/status.sh"
DESTROY_OK="$TMP/destroy-ok.sh"
DESTROY_REFUSE="$TMP/destroy-refuse.sh"
write_destroy_stub "$DESTROY_OK" 0
write_destroy_stub "$DESTROY_REFUSE" 1

set_floor() {
  if [ -z "${1:-}" ]; then
    rm -f "$FM_TEST_HOME/config/worktree-reap"
  else
    printf '%s\n' "$1" > "$FM_TEST_HOME/config/worktree-reap"
  fi
}

# run_reap [extra-args...]: run the reaper against the stub pool, capturing
# combined output on stdout. Because callers use $(run_reap), the exit code
# cannot be returned through a shell variable (the subshell would discard it),
# so it is recorded in $RC_FILE and read back by reap_rc.
RC_FILE="$TMP/reap.rc"

run_reap() {
  local rc=0
  : > "$DESTROY_LOG"
  FM_HOME="$FM_TEST_HOME" \
    FM_TREEHOUSE_STATUS_CMD="$STATUS_STUB" \
    FM_TREEHOUSE_DESTROY_CMD="${REAP_DESTROY_STUB:-$DESTROY_OK}" \
    "$REAP" demo "$@" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$RC_FILE"
}

# reap_rc: the exit code of the most recent run_reap.
reap_rc() {
  cat "$RC_FILE" 2>/dev/null || printf 'missing\n'
}

# --- the floor ---------------------------------------------------------------

test_default_floor_keeps_two_slots() {
  set_floor ""
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available 4:available 5:available
  local out
  out=$(run_reap)
  expect_code 0 "$(reap_rc)" "default-floor reap"
  # 5 idle, floor 2 -> exactly 3 reaped.
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 3 ] \
    || fail "default floor must reap 5-2=3 slots, got: $(cat "$DESTROY_LOG")"
  # The floor slots that must survive are the low-numbered, steady-state ones.
  assert_no_grep '/demo/1/demo' "$DESTROY_LOG" "slot 1 is within the floor and must never be reaped"
  assert_no_grep '/demo/2/demo' "$DESTROY_LOG" "slot 2 is within the floor and must never be reaped"
  assert_contains "$out" "kept 2 idle slot(s) pre-warmed" "reaper must report the retained floor"
  pass "default floor keeps 2 idle slots pre-warmed and reaps only the excess"
}

test_never_reaps_below_the_floor() {
  set_floor ""
  # Exactly at the floor, and below it: both must reap nothing at all. This is
  # the property `treehouse prune` lacks - it would take these to zero.
  write_status_stub "$STATUS_STUB" 1:available 2:available
  run_reap >/dev/null
  [ ! -s "$DESTROY_LOG" ] || fail "a pool at the floor must not be reaped: $(cat "$DESTROY_LOG")"
  write_status_stub "$STATUS_STUB" 1:available
  run_reap >/dev/null
  [ ! -s "$DESTROY_LOG" ] || fail "a pool below the floor must not be reaped: $(cat "$DESTROY_LOG")"
  pass "a pool at or below the floor is never reaped (the pool is never emptied)"
}

test_configured_floor_is_honored() {
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available 4:available 5:available
  set_floor 4
  run_reap >/dev/null
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 1 ] \
    || fail "floor 4 over 5 idle must reap 1, got: $(cat "$DESTROY_LOG")"
  set_floor 0
  run_reap >/dev/null
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 5 ] \
    || fail "floor 0 must reap every idle slot, got: $(cat "$DESTROY_LOG")"
  pass "a configured floor sets the retained-slot arithmetic"
}

test_invalid_floor_falls_back_to_default() {
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available 4:available 5:available
  set_floor "banana"
  local out
  out=$(run_reap)
  expect_code 0 "$(reap_rc)" "invalid-floor reap"
  assert_contains "$out" "invalid config/worktree-reap value" "an unusable value must be reported"
  # Must fall back to the default floor, never to 0 (which would empty the pool).
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 3 ] \
    || fail "an invalid floor must fall back to the default 2, got: $(cat "$DESTROY_LOG")"
  pass "an invalid floor falls back to the default rather than emptying the pool"
}

test_comments_and_blanks_are_skipped() {
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available 4:available 5:available
  printf '# keep more slots warm\n\n4\n' > "$FM_TEST_HOME/config/worktree-reap"
  run_reap >/dev/null
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 1 ] \
    || fail "the first non-comment, non-blank line must set the floor, got: $(cat "$DESTROY_LOG")"
  pass "config comments and blank lines are skipped, matching sibling knobs"
}

# --- the opt-out -------------------------------------------------------------

test_off_disables_reaping() {
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available 4:available 5:available
  local out spelling
  for spelling in off OFF Off; do
    set_floor "$spelling"
    out=$(run_reap)
    expect_code 0 "$(reap_rc)" "opt-out reap ($spelling)"
    [ ! -s "$DESTROY_LOG" ] || fail "'$spelling' must reap nothing, got: $(cat "$DESTROY_LOG")"
    [ -z "$out" ] || fail "'$spelling' must be silent, got: $out"
  done
  pass "config/worktree-reap=off disables reaping entirely and silently"
}

test_absent_config_means_default_not_off() {
  set_floor ""
  assert_absent "$FM_TEST_HOME/config/worktree-reap" "fixture must have no config file"
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available
  run_reap >/dev/null
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 1 ] \
    || fail "an absent config must mean the default floor, not disabled"
  pass "an absent config means the default posture, not off"
}

# --- what is never touched ---------------------------------------------------

test_never_passes_an_include_flag() {
  set_floor 0
  # Every slot eligible, so every destroy the reaper can emit is recorded.
  write_status_stub "$STATUS_STUB" 1:available 2:available 3:available
  run_reap >/dev/null
  [ -s "$DESTROY_LOG" ] || fail "fixture should have produced destroy calls"
  assert_no_grep 'include-' "$DESTROY_LOG" "the reaper must NEVER pass any --include-* flag (data loss)"
  # Positively pin the exact argv shape: --yes plus one path, nothing else.
  local line
  while IFS= read -r line; do
    case "$line" in
      "--yes /"*) : ;;
      *) fail "unexpected destroy argv '$line'; expected exactly '--yes <path>'" ;;
    esac
    [ "$(printf '%s\n' "$line" | wc -w | tr -d ' ')" -eq 2 ] \
      || fail "destroy argv must be exactly two words, got '$line'"
  done < "$DESTROY_LOG"
  # And the script must never actually invoke those flags. They are named in the
  # header comment as an explicit prohibition, so match the invocation shape
  # (a destroy call carrying the flag) rather than any mention of the word.
  ! grep -E '^[^#]*treehouse destroy.*--include-' "$REAP" >/dev/null \
    || fail "fm-worktree-reap.sh must never invoke treehouse destroy with an --include-* flag"
  pass "destroy is invoked as exactly '--yes <path>'; no --include-* flag can be emitted"
}

test_dirty_and_in_use_slots_are_never_targeted() {
  set_floor 0
  write_status_stub "$STATUS_STUB" 1:dirty 2:in-use 3:available 4:dirty 5:in-use
  run_reap >/dev/null
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 1 ] \
    || fail "only the single available slot may be reaped, got: $(cat "$DESTROY_LOG")"
  assert_grep '/demo/3/demo' "$DESTROY_LOG" "the available slot should be the reap target"
  local n
  for n in 1 2 4 5; do
    assert_no_grep "/demo/$n/demo" "$DESTROY_LOG" "slot $n is dirty or in-use and must never be targeted"
  done
  pass "dirty and in-use slots are never reap targets"
}

test_dirty_slots_are_surfaced_with_paths() {
  set_floor ""
  write_status_stub "$STATUS_STUB" 1:dirty 2:available 3:dirty
  local out
  out=$(run_reap)
  # The blind spot this closes: a slot treehouse refuses to remove otherwise
  # sits forever, invisible, holding disk and possibly un-rescued work.
  assert_contains "$out" "2 slot(s) hold uncommitted changes" "dirty slots must be counted"
  assert_contains "$out" "/.treehouse/demo/1/demo" "dirty slot paths must be reported so the captain can act"
  assert_contains "$out" "/.treehouse/demo/3/demo" "every dirty slot path must be reported"
  # Reported, never acted on.
  assert_no_grep '/demo/1/demo' "$DESTROY_LOG" "a surfaced dirty slot must not also be destroyed"
  pass "dirty slots are surfaced with their paths and left untouched"
}

test_dirty_slots_surface_even_when_nothing_is_reaped() {
  set_floor ""
  # One idle slot: below the floor, so no reaping happens at all. The dirty
  # report must not be gated behind a reap.
  write_status_stub "$STATUS_STUB" 1:dirty 2:available
  local out
  out=$(run_reap)
  [ ! -s "$DESTROY_LOG" ] || fail "nothing should be reaped below the floor"
  assert_contains "$out" "/.treehouse/demo/1/demo" "a dirty slot must surface even when no reaping occurs"
  pass "dirty slots surface even when the pool is below the floor"
}

test_in_use_continuation_lines_are_not_parsed_as_slots() {
  set_floor 0
  write_status_stub "$STATUS_STUB" 1:in-use 2:available
  local out
  out=$(run_reap)
  # The process list under an in-use slot must not be mistaken for a slot, and
  # must not be reported as a dirty blind spot either.
  assert_not_contains "$out" "zsh" "process continuation lines must never be parsed as slots"
  [ "$(grep -c '^--yes ' "$DESTROY_LOG")" -eq 1 ] \
    || fail "only the available slot may be reaped, got: $(cat "$DESTROY_LOG")"
  pass "in-use process continuation lines are not parsed as pool slots"
}

test_dry_run_destroys_nothing() {
  set_floor 0
  write_status_stub "$STATUS_STUB" 1:available 2:available
  local out
  out=$(run_reap --dry-run)
  expect_code 0 "$(reap_rc)" "dry run"
  [ ! -s "$DESTROY_LOG" ] || fail "--dry-run must not invoke destroy at all: $(cat "$DESTROY_LOG")"
  assert_contains "$out" "would reap" "a dry run must report what it would reap"
  pass "--dry-run reports candidates and destroys nothing"
}

# --- failure posture ---------------------------------------------------------

test_status_failure_is_non_fatal() {
  set_floor ""
  cat > "$STATUS_STUB" <<'SH'
#!/usr/bin/env bash
echo "treehouse exploded" >&2
exit 3
SH
  chmod +x "$STATUS_STUB"
  local out
  out=$(run_reap)
  expect_code 0 "$(reap_rc)" "reap must exit 0 when status fails"
  assert_contains "$out" "skipped" "a status failure must be reported concisely"
  [ ! -s "$DESTROY_LOG" ] || fail "nothing may be destroyed when the pool cannot be read"
  pass "a failing treehouse status is non-fatal and reaps nothing"
}

test_unparseable_status_is_non_fatal() {
  set_floor ""
  cat > "$STATUS_STUB" <<'SH'
#!/usr/bin/env bash
echo "some future output format we cannot read"
SH
  chmod +x "$STATUS_STUB"
  local out
  out=$(run_reap)
  expect_code 0 "$(reap_rc)" "reap must exit 0 on unparseable status"
  [ ! -s "$DESTROY_LOG" ] || fail "unparseable status must never lead to a destroy"
  assert_contains "$out" "skipped" "unparseable status must be reported"
  pass "unparseable status output is non-fatal and reaps nothing"
}

test_destroy_refusal_is_non_fatal() {
  set_floor 0
  write_status_stub "$STATUS_STUB" 1:available 2:available
  local out
  REAP_DESTROY_STUB=$DESTROY_REFUSE out=$(REAP_DESTROY_STUB=$DESTROY_REFUSE run_reap)
  expect_code 0 "$(reap_rc)" "reap must exit 0 when treehouse declines"
  # A refusal is treehouse correctly protecting a slot, not an error.
  assert_contains "$out" "left" "a declined removal must be reported as left in place"
  pass "a treehouse refusal to remove a slot is non-fatal"
}

test_missing_project_and_bad_args_are_non_fatal() {
  set_floor ""
  local out rc=0
  # These paths do not go through run_reap, so clear the shared log explicitly.
  : > "$DESTROY_LOG"
  out=$(FM_HOME="$FM_TEST_HOME" "$REAP" definitely-not-a-project 2>&1) || rc=$?
  expect_code 0 "$rc" "an unresolvable project must not fail the caller"
  assert_contains "$out" "skipped" "an unresolvable project must be reported"
  rc=0
  FM_HOME="$FM_TEST_HOME" "$REAP" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a missing argument must not fail the caller"
  pass "an unresolvable project and a missing argument are both non-fatal"
}

test_missing_treehouse_binary_is_non_fatal() {
  set_floor ""
  local out rc=0 sandbox="$TMP/nothouse"
  # A PATH that still has the standard tools but NO treehouse - the realistic
  # "treehouse not installed / not on this box" case. (An entirely empty PATH is
  # not a useful model: the #!/usr/bin/env bash shebang could not resolve either,
  # so the script would never start.)
  mkdir -p "$sandbox"
  ln -sf /bin/bash "$sandbox/bash" 2>/dev/null || true
  # This path does not go through run_reap, so clear the shared log explicitly.
  : > "$DESTROY_LOG"
  out=$(FM_HOME="$FM_TEST_HOME" PATH="$sandbox:/usr/bin:/bin" "$REAP" demo 2>&1) || rc=$?
  expect_code 0 "$rc" "a missing treehouse binary must not fail the caller"
  assert_contains "$out" "treehouse not installed" "a missing treehouse must be reported concisely"
  [ ! -s "$DESTROY_LOG" ] || fail "nothing may be destroyed when treehouse is absent"
  pass "a missing treehouse binary is non-fatal and reaps nothing"
}

# --- wiring ------------------------------------------------------------------

test_teardown_invokes_the_reaper_non_fatally() {
  local td="$ROOT/bin/fm-teardown.sh"
  assert_grep 'bin/fm-worktree-reap.sh' "$td" "teardown must invoke the reaper on the release path"
  # It must be guarded so a reaper problem can never abort a teardown.
  # shellcheck disable=SC2016  # matching the literal '$PROJ' text in the source
  grep -F 'bin/fm-worktree-reap.sh" "$PROJ" || true' "$td" >/dev/null \
    || fail "teardown's reaper call must be guarded with '|| true' so it cannot fail teardown"
  pass "teardown invokes the reaper on the release path, non-fatally"
}

test_reaper_is_executable_and_lint_clean_shape() {
  [ -x "$REAP" ] || fail "bin/fm-worktree-reap.sh must be executable"
  # The script must never be able to exit non-zero: assert the explicit exit 0.
  grep -Fx 'exit 0' "$REAP" >/dev/null || fail "the reaper must end with an explicit 'exit 0'"
  pass "the reaper is executable and ends with an unconditional exit 0"
}

test_default_floor_keeps_two_slots
test_never_reaps_below_the_floor
test_configured_floor_is_honored
test_invalid_floor_falls_back_to_default
test_comments_and_blanks_are_skipped
test_off_disables_reaping
test_absent_config_means_default_not_off
test_never_passes_an_include_flag
test_dirty_and_in_use_slots_are_never_targeted
test_dirty_slots_are_surfaced_with_paths
test_dirty_slots_surface_even_when_nothing_is_reaped
test_in_use_continuation_lines_are_not_parsed_as_slots
test_dry_run_destroys_nothing
test_status_failure_is_non_fatal
test_unparseable_status_is_non_fatal
test_destroy_refusal_is_non_fatal
test_missing_project_and_bad_args_are_non_fatal
test_missing_treehouse_binary_is_non_fatal
test_teardown_invokes_the_reaper_non_fatally
test_reaper_is_executable_and_lint_clean_shape
