#!/usr/bin/env bash
# fm-await-external.sh - mark a task as deliberately waiting on a dependency
# outside the fleet, so its idle pane stops producing stale: wakes.
#
# The problem this solves: bin/fm-watch.sh detects pane staleness by hashing the
# last 40 captured lines and surfacing each DISTINCT hash once. A harness whose
# footer keeps redrawing while the agent sits idle (a spinner, an update notice,
# an agent counter) moves those bytes between captures, so the hash moves, so
# every poll reads as a brand-new stale event and is surfaced again - forever.
#
# The existing declared-pause absorb (a crew's own `paused:` status, see
# bin/fm-classify-lib.sh) covers the case where the CREW knows it is waiting. It
# does not cover the case this flag exists for: a crew whose last word was
# `blocked:` (firstmate action needed), where firstmate has since acted and the
# only thing left is an external dependency - a CI build, a vendor response, a
# human device test. That crew is not going to write another status line, so
# nothing crew-side can ever clear the churn.
#
# Scope: this suppresses ONLY the pane-hash staleness wake. Every other wake
# path is untouched - a status write, a turn-end marker, an armed check, and the
# heartbeat backstop all still wake supervision normally, so marking a task here
# can never hide a genuine signal from it.
#
# `awaiting_external`, not `parked`: bin/fm-crew-state.sh already reports
# `parked` for a run parked at a validation gate, and this is a different
# concept. The field is separate from `kind=` on purpose - a scout waiting on a
# build is still a scout.
#
# Usage:
#   fm-await-external.sh set <task-id> <reason>
#   fm-await-external.sh clear <task-id>
#   fm-await-external.sh status <task-id>
#
# `set` is idempotent: repeating it with a new reason replaces the reason.
# `clear` is idempotent and always leaves the task fully supervised again.
# `status` prints `awaiting-external: <reason>` or `supervised`, and exits 0
# either way; it exits non-zero only when the task itself is unreadable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() { echo "fm-await-external: $1" >&2; exit 1; }

# A reason is stored on one meta line, so it must not carry a newline and must
# stay a single readable line for the fleet view.
reason_valid() {  # <reason>
  local r=${1-}
  [ -n "$r" ] || return 1
  [ "${#r}" -le 200 ] || return 1
  # Reject any control character, so the reason cannot inject a second meta line.
  case "$r" in
    *[[:cntrl:]]*) return 1 ;;
  esac
}

meta_of() {  # <task-id>
  local id=$1 meta
  fm_pr_task_id_valid "$id" || fail "invalid task id"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "no task metadata for $id"
  printf '%s' "$meta"
}

# Rewrite <meta> without any awaiting_external= line, then append the new value
# when one is given. Written to a temp file in the same directory and moved into
# place, so a torn write can never leave the watcher a half-parsed meta.
rewrite_meta() {  # <meta> [<reason>]
  local meta=$1 reason=${2-} tmp line
  tmp=$(mktemp "$STATE/.fm-await-meta.XXXXXX") || fail "could not stage metadata"
  # shellcheck disable=SC2064 # expand $tmp now: the trap must survive `local` scope.
  trap "rm -f -- '$tmp'" EXIT
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      awaiting_external=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" || fail "could not stage metadata" ;;
    esac
  done < "$meta"
  [ -z "$reason" ] || printf 'awaiting_external=%s\n' "$reason" >> "$tmp" || fail "could not stage metadata"
  chmod 0600 "$tmp" || fail "could not stage metadata"
  mv -f -- "$tmp" "$meta" || fail "could not record metadata"
  trap - EXIT
}

# Drop the stale/wedge bookkeeping for this task's pane so the transition takes
# effect on the next poll instead of inheriting a mid-flight escalation timer.
clear_stale_markers() {  # <meta>
  local meta=$1 target key
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  key=$(printf '%s' "$target" | tr ':/.' '___')
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

cmd=${1-}
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  set)
    [ "$#" -eq 3 ] || fail "usage: fm-await-external.sh set <task-id> <reason>"
    reason_valid "$3" || fail "reason must be one non-empty line of at most 200 characters"
    META=$(meta_of "$2")
    rewrite_meta "$META" "$3"
    clear_stale_markers "$META"
    printf 'awaiting-external %s: %s\n' "$2" "$3"
    ;;
  clear)
    [ "$#" -eq 2 ] || fail "usage: fm-await-external.sh clear <task-id>"
    META=$(meta_of "$2")
    rewrite_meta "$META"
    clear_stale_markers "$META"
    printf 'supervised %s\n' "$2"
    ;;
  status)
    [ "$#" -eq 2 ] || fail "usage: fm-await-external.sh status <task-id>"
    META=$(meta_of "$2")
    VALUE=$(fm_meta_get "$META" awaiting_external)
    if [ -n "$VALUE" ]; then
      printf 'awaiting-external: %s\n' "$VALUE"
    else
      printf 'supervised\n'
    fi
    ;;
  ""|*) usage >&2; exit 2 ;;
esac
