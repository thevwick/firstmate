#!/usr/bin/env bash
# Claude session identity and crash recovery, hermetically: a stub tmux pane and
# throwaway Claude config roots, no real agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
RECOVER="$ROOT/bin/fm-recover.sh"
HOOK="$ROOT/bin/fm-claude-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-session-resume)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()
session_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap session_cleanup EXIT

SID_A=11111111-2222-4333-8444-555555555555
SID_B=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee

# A pane whose foreground command is $D/command; any launch line turns it into claude.
make_tmux_stub() {  # <dir>
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in *' claude '*) printf 'claude' > "$D/command" ;; esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$1/fakebin/sleep"
  chmod +x "$1/fakebin/sleep"
}

# new_task <name> <id> [harness] -> a case dir holding a stopped claude ship task.
new_task() {
  local dir="$TMP_ROOT/$1" id=$2 harness=${3:-claude}
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fake" "$dir/user-home"
  make_tmux_stub "$dir"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  printf '# Task\n## Captain'"'"'s intent\nResume test for %s.\n\n## Firstmate spec\nNothing.\n' "$id" > "$dir/home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=opus"
    echo "effort=high"
  } > "$dir/home/state/$id.meta"
  printf 'zsh' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  : > "$dir/fake/literal"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u TERM_PROGRAM -u REX_SESSION -u REX_BLOCK \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

# A transcript under a throwaway config root, as Claude lays it out.
write_transcript() {  # <config-root> <cwd> <session-id> <text>
  local dir
  dir="$1/projects/$(printf '%s' "$2" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf '{"type":"user","message":"%s"}\n' "$4" > "$dir/$3.jsonl"
}

test_relaunch_mints_and_records_a_session_id() {
  local dir out rc sid launch
  dir=$(new_task mint cs1)
  out=$(run_spawn "$dir" cs1 --relaunch); rc=$?
  expect_code 0 "$rc" "a relaunch into an idle pane should succeed: $out"
  sid=$(meta_field "$dir/home/state/cs1.meta" claude_session_id)
  printf '%s' "$sid" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    || fail "the record should carry a minted session uuid, got '$sid'"
  launch=$(cat "$dir/fake/literal")
  assert_contains "$launch" "--session-id $sid " "the launch should start claude under the recorded id"
  assert_not_contains "$launch" "--resume" "a fresh launch must not resume anything"
  assert_grep 'fm-claude-session.sh' "$dir/wt/.claude/settings.local.json" \
    "the worker's hooks should keep the id current on SessionStart"
  pass "fm-spawn: a Claude launch passes --session-id and records the same id"
}

test_resume_session_continues_the_recorded_conversation() {
  local dir out rc launch
  dir=$(new_task resume cs2)
  printf 'claude_session_id=%s\n' "$SID_A" >> "$dir/home/state/cs2.meta"
  out=$(run_spawn "$dir" cs2 --relaunch --resume-session "$SID_A"); rc=$?
  expect_code 0 "$rc" "a resume into an idle pane should succeed: $out"
  launch=$(cat "$dir/fake/literal")
  assert_contains "$launch" "--resume $SID_A " "the launch should resume the recorded conversation"
  assert_contains "$launch" "--model 'opus' --effort 'high' " "the resume should keep the recorded model and effort"
  assert_not_contains "$launch" "--session-id" "a resume must not mint a new conversation"
  assert_not_contains "$launch" "operational input waiting" "a resume must not deliver the launch brief again"
  assert_equals "$SID_A" "$(meta_field "$dir/home/state/cs2.meta" claude_session_id)" \
    "the record should keep the resumed id exactly once"
  [ "$(grep -c '^claude_session_id=' "$dir/home/state/cs2.meta")" = 1 ] \
    || fail "the republished record should hold one claude_session_id line"
  assert_grep ' state=idle ' "$dir/home/state/cs2.busy-state" "a resumed pane submits no turn, so it seeds idle"
  pass "fm-spawn --resume-session: resumes the recorded conversation with the recorded profile and no brief"
}

