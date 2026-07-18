# shellcheck shell=bash
# fm-cawldron-lock-lib.sh - shared marker mechanics for the Cawldron coordination
# lock (bin/fm-cawldron-lock.sh).
#
# ONE owner for the marker path, its "since=<epoch>[, note=<text>]" format, age
# formatting, and the human rendering of a lock (banner rule plus the shared
# "locked <age> ago[ (note: <text>)]" detail), so fm-cawldron-lock.sh (writer),
# fm-spawn.sh (spawn gate reader), and fm-bootstrap.sh (session-start detect
# line reader) cannot drift on either the file format or the wording.
#
# A marker that exists but carries no since= value is CORRUPT, not absent: a
# truncated or interrupted write must never silently disarm the spawn gate, so
# readers surface it and treat it as locked.
#
# Sourced by the three callers above. No side effects on source. set -u / set -e
# safe. Depends on nothing else in bin/.

# Shared a-dot banner rule for every Cawldron-lock banner. Consumed by the
# sourcing callers, not by this file.
# shellcheck disable=SC2034
FM_CAWLDRON_RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# fm_cawldron_lock_path <state-dir> <project>: print the marker path for
# <project> under <state-dir>. Does not check existence.
fm_cawldron_lock_path() {
  printf '%s/cawldron-lock-%s\n' "$1" "$2"
}

# fm_cawldron_lock_read <marker-path>: populates FM_CAWL_SINCE / FM_CAWL_NOTE
# (FM_CAWL_NOTE empty if the marker carries no note) and returns
#   0 - the marker exists and carries a since= value (locked)
#   1 - no marker at all (unlocked)
#   2 - the marker exists but carries no since= value (CORRUPT; still locked)
# Callers must distinguish 1 from 2: only 1 means "not locked". A note value may
# itself contain '=' - the read below assigns every character after the first
# '=' to the value, so that is preserved intact.
fm_cawldron_lock_read() {
  local path=$1 key value
  FM_CAWL_SINCE=
  FM_CAWL_NOTE=
  [ -f "$path" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      since) FM_CAWL_SINCE=$value ;;
      note) FM_CAWL_NOTE=$value ;;
    esac
  done < "$path"
  [ -n "$FM_CAWL_SINCE" ] || return 2
  return 0
}

# fm_cawldron_lock_write <marker-path> <since-epoch> [<note>]: write the marker,
# overwriting any prior content. Omits the note= line when <note> is empty.
# Writes to a temp sibling and renames, so an interrupted or out-of-space write
# can never leave a truncated marker in place of a good one. The temp is also
# removed on INT/TERM/HUP, so an interrupt between the redirect and the rename
# leaves no stray temp behind either.
fm_cawldron_lock_write() {
  local path=$1 since=$2 note=${3:-} tmp
  # Dot-prefixed so the in-flight temp never matches fm_cawldron_lock_list's
  # cawldron-lock-* glob.
  tmp="$(dirname "$path")/.cawldron-lock-tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" INT TERM HUP
  {
    printf 'since=%s\n' "$since"
    [ -z "$note" ] || printf 'note=%s\n' "$note"
  } > "$tmp" || { trap - INT TERM HUP; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { trap - INT TERM HUP; rm -f "$tmp"; return 1; }
  trap - INT TERM HUP
}

# fm_cawldron_lock_age_human <since-epoch> [<now-epoch>]: print a short
# human-readable age ("45s", "12m", "3h14m", "2d5h"). <now-epoch> defaults to
# the current time; tests pass it explicitly for deterministic output.
fm_cawldron_lock_age_human() {
  local since=$1 now=${2:-$(date +%s)} age d h m s
  age=$(( now - since ))
  [ "$age" -ge 0 ] || age=0
  d=$(( age / 86400 ))
  h=$(( (age % 86400) / 3600 ))
  m=$(( (age % 3600) / 60 ))
  s=$(( age % 60 ))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm' "$m"
  else
    printf '%ds' "$s"
  fi
}

# fm_cawldron_lock_detail <status> <since> <note> [<now-epoch>]: print the shared
# human rendering of one lock's state, the fragment every caller appends to its
# own prefix. <status> is "ok" or "corrupt" as reported by
# fm_cawldron_lock_list. A corrupt marker renders as an explicit unreadable
# notice rather than a bogus age, and is still a lock.
fm_cawldron_lock_detail() {
  local status=$1 since=$2 note=${3:-} now=${4:-} age
  if [ "$status" = corrupt ]; then
    printf 'LOCKED but the marker is unreadable (no since= value; truncated or corrupt write) - treat as locked and re-set or clear it with bin/fm-cawldron-lock.sh'
    return 0
  fi
  if [ -n "$now" ]; then
    age=$(fm_cawldron_lock_age_human "$since" "$now")
  else
    age=$(fm_cawldron_lock_age_human "$since")
  fi
  if [ -n "$note" ]; then
    printf 'locked %s ago (note: %s)' "$age" "$note"
  else
    printf 'locked %s ago' "$age"
  fi
}

# fm_cawldron_lock_list <state-dir>: print one
# "<project>\t<status>\t<since>\t<note>" line per lock marker under <state-dir>
# (note may be empty). <status> is "ok", or "corrupt" for a marker that exists
# but carries no since= value - a corrupt marker is still reported, never
# silently dropped, so it cannot hide from --list or session start. Silent if
# there are no markers at all.
fm_cawldron_lock_list() {
  local state=$1 f base project rc
  for f in "$state"/cawldron-lock-*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    project=${base#cawldron-lock-}
    [ -n "$project" ] || continue
    rc=0
    fm_cawldron_lock_read "$f" || rc=$?
    case "$rc" in
      0) printf '%s\tok\t%s\t%s\n' "$project" "$FM_CAWL_SINCE" "$FM_CAWL_NOTE" ;;
      *) printf '%s\tcorrupt\t\t\n' "$project" ;;
    esac
  done
}
