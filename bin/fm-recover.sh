#!/usr/bin/env bash
# fm-recover.sh - resume every Claude worker this home records after a crash or
# kill, exactly where its conversation stopped.
#
# Usage:
#   fm-recover.sh [--apply] [<task-id>...]       plan (default) or act, per task
#   fm-recover.sh --backfill [--apply] [<id>...] record missing session ids only
#   fm-recover.sh --digest                        session-start plan, silent when nothing to do
#   fm-recover.sh --primary [--apply]             print (or exec) the primary's resume command
#
# Per task record in this home (ship, scout, captain crew, secondmate, standing):
#   claude running in its pane   -> left alone
#   pane alive, shell idle       -> resumed in that pane
#   pane gone                    -> re-created in its routed Rex session
#                                   (config/rex-session-routes, created by label
#                                   when missing), else its recorded session, and
#                                   resumed; the record rebinds to the new pane
#   no claude_session_id         -> backfilled from the newest transcript naming
#                                   the task (bin/fm-claude-session-lib.sh), or reported
# Every resume goes through bin/fm-spawn.sh <id> --relaunch --resume-session,
# the single launch owner, which re-proves the pane agent-free under the task's
# locks. Nothing is torn down, a live claude is never touched, and a session
# whose transcript is not on disk is reported rather than replaced by a fresh
# conversation. Only claude tasks on the rex backend are resumed; others are
# reported. Running it twice is safe: a resumed task reads live the second time.
#
# Exit: 0 when the plan or every action succeeded, 1 when any task was left
# unrecovered or reported, 2 on usage errors.
#
# Environment: FM_HOME (default: this script's checkout), FM_STATE_OVERRIDE,
# FM_RECOVER_CONFIRM_SECS (default 45) bounds the wait for a resumed claude.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIRM_SECS=${FM_RECOVER_CONFIRM_SECS:-45}
case "$CONFIRM_SECS" in ''|*[!0-9]*) CONFIRM_SECS=45 ;; esac
export FM_HOME

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

MODE=plan
APPLY=0
IDS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --backfill) MODE=backfill ;;
    --digest) MODE=digest ;;
    --primary) MODE=primary ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $a" >&2; usage >&2; exit 2 ;;
    *) IDS+=("$a") ;;
  esac
done
[ "$MODE" != digest ] || [ "$APPLY" -eq 0 ] || { echo "error: --digest never applies; run without it to act" >&2; exit 2; }

# shellcheck source=bin/fm-claude-session-lib.sh
. "$SCRIPT_DIR/fm-claude-session-lib.sh"

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

primary_command() {
  local rec="$STATE/primary-claude-session" sid cwd flags
  [ -f "$rec" ] || { echo "error: no primary session recorded at $rec; open firstmate once with this version to record it" >&2; return 1; }
  sid=$(fm_claude_meta_value "$rec" session_id)
  cwd=$(fm_claude_meta_value "$rec" cwd)
  flags=$(fm_claude_meta_value "$rec" launch_flags)
  fm_claude_uuid_valid "$sid" && [ -n "$cwd" ] || { echo "error: $rec is unreadable" >&2; return 1; }
  fm_claude_transcript_path "$cwd" "$sid" >/dev/null || {
    echo "error: the primary's recorded conversation $sid has no transcript under $cwd; refusing to start a fresh one in its place" >&2
    return 1
  }
  [ "$flags" != '?' ] || flags=
  printf 'cd %s && claude --resume %s%s\n' "$(sq "$cwd")" "$sid" "${flags:+ $flags}"
}

if [ "$MODE" = primary ]; then
  cmd=$(primary_command) || exit 1
  if [ "$APPLY" -eq 1 ]; then
    exec bash -c "${cmd/&& claude /&& exec claude }"
  fi
  printf '%s\n' "$cmd"
  exit 0
fi

[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 2; }
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source rex >/dev/null 2>&1 || true