test_resume_session_refusals() {
  local dir out rc
  dir=$(new_task refuse cs3)
  out=$(run_spawn "$dir" cs3 --resume-session "$SID_A"); rc=$?
  expect_code 1 "$rc" "--resume-session without --relaunch should refuse"
  assert_contains "$out" "needs --relaunch" "the refusal should name the missing flag"
  out=$(run_spawn "$dir" cs3 --relaunch --resume-session NOT-A-UUID); rc=$?
  expect_code 1 "$rc" "a malformed id should refuse"
  out=$(run_spawn "$dir" cs3 --relaunch --resume-session "$SID_A" --model sonnet); rc=$?
  expect_code 1 "$rc" "a profile override should refuse"
  assert_contains "$out" "resumes the recorded profile exactly" "the refusal should say why"
  dir=$(new_task refuse-codex cs4 codex)
  out=$(run_spawn "$dir" cs4 --relaunch --resume-session "$SID_A"); rc=$?
  expect_code 1 "$rc" "a non-Claude task should refuse"
  assert_contains "$out" "Claude conversations only" "the refusal should name the harness limit"
  [ ! -s "$dir/fake/literal" ] || fail "a refused resume must launch nothing"
  pass "fm-spawn --resume-session: refuses without --relaunch, on a bad id, a profile change, or another harness"
}

test_session_hook_tracks_a_new_conversation() {
  local dir meta before
  dir="$TMP_ROOT/hook"
  mkdir -p "$dir/state"
  meta="$dir/state/hk1.meta"
  printf 'window=a:b\nclaude_session_id=%s\nspawn_gen=s1.1.1\n' "$SID_A" > "$meta"
  before=$(cat "$meta")
  printf '{"session_id":"%s","source":"resume"}' "$SID_A" | "$HOOK" record "$dir/state" hk1 \
    || fail "the hook must exit 0"
  assert_equals "$before" "$(cat "$meta")" "a resume keeps its id, so the record must not change"
  printf '{"session_id":"%s","source":"clear"}' "$SID_B" | "$HOOK" record "$dir/state" hk1 \
    || fail "the hook must exit 0"
  assert_equals "$SID_B" "$(meta_field "$meta" claude_session_id)" "a new conversation should be recorded"
  assert_equals 1 "$(grep -c '^claude_session_id=' "$meta")" "the id should be replaced, not appended"
  assert_equals a:b "$(meta_field "$meta" window)" "every other field should survive"
  printf 'not json' | "$HOOK" record "$dir/state" hk1 || fail "a bad payload must still exit 0"
  assert_equals "$SID_B" "$(meta_field "$meta" claude_session_id)" "a bad payload must change nothing"
  pass "fm-claude-session.sh record: rewrites the id only for a new conversation"
}

test_backfill_matches_the_newest_transcript_naming_the_task() {
  local dir cfg out rc meta
  dir=$(new_task backfill cs5)
  cfg="$dir/claude-config"
  meta="$dir/home/state/cs5.meta"
  printf 'backend=rex\nspawn_gen=s100.1.1\n' >> "$meta"
  write_transcript "$cfg" "$dir/wt" "$SID_A" "older session for cs5"
  touch -t 202001010000 "$cfg/projects/"*"/$SID_A.jsonl"
  write_transcript "$cfg" "$dir/wt" "$SID_B" "current session for cs5"
  write_transcript "$cfg" "$dir/wt" 99999999-9999-4999-8999-999999999999 "another task"
  out=$(CLAUDE_CONFIG_DIR=$cfg HOME="$dir/user-home" FM_HOME="$dir/home" "$RECOVER" --backfill 2>&1); rc=$?
  expect_code 0 "$rc" "a dry backfill should succeed: $out"
  assert_contains "$out" "cs5: would record claude_session_id=$SID_B" "the newest transcript naming the task should win"
  [ -z "$(meta_field "$meta" claude_session_id)" ] || fail "a dry run must not write"
  out=$(CLAUDE_CONFIG_DIR=$cfg HOME="$dir/user-home" FM_HOME="$dir/home" "$RECOVER" --backfill --apply 2>&1); rc=$?
  expect_code 0 "$rc" "an applied backfill should succeed: $out"
  assert_equals "$SID_B" "$(meta_field "$meta" claude_session_id)" "the matched id should be recorded"
  out=$(CLAUDE_CONFIG_DIR=$cfg HOME="$dir/user-home" FM_HOME="$dir/home" "$RECOVER" --backfill 2>&1)
  assert_not_contains "$out" "would record" "a recorded task needs no second backfill"
  pass "fm-recover.sh --backfill: records the newest transcript that names the task, only on --apply"
}

