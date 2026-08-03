#!/usr/bin/env bash
# Reap idle treehouse pool slots so a project's pool self-limits instead of
# growing to the high-water mark of concurrent crews and never shrinking.
# fm-teardown.sh RETURNS a worktree to the pool; it never removes one, so a
# returned slot keeps its full checkout, node_modules, and build artifacts.
# Observed cost of that: one 8-slot mobile pool held 22.6 GiB across 4 slots
# that had been idle since a one-off burst of 8 concurrent crews.
#
# Usage: fm-worktree-reap.sh <project-dir-or-name> [--dry-run]
#   --dry-run reports what would be reaped and removes nothing.
#
# WHY PER-SLOT `treehouse destroy` AND NOT `treehouse prune`
# `treehouse prune` reclaims every disposable slot in the pool at once and has
# no floor, so it empties the pool. Verified on 2026-08-03 with treehouse
# v2.0.0: a `prune` dry run against a 1-slot gearbelt pool reported "would prune
# 1 stale worktree and reclaim 2.7 GiB" - i.e. it would leave zero pre-warmed
# slots. Keeping slots pre-warmed is the entire point of the pool (re-cloning
# sitemate costs ~7 GiB and minutes), so the floor has to be enforced outside
# treehouse. `treehouse destroy <exact-worktree-path>` is the per-slot primitive
# that makes that possible.
#
# SAFETY: this NEVER passes any --include-* flag. A bare `treehouse destroy`
# removes only the genuinely disposable set (merged, clean, idle, unleased) and
# skips everything else, so an unlanded, dirty, in-use, or leased slot survives
# even if this script picks it as a reap candidate. That refusal is treehouse's
# to make and is deliberately not second-guessed here.
#
# Reap candidates come from `treehouse status`: only slots reported `available`
# are eligible. `dirty` and `in-use` slots are never targeted. Candidates are
# reaped oldest-first (highest slot number first, which is the least recently
# pre-warmed end of the pool) until the floor is reached.
#
# DIRTY-SLOT BLIND SPOT: a slot holding uncommitted changes is invisible - it
# is never reaped and nothing else reports it, so it can sit forever holding
# both disk and un-rescued work. This script surfaces those slots and their
# paths so the captain can act. It NEVER auto-commits, auto-rescues, or removes
# them.
#
# FAILURE POSTURE: reaping is housekeeping. Every failure path returns 0 and
# reports a single line, so this can never fail a teardown or abort a session
# start. This mirrors bin/fm-fleet-sync.sh's best-effort posture in bootstrap.
#
# CONFIG: config/worktree-reap, read as the first non-empty, non-comment line.
#   absent          floor of 2 idle slots per pool (the default)
#   off             disabled entirely
#   <n>             floor of <n> idle slots per pool
# See docs/configuration.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Default floor of idle slots to keep pre-warmed per pool. Two covers the common
# case of a second task dispatched while one is running without paying a re-clone,
# while still letting an 8-slot burst pool collapse back to 2.
REAP_DEFAULT_FLOOR=2

# Injectable command seam so tests can drive the whole reap without a real pool
# and without destroying anything. Both default to the real CLI.
TREEHOUSE_STATUS_CMD=${FM_TREEHOUSE_STATUS_CMD:-}
TREEHOUSE_DESTROY_CMD=${FM_TREEHOUSE_DESTROY_CMD:-}

usage() {
  echo "usage: fm-worktree-reap.sh <project-dir-or-name> [--dry-run]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

# Resolve the configured floor. Absent file, blank file, or an unreadable value
# means the default; "off" (any case) disables reaping. A value that is not a
# non-negative integer is reported once and treated as the default rather than
# silently disabling housekeeping or, worse, reaping to zero.
resolve_floor() {
  local file="$CONFIG/worktree-reap" line
  [ -f "$file" ] || { printf '%s\n' "$REAP_DEFAULT_FLOOR"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    case "$line" in
      [Oo][Ff][Ff]) printf 'off\n'; return 0 ;;
      ''|*[!0-9]*)
        echo "reap: invalid config/worktree-reap value '$line'; using default floor $REAP_DEFAULT_FLOOR" >&2
        printf '%s\n' "$REAP_DEFAULT_FLOOR"
        return 0
        ;;
      *) printf '%s\n' "$line"; return 0 ;;
    esac
  done < "$file"
  printf '%s\n' "$REAP_DEFAULT_FLOOR"
}

