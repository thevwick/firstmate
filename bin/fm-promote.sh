#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# Usage: fm-promote.sh <task-id> [--force-locked]
#   A promoted scout becomes a full committing ship crew exactly like a fresh
#   bin/fm-spawn.sh ship spawn, so it is refused the same way if the task's
#   recorded project is Cawldron-locked (state/cawldron-lock-<project>;
#   bin/fm-cawldron-lock.sh) - unless --force-locked or FM_SPAWN_FORCE_LOCKED=1
#   (the same override fm-spawn.sh uses) is set.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-cawldron-lock-lib.sh
. "$SCRIPT_DIR/fm-cawldron-lock-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

FORCE_LOCKED=0
POS=()
USAGE='usage: fm-promote.sh <task-id> [--force-locked]'
for a in "$@"; do
  case "$a" in
    --force-locked) FORCE_LOCKED=1 ;;
    # A misspelled flag or a stray extra positional must not be silently
    # swallowed: "--forc-locked" would otherwise be dropped and the promote
    # would quietly refuse under a lock the captain meant to override.
    -*) echo "error: unknown argument: $a" >&2; echo "$USAGE" >&2; exit 1 ;;
    *)
      [ "${#POS[@]}" -eq 0 ] || { echo "error: unexpected extra argument: $a" >&2; echo "$USAGE" >&2; exit 1; }
      POS+=("$a")
      ;;
  esac
done
ID=${POS[0]:?$USAGE}
FORCE_LOCKED_EFFECTIVE=0
[ "$FORCE_LOCKED" -eq 0 ] || FORCE_LOCKED_EFFECTIVE=1
[ "${FM_SPAWN_FORCE_LOCKED:-0}" != 1 ] || FORCE_LOCKED_EFFECTIVE=1

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# Cawldron coordination lock gate. The same shared helper bin/fm-spawn.sh's
# ship/scout check uses, so the locked/unlocked test and the refusal wording have
# exactly one owner (bin/fm-cawldron-lock-lib.sh); only the action phrase differs.
proj_field=$(grep '^project=' "$META" | head -1 | cut -d= -f2- || true)
if [ -n "$proj_field" ]; then
  fm_cawldron_gate "$STATE" "$proj_field" "$FORCE_LOCKED_EFFECTIVE" promote || exit 1
else
  echo "warning: cannot verify the Cawldron lock for $ID: no project recorded in $META" >&2
fi

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
