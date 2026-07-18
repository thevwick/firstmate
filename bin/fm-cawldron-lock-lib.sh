# shellcheck shell=bash
# fm-cawldron-lock-lib.sh - shared marker mechanics for the Cawldron coordination
# lock (bin/fm-cawldron-lock.sh).
#
# ONE owner for the marker path, its "since=<epoch>[, note=<text>]" format, and
# age formatting, so fm-cawldron-lock.sh (writer), fm-spawn.sh (spawn gate
# reader), and fm-bootstrap.sh (session-start detect line reader) cannot drift
# on the file format.
#
# Sourced by the three callers above. No side effects on source. set -u / set -e
# safe. Depends on nothing else in bin/.

# fm_cawldron_lock_path <state-dir> <project>: print the marker path for
# <project> under <state-dir>. Does not check existence.
fm_cawldron_lock_path() {
  printf '%s/cawldron-lock-%s\n' "$1" "$2"
}

# fm_cawldron_lock_read <marker-path>: 0 and populates FM_CAWL_SINCE /
# FM_CAWL_NOTE (FM_CAWL_NOTE empty if the marker carries no note) if the marker
# exists and has a since= value; 1 otherwise (absent, or malformed with no
# since=). A note value may itself contain '=' - the read below assigns every
# character after the first '=' to the value, so that is preserved intact.
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
  [ -n "$FM_CAWL_SINCE" ] || return 1
  return 0
}

# fm_cawldron_lock_write <marker-path> <since-epoch> [<note>]: write the marker,
# overwriting any prior content. Omits the note= line when <note> is empty.
fm_cawldron_lock_write() {
  local path=$1 since=$2 note=${3:-}
  {
    printf 'since=%s\n' "$since"
    [ -z "$note" ] || printf 'note=%s\n' "$note"
  } > "$path"
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

# fm_cawldron_lock_list <state-dir>: print one "<project>\t<since>\t<note>" line
# per active lock marker under <state-dir> (note may be empty). Silent if none.
fm_cawldron_lock_list() {
  local state=$1 f base project
  for f in "$state"/cawldron-lock-*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    project=${base#cawldron-lock-}
    fm_cawldron_lock_read "$f" || continue
    printf '%s\t%s\t%s\n' "$project" "$FM_CAWL_SINCE" "$FM_CAWL_NOTE"
  done
}
