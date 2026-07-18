#!/usr/bin/env bash
# fm-cawldron-lock.sh - the Cawldron coordination lock.
#
# A firstmate-owned, per-project advisory marker recording that the captain is
# live in a Cawldron session (a generic, self-hosted human-in-the-loop coding
# shell that edits a project's working tree in place) on a project. Firstmate is
# the only writer; Cawldron itself stays dumb about firstmate and never reads or
# writes this marker (docs/cawldron-integration.md owns the wider design). The
# marker exists so bin/fm-spawn.sh can refuse to launch a background ship/scout
# crew into a project the captain is actively hand-editing through Cawldron,
# preventing an unlanded live edit from colliding with a crew's commits.
#
# Usage:
#   fm-cawldron-lock.sh <project> [--note "<text>"]
#     Set the lock for <project>. Warns (but still sets) if <project> is not a
#     known project (data/projects.md, or an existing projects/<project> dir) -
#     the target repo may not be cloned yet. Warns (but still sets) if any live
#     crew (state/*.meta with a project= field whose basename matches <project>)
#     is already recorded on it - a crew may already be on that project.
#   fm-cawldron-lock.sh <project> --clear
#     Remove the lock for <project>. Always prints a one-line reminder that the
#     captain's Cawldron edits for that project may still be sitting uncommitted
#     in its working tree, to reconcile before dispatching crews there.
#   fm-cawldron-lock.sh [--list]
#     List active locks with age and note. The default with no arguments.
#   fm-cawldron-lock.sh -h|--help
#
# Marker: state/cawldron-lock-<project>, containing "since=<epoch>" and an
# optional "note=<text>" line (bin/fm-cawldron-lock-lib.sh owns the format).
# FM_HOME/FM_STATE_OVERRIDE resolve the state dir exactly as other bin/ scripts
# do. <project> must be a leaf name (no path separators).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-cawldron-lock-lib.sh
. "$SCRIPT_DIR/fm-cawldron-lock-lib.sh"

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

list_locks() {
  local project since note age line printed
  printed=0
  while IFS=$'\t' read -r project since note; do
    [ -n "$project" ] || continue
    printed=1
    age=$(fm_cawldron_lock_age_human "$since")
    if [ -n "$note" ]; then
      line="$project - locked $age ago (note: $note)"
    else
      line="$project - locked $age ago"
    fi
    printf '%s\n' "$line"
  done < <(fm_cawldron_lock_list "$STATE")
  [ "$printed" -eq 1 ] || echo "no active Cawldron locks"
}

if [ $# -eq 0 ] || [ "${1:-}" = --list ]; then
  list_locks
  exit 0
fi

PROJECT=$1
shift

case "$PROJECT" in
  -*) echo "error: missing <project> (got '$PROJECT'); usage: fm-cawldron-lock.sh <project> [--note <text>|--clear]" >&2; exit 1 ;;
  */*) echo "error: <project> must be a leaf name, not a path: $PROJECT" >&2; exit 1 ;;
esac

NOTE=
CLEAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --note)
      shift
      [ $# -gt 0 ] || { echo "error: --note requires a value" >&2; exit 1; }
      NOTE=$1
      ;;
    --note=*) NOTE=${1#--note=} ;;
    --clear) CLEAR=1 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
[ "$CLEAR" -eq 0 ] || [ -z "$NOTE" ] || { echo "error: --note and --clear are mutually exclusive" >&2; exit 1; }

mkdir -p "$STATE"
MARKER=$(fm_cawldron_lock_path "$STATE" "$PROJECT")

if [ "$CLEAR" -eq 1 ]; then
  if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    echo "cawldron lock cleared: $PROJECT"
  else
    echo "cawldron lock: $PROJECT was not locked"
  fi
  echo "reminder: the captain's Cawldron edits for $PROJECT may still be sitting uncommitted in that repo's working tree - reconcile them before dispatching crews there."
  exit 0
fi

# <project> validation: known if it is a leaf in data/projects.md or an existing
# projects/<project> dir. Unknown is a WARN, not a refusal - the target repo may
# not be cloned yet (e.g. a new monorepo).
project_known() {
  local name=$1 reg="$DATA/projects.md"
  [ -d "$PROJECTS/$name" ] && return 0
  [ -f "$reg" ] || return 1
  awk -v n="$name" '$1=="-" && $2==n { found=1; exit } END { exit !found }' "$reg"
}
if ! project_known "$PROJECT"; then
  echo "warning: '$PROJECT' is not a known project (absent from data/projects.md and projects/); setting the lock anyway." >&2
fi

# Live-crew scan: state/*.meta files whose project= basename matches. Purely
# informational - the lock is still set even when crews are already there.
live_crew_ids=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  proj_field=$(grep '^project=' "$meta" | head -1 | cut -d= -f2- || true)
  [ -n "$proj_field" ] || continue
  if [ "$(basename "$proj_field")" = "$PROJECT" ]; then
    live_crew_ids+=("$(basename "$meta" .meta)")
  fi
done
if [ "${#live_crew_ids[@]}" -gt 0 ]; then
  {
    printf '●%s\n' "$RULE"
    printf '●  CAWLDRON LOCK SET WHILE A CREW IS ALREADY ON %s\n' "$PROJECT"
    printf '●  Live crew(s) already recorded on this project: %s\n' "${live_crew_ids[*]}"
    printf '●  The lock is informational only - it does not stop or notify those crews.\n'
    printf '●%s\n' "$RULE"
  } >&2
fi

SINCE=$(date +%s)
fm_cawldron_lock_write "$MARKER" "$SINCE" "$NOTE"
if [ -n "$NOTE" ]; then
  echo "cawldron lock set: $PROJECT (note: $NOTE)"
else
  echo "cawldron lock set: $PROJECT"
fi