# Sets SID and SID_SOURCE (recorded|matched|none) and SID_NOTE for one record.
resolve_session() {  # <meta> <id> <cwd>
  local meta=$1 id=$2 cwd=$3 match
  SID=$(fm_meta_get "$meta" claude_session_id)
  SID_NOTE=
  if [ -n "$SID" ]; then
    SID_SOURCE=recorded
    return 0
  fi
  if match=$(fm_claude_match_transcript "$cwd" "$id" "$(fm_claude_spawn_epoch "$meta")"); then
    SID=${match%%$'\t'*}
    SID_SOURCE=matched
    SID_NOTE=${match#*$'\t'}
    return 0
  fi
  SID_SOURCE=none
}

route_note() {  # <id> <meta>
  local target
  target=$(CONFIG=$CONFIG fm_backend_rex_route_target "$1" 2>/dev/null) || target=
  if [ -n "$target" ]; then
    printf 'routed Rex session "%s"' "$target"
  else
    printf 'recorded Rex session %s' "$(fm_meta_get "$2" rex_session_id)"
  fi
}

confirm_alive() {  # <meta>
  local i=0 target state
  while [ "$i" -le "$CONFIRM_SECS" ]; do
    target=$(fm_backend_target_of_meta "$1")
    state=$(fm_backend_agent_state rex "$target" 2>/dev/null) || state=unreadable
    [ "$state" != alive ] || return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

FAILED=0
ACTIONABLE=0
LIVE=0
UNRECORDED_LIVE=0
LINES=()
say() { LINES+=("$1"); }

recover_one() {  # <meta>
  local meta=$1 id harness backend kind cwd target state action out
  id=$(basename "$meta" .meta)
  harness=$(fm_meta_get "$meta" harness)
  backend=$(fm_backend_of_meta "$meta")
  kind=$(fm_meta_get "$meta" kind)
  cwd=$(fm_meta_get "$meta" worktree)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    [ "$MODE" = digest ] || say "$id: skipped - a remote secondmate recovers on its own host"
    return 0
  fi
  if [ "$harness" != claude ] || [ "$backend" != rex ]; then
    [ "$MODE" = digest ] || say "$id: unsupported - only claude on the rex backend resumes (this is $harness on $backend); use bin/fm-control.sh $id relaunch"
    return 0
  fi
  [ -n "$target" ] || { say "$id: no endpoint recorded - reconcile its record by hand"; FAILED=1; return 0; }
  resolve_session "$meta" "$id" "$cwd"

  if [ "$MODE" = backfill ]; then
    case "$SID_SOURCE" in
      recorded) return 0 ;;
      none) say "$id: no transcript under $cwd names this task - nothing to record"; FAILED=1; return 0 ;;
    esac
    if [ "$APPLY" -eq 1 ]; then
      if fm_claude_meta_set_session "$meta" "$SID" 100; then
        say "$id: recorded claude_session_id=$SID (from $SID_NOTE)"
      else
        say "$id: could not record claude_session_id=$SID"; FAILED=1
      fi
    else
      say "$id: would record claude_session_id=$SID (from $SID_NOTE)"
    fi
    return 0
  fi

  state=$(fm_backend_agent_state rex "$target" 2>/dev/null) || state=unreadable
  case "$state" in
    alive)
      LIVE=$((LIVE + 1))
      if [ "$SID_SOURCE" != recorded ]; then
        UNRECORDED_LIVE=$((UNRECORDED_LIVE + 1))
        [ "$MODE" = digest ] || say "$id: claude live - left alone; no recorded session id (bin/fm-recover.sh --backfill --apply records it)"
      else
        [ "$MODE" = digest ] || say "$id: claude live - left alone"
      fi
      return 0
      ;;
    dead) action="idle shell in its pane - resume there" ;;
    missing) action="pane gone - re-create it in the $(route_note "$id" "$meta") and resume there" ;;
    unreadable) action="pane unreadable (a stopped Rex server reads this way) - prove it gone, re-create it in the $(route_note "$id" "$meta"), and resume there" ;;
    *)
      say "$id: endpoint reads '$state' - left alone; inspect it by hand"
      FAILED=1
      return 0
      ;;
  esac
  ACTIONABLE=$((ACTIONABLE + 1))
  case "$SID_SOURCE" in
    none)
      say "$id ($kind): $action, but no session id is recorded and no transcript under $cwd names it - nothing to resume"
      FAILED=1
      return 0
      ;;
    matched) action="$action (session $SID matched from $SID_NOTE)" ;;
    recorded) action="$action (session $SID)" ;;
  esac
  if ! fm_claude_transcript_path "$cwd" "$SID" >/dev/null; then
    say "$id ($kind): $action, but that transcript is not on disk - refusing to start a fresh conversation in its place"
    FAILED=1
    return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    say "$id ($kind): $action"
    return 0
  fi
  if [ "$SID_SOURCE" = matched ] && ! fm_claude_meta_set_session "$meta" "$SID" 100; then
    say "$id: could not record matched session $SID; not resumed"
    FAILED=1
    return 0
  fi
  if ! out=$(FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-spawn.sh" "$id" --relaunch --resume-session "$SID" 2>&1); then
    say "$id: resume refused - $(printf '%s\n' "$out" | grep -m1 'error' || printf '%s\n' "$out" | tail -1)"
    FAILED=1
    return 0
  fi
  if confirm_alive "$meta"; then
    say "$id: resumed session $SID ($(fm_meta_get "$meta" window))"
  else
    say "$id: resume launched but claude did not read alive within ${CONFIRM_SECS}s - inspect its pane"
    FAILED=1
  fi
}

if [ "${#IDS[@]}" -gt 0 ]; then
  for id in "${IDS[@]}"; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id '$id'" >&2; exit 2 ;; esac
    [ -f "$STATE/$id.meta" ] || { echo "error: no task record $STATE/$id.meta" >&2; exit 2; }
    recover_one "$STATE/$id.meta"
  done
else
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    recover_one "$meta"
  done
fi

self=$(sq "$SCRIPT_DIR/fm-recover.sh")
case "$MODE" in
  digest)
    if [ "$ACTIONABLE" -gt 0 ] || [ "${#LINES[@]}" -gt 0 ]; then
      printf 'Claude workers to recover (dry run; nothing was changed):\n'
      printf '  %s\n' "${LINES[@]}"
      [ "$ACTIONABLE" -eq 0 ] || printf 'Apply with: FM_HOME=%s %s --apply\n' "$(sq "$FM_HOME")" "$self"
    fi
    [ "$UNRECORDED_LIVE" -eq 0 ] \
      || printf '%s live claude worker(s) have no recorded session id; record them with: FM_HOME=%s %s --backfill --apply\n' \
        "$UNRECORDED_LIVE" "$(sq "$FM_HOME")" "$self"
    exit 0
    ;;
  *)
    [ "${#LINES[@]}" -gt 0 ] || LINES=("no claude task records in $STATE")
    printf '%s\n' "${LINES[@]}"
    if [ "$APPLY" -eq 0 ] && { [ "$ACTIONABLE" -gt 0 ] || [ "$MODE" = backfill ]; }; then
      extra=
      [ "$MODE" != backfill ] || extra=' --backfill'
      printf 'Dry run; nothing was changed. Apply with: FM_HOME=%s %s%s --apply\n' "$(sq "$FM_HOME")" "$self" "$extra"
    fi
    ;;
esac
exit "$FAILED"
