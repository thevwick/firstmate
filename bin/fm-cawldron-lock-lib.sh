# shellcheck shell=bash
# fm-cawldron-lock-lib.sh - shared marker mechanics for the Cawldron coordination
# lock (bin/fm-cawldron-lock.sh).
#
# ONE owner for the marker path, its "since=<epoch>[, note=<text>]" format, age
# formatting, the human rendering of a lock (banner rule plus the shared
# "locked <age> ago[ (note: <text>)]" detail), and the ship-crew refusal gate
# itself (fm_cawldron_gate), so fm-cawldron-lock.sh (writer), fm-spawn.sh and
# fm-promote.sh (gate callers), and fm-bootstrap.sh (session-start detect line
# reader) cannot drift on the file format, the locked/unlocked test, or the
# wording.
#
# A marker that exists but carries no usable since= value - absent, empty, or
# not a non-negative integer - is CORRUPT, not absent: a truncated, interrupted,
# or garbled write must never silently disarm the spawn gate, so readers surface
# it and treat it as locked.
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
#   0 - the marker exists and carries a usable since= epoch (locked)
#   1 - no marker at all (unlocked)
#   2 - the marker exists but its since= value is missing or not a non-negative
#       integer (CORRUPT; still locked)
# Callers must distinguish 1 from 2: only 1 means "not locked". The digit check
# matters beyond diagnostics: fm_cawldron_lock_age_human feeds since= to shell
# arithmetic, which would otherwise dereference (and for a value like
# 'x[$(cmd)]' evaluate) a non-numeric value instead of rendering an age. A note
# value may itself contain '=' - the read below assigns every character after
# the first '=' to the value, so that is preserved intact.
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
  case "$FM_CAWL_SINCE" in
    '' | *[!0-9]*) return 2 ;;
  esac
  return 0
}

# fm_cawldron_lock_write <marker-path> <since-epoch> [<note>]: write the marker,
# overwriting any prior content. Omits the note= line when <note> is empty.
# Writes to a temp sibling and renames, so an interrupted or out-of-space write
# can never leave a truncated marker in place of a good one. The temp is also
# removed on INT/TERM/HUP, so an interrupt between the redirect and the rename
# leaves no stray temp behind either. Any INT/TERM/HUP handler the caller had
# installed is saved and restored rather than reset to the default, so this
# helper never silently disarms a caller's own cleanup.
fm_cawldron_lock_write() {
  local path=$1 since=$2 note=${3:-} tmp prior rc=0
  # Dot-prefixed so the in-flight temp never matches fm_cawldron_lock_list's
  # cawldron-lock-* glob.
  tmp="$(dirname "$path")/.cawldron-lock-tmp.$$"
  prior=$(trap -p INT TERM HUP)
  # printf %q so a state-dir path containing quotes or spaces still yields a
  # well-formed trap command.
  # shellcheck disable=SC2064
  trap "rm -f $(printf '%q' "$tmp")" INT TERM HUP
  {
    printf 'since=%s\n' "$since"
    [ -z "$note" ] || printf 'note=%s\n' "$note"
  } > "$tmp" && mv -f "$tmp" "$path" || rc=1
  trap - INT TERM HUP
  [ -z "$prior" ] || eval "$prior"
  [ "$rc" -eq 0 ] || rm -f "$tmp"
  return "$rc"
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
    printf 'LOCKED but the marker is unreadable (missing or invalid since= value; truncated or corrupt write) - treat as locked and re-set or clear it with bin/fm-cawldron-lock.sh'
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

# fm_cawldron_gate <state-dir> <project> <force-flag> <action>: the shared
# ship-crew refusal gate. <project> may be a bare name or an absolute project
# path (it is basenamed). <action> is a short context phrase - "spawn",
# "promote" - naming what is being gated, and appears in the banner, the
# override warning, and the refusal message. Returns
#   0 - not locked, or locked but <force-flag> is non-zero (warning emitted)
#   1 - locked and not overridden; the bordered banner and refusal line are
#       already on stderr, so the caller only has to stop
# Only a missing marker (rc 1 from fm_cawldron_lock_read) means unlocked: an
# unreadable marker (rc 2 - truncated or corrupt write) is still a lock, because
# a damaged state file must never silently disarm this gate. This lives here, in
# the marker's one owner, so fm-spawn.sh and fm-promote.sh cannot drift on the
# locked/unlocked test or the wording.
fm_cawldron_gate() {
  local state=$1 proj_name marker rc detail force=$3 action=$4
  proj_name=$(basename "$2")
  marker=$(fm_cawldron_lock_path "$state" "$proj_name")
  rc=0
  fm_cawldron_lock_read "$marker" || rc=$?
  [ "$rc" -ne 1 ] || return 0
  if [ "$rc" -eq 0 ]; then
    detail=$(fm_cawldron_lock_detail ok "$FM_CAWL_SINCE" "$FM_CAWL_NOTE")
  else
    detail=$(fm_cawldron_lock_detail corrupt '' '')
  fi
  # An override is the one case a later collision with the captain's unlanded
  # live edits most needs a trace, and nothing is recorded in state/<id>.meta -
  # so say so on the way past.
  if [ "$force" -ne 0 ]; then
    echo "warning: $proj_name is Cawldron-locked ($detail); continuing this $action anyway per --force-locked" >&2
    return 0
  fi
  {
    printf '●%s\n' "$FM_CAWLDRON_RULE"
    printf '●  CAWLDRON LOCK ACTIVE - %s\n' "$proj_name"
    printf '●  %s\n' "$detail"
    printf "●  This %s may collide with the captain's unlanded live Cawldron edits.\n" "$action"
    printf '●  Pass --force-locked (or set FM_SPAWN_FORCE_LOCKED=1) to continue anyway.\n'
    printf '●%s\n' "$FM_CAWLDRON_RULE"
  } >&2
  echo "error: $action refused: $proj_name is Cawldron-locked ($detail); pass --force-locked to override" >&2
  return 1
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
