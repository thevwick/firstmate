#!/usr/bin/env bash
# Reclaim disk from treehouse slots no live task is using.
#
# A slot is reclaimable only when ALL of these hold:
#   - no state/<id>.meta in ANY firstmate home records it as a worktree
#   - it is detached with no branch checked out
#   - it has zero uncommitted changes
#   - no process holds a file open under it
#
# Default is report-only. --apply does the work. There is deliberately no
# --force: a slot that fails any check is left alone, full stop.
set -uo pipefail

JUNK=(node_modules ios/Pods ios/build android/build android/app/build .gradle common/temp)
POOL_ROOT=${TREEHOUSE_ROOT:-$HOME/.treehouse}
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Every slot path recorded by a live task, across every firstmate home.
held_paths() {
  local home
  for home in "$HOME"/.firstmate-* "$HOME"/sitemate/firstmate "${FM_HOME:-}"; do
    [ -d "$home/state" ] || continue
    grep -h '^worktree=' "$home"/state/*.meta 2>/dev/null | cut -d= -f2-
  done
}

HELD=$(held_paths | sort -u)

is_held() {
  local dir=$1
  printf '%s\n' "$HELD" | grep -qxF "$dir"
}

refuse() { echo "  skip: $1"; }

total_freed=0
reclaimed=0

for dir in "$POOL_ROOT"/*/*/*; do
  [ -d "$dir" ] || continue
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue

  # Never operate on a root, a home, or a trailing-slash path.
  case "$dir" in
    "$HOME"|/|"$POOL_ROOT"|*/) continue ;;
  esac

  size=$(du -sk "$dir" 2>/dev/null | cut -f1) || size=0
  [ "$size" -gt 102400 ] || continue   # under 100MB, not worth the risk

  echo "$dir ($(( size / 1024 ))MB)"

  if is_held "$dir"; then
    refuse "held by a live task"
    continue
  fi

  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  if [ -n "$branch" ]; then
    refuse "on branch $branch, not detached"
    continue
  fi

  dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dirty" != "0" ]; then
    refuse "$dirty uncommitted change(s)"
    continue
  fi

  if command -v lsof >/dev/null 2>&1 && lsof +D "$dir" >/dev/null 2>&1; then
    refuse "open file handles under it"
    continue
  fi

  if [ "$APPLY" = "0" ]; then
    echo "  would clear build output (re-run with --apply)"
    continue
  fi

  before=$size
  for junk in "${JUNK[@]}"; do
    [ -e "$dir/$junk" ] && rm -rf "${dir:?}/${junk:?}"
  done
  after=$(du -sk "$dir" 2>/dev/null | cut -f1) || after=0
  freed=$(( (before - after) / 1024 ))
  total_freed=$(( total_freed + freed ))
  reclaimed=$(( reclaimed + 1 ))
  echo "  cleared ${freed}MB"
done

if [ "$APPLY" = "1" ]; then
  echo
  echo "reclaimed ${total_freed}MB from ${reclaimed} slot(s)"
fi