# Accept a path or a bare/"projects/<name>" name, resolved against $PROJECTS.
# Mirrors fm-fleet-sync.sh's resolve_project_arg so both take the same forms.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
      ;;
    */*)
      [ -d "$arg" ] && { printf '%s\n' "$arg"; return 0; }
      ;;
    *)
      candidate="$PROJECTS/$arg"
      [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
      [ -d "$arg" ] && { printf '%s\n' "$arg"; return 0; }
      ;;
  esac
  printf '%s\n' "$arg"
}

# Expand a leading ~ in a treehouse-reported path. `treehouse status` abbreviates
# home as "~", but `treehouse destroy` needs a real path.
expand_tilde() {
  # shellcheck disable=SC2088  # matching a literal leading "~/" in treehouse's
  # output, deliberately unexpanded; $HOME substitution is what the body does.
  case "$1" in
    '~/'*) printf '%s/%s\n' "$HOME" "${1#'~/'}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

run_status() {
  if [ -n "$TREEHOUSE_STATUS_CMD" ]; then
    ( cd "$PROJ" && $TREEHOUSE_STATUS_CMD ) 2>/dev/null
  else
    ( cd "$PROJ" && treehouse status ) 2>/dev/null
  fi
}

run_destroy() {
  local path=$1
  if [ -n "$TREEHOUSE_DESTROY_CMD" ]; then
    ( cd "$PROJ" && $TREEHOUSE_DESTROY_CMD --yes "$path" ) 2>&1
  else
    # No --include-* flag, ever. treehouse skips anything not genuinely
    # disposable, which is exactly the refusal we want to inherit.
    ( cd "$PROJ" && treehouse destroy --yes "$path" ) 2>&1
  fi
}

# Parse `treehouse status` into "<state>\t<path>" lines. Status prints one line
# per slot as "<n>  <state>  <path>", optionally followed by indented process
# lines for an in-use slot; those continuation lines have no state token in
# field 2 and are skipped. The upgrade banner and any blank lines are ignored.
# The path is taken as everything after the state token rather than as field 3,
# so a pool path containing spaces is not silently truncated into a DIFFERENT,
# possibly existing path that would then be handed to destroy.
parse_status() {
  awk '
    match($0, /^[0-9]+[[:space:]]+(available|dirty|in-use)[[:space:]]+/) {
      state = $2
      path = substr($0, RSTART + RLENGTH)
      sub(/[[:space:]]+$/, "", path)
      if (path != "") printf "%s\t%s\n", state, path
    }
  '
}

main() {
  local arg=${1:-} dry=${2:-} floor
  [ -n "$arg" ] || { usage; return 0; }
  [ "$dry" = "" ] || [ "$dry" = "--dry-run" ] || { usage; return 0; }

  floor=$(resolve_floor)
  if [ "$floor" = off ]; then
    return 0
  fi

  PROJ=$(resolve_project_arg "$arg")
  local label
  case "$PROJ" in
    "$PROJECTS"/*) label=$(basename "$PROJ") ;;
    *) label=$(basename "$PROJ") ;;
  esac

  if [ ! -d "$PROJ" ]; then
    echo "reap: $label: skipped: not a directory"
    return 0
  fi
  if [ -z "$TREEHOUSE_STATUS_CMD" ] && ! command -v treehouse >/dev/null 2>&1; then
    echo "reap: $label: skipped: treehouse not installed"
    return 0
  fi

  local status_out
  if ! status_out=$(run_status); then
    echo "reap: $label: skipped: could not read pool status"
    return 0
  fi

  local parsed idle_paths=() dirty_paths=() state path
  parsed=$(printf '%s\n' "$status_out" | parse_status)
  if [ -z "$parsed" ]; then
    echo "reap: $label: skipped: no pool slots found"
    return 0
  fi

  while IFS=$'\t' read -r state path; do
    [ -n "$state" ] || continue
    case "$state" in
      available) idle_paths+=("$(expand_tilde "$path")") ;;
      dirty) dirty_paths+=("$(expand_tilde "$path")") ;;
      *) : ;;  # in-use: never a candidate, never reported as a blind spot
    esac
  done <<< "$parsed"

  # Surface the dirty-slot blind spot regardless of whether anything is reaped:
  # a slot treehouse refuses to remove otherwise sits forever, invisible, holding
  # both disk and possibly un-rescued work. Report only; never touch it.
  if [ "${#dirty_paths[@]}" -gt 0 ]; then
    echo "reap: $label: ${#dirty_paths[@]} slot(s) hold uncommitted changes and were left untouched:"
    for path in "${dirty_paths[@]}"; do
      echo "reap: $label:   $path"
    done
  fi

  local idle_count=${#idle_paths[@]} excess
  if [ "$idle_count" -le "$floor" ]; then
    return 0
  fi
  excess=$(( idle_count - floor ))

  # Reap the highest-numbered idle slots first: status lists slots in ascending
  # order, and the tail of the pool is the burst capacity a one-off spike added,
  # while the low slots are the ones steady-state work keeps reusing.
  local reaped=0 target i
  for (( i = idle_count - 1; i >= 0 && reaped < excess; i-- )); do
    target=${idle_paths[$i]}
    if [ "$dry" = "--dry-run" ]; then
      echo "reap: $label: would reap $target"
      reaped=$(( reaped + 1 ))
      continue
    fi
    if run_destroy "$target" >/dev/null 2>&1; then
      echo "reap: $label: reaped $target"
    else
      # A refusal is a correct, expected outcome, not an error to escalate:
      # treehouse declined because the slot was not genuinely disposable.
      echo "reap: $label: left $target in place (treehouse declined to remove it)"
    fi
    reaped=$(( reaped + 1 ))
  done

  if [ "$reaped" -gt 0 ] && [ "$dry" != "--dry-run" ]; then
    echo "reap: $label: kept $floor idle slot(s) pre-warmed"
  fi
  return 0
}

# Housekeeping must never fail its caller. Any unexpected error inside main is
# swallowed here so a teardown, spawn, or session start can never abort on it.
main "$@" || true
exit 0