test_unsupported_tasks_are_reported_not_touched() {
  local dir out rc
  dir=$(new_task unsupported cs6)
  out=$(FM_HOME="$dir/home" "$RECOVER" 2>&1); rc=$?
  expect_code 0 "$rc" "a plan with nothing resumable should succeed"
  assert_contains "$out" "cs6: unsupported - only claude on the rex backend resumes" "a tmux task should be reported"
  out=$(FM_HOME="$dir/home" "$RECOVER" --digest 2>&1)
  assert_equals "" "$out" "the session-start digest stays silent about tasks it cannot resume"
  pass "fm-recover.sh: reports a task it cannot resume and leaves it alone"
}

test_primary_command_resumes_the_recorded_session() {
  local dir cfg out rc
  dir="$TMP_ROOT/primary"
  cfg="$dir/claude-config"
  mkdir -p "$dir/home/state"
  printf 'session_id=%s\ncwd=%s\nlaunch_flags=--model opus\n' "$SID_A" "$dir/home" > "$dir/home/state/primary-claude-session"
  out=$(CLAUDE_CONFIG_DIR=$cfg HOME="$dir/user-home" FM_HOME="$dir/home" "$RECOVER" --primary 2>&1); rc=$?
  expect_code 1 "$rc" "a session with no transcript must not be offered"
  assert_contains "$out" "refusing to start a fresh one" "the refusal should say why"
  write_transcript "$cfg" "$dir/home" "$SID_A" "primary"
  out=$(CLAUDE_CONFIG_DIR=$cfg HOME="$dir/user-home" FM_HOME="$dir/home" "$RECOVER" --primary 2>&1); rc=$?
  expect_code 0 "$rc" "a recorded primary should print its command: $out"
  assert_equals "cd '$dir/home' && claude --resume $SID_A --model opus" "$out" "the command should resume in the recorded directory"
  pass "fm-recover.sh --primary: prints the resume command only for a transcript on disk"
}

test_route_target_reads_labels_with_spaces() {
  local dir out
  dir="$TMP_ROOT/routes"
  mkdir -p "$dir/config"
  printf '# comment\ncpt-rig    Rig\ncpt-*  Long running temporary  \n' > "$dir/config/rex-session-routes"
  out=$(FM_HOME="$dir" CONFIG="$dir/config" bash -c '. "$1/bin/backends/rex.sh"; fm_backend_rex_route_target cpt-flag-rig' _ "$ROOT")
  assert_equals "Long running temporary" "$out" "a glob route should yield its whole trimmed label"
  out=$(FM_HOME="$dir" CONFIG="$dir/config" bash -c '. "$1/bin/backends/rex.sh"; fm_backend_rex_route_target fm-other' _ "$ROOT")
  assert_equals "" "$out" "an unrouted task has no target"
  pass "rex adapter: route targets keep multi-word labels"
}

test_liveness_resumes_only_a_recorded_rex_session() {
  local dir cfg meta out
  dir="$TMP_ROOT/liveness"
  cfg="$dir/claude-config"
  mkdir -p "$dir/state" "$dir/home"
  meta="$dir/state/sm1.meta"
  printf 'harness=claude\nkind=secondmate\nworktree=%s\nbackend=rex\nclaude_session_id=%s\n' "$dir/home" "$SID_A" > "$meta"
  probe() {
    CLAUDE_CONFIG_DIR=$cfg HOME="$dir/user-home" FM_HOME="$dir/home" STATE="$dir/state" \
      bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_claude_session "$2"' _ "$ROOT" "$meta"
  }
  out=$(probe) && fail "a session with no transcript must not be resumed, got '$out'"
  write_transcript "$cfg" "$dir/home" "$SID_A" "secondmate"
  out=$(probe) || fail "a recorded Rex session with its transcript should resume"
  assert_equals "$SID_A" "$out" "the recorded id should be the one resumed"
  printf 'backend=tmux\n' >> "$meta"
  out=$(probe) && fail "a tmux mate keeps the ordinary respawn, got '$out'"
  pass "secondmate liveness: resumes a recorded Rex Claude session only when its transcript is on disk"
}

test_relaunch_mints_and_records_a_session_id
test_resume_session_continues_the_recorded_conversation
test_resume_session_refusals
test_session_hook_tracks_a_new_conversation
test_backfill_matches_the_newest_transcript_naming_the_task
test_unsupported_tasks_are_reported_not_touched
test_primary_command_resumes_the_recorded_session
test_route_target_reads_labels_with_spaces
test_liveness_resumes_only_a_recorded_rex_session
