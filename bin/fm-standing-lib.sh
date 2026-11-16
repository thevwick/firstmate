#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Single owner of the standing kind: a persistent agent the captain talks to
# directly, which keeps a secondmate's isolated home, parent channel, pending-reply
# guard, and liveness relaunch, and does its own hands-on work in one durably
# leased worktree per project it was seeded with.
#
# Declaration. A standing home carries the gitignored .fm-standing-home record.
# The fm-standing-home.v2 record contains exactly one schema and id, and one or
# more project/absolute-worktree pairs: the Nth worktree= line belongs to the
# Nth project= line. A v1 record is the same with exactly one pair; it is still
# read, and rewritten as v2 only when a re-seed changes its pairs. Unknown
# fields are reserved for forward-compatible additions. A duplicate schema or
# id, unequal pair counts, a repeated project or worktree, a malformed value, a
# NUL-bearing record, and a symlinked record fail to parse. bin/fm-home-seed.sh
# publishes it after .fm-secondmate-parent and before .fm-secondmate-home, so
# the identity marker stays the seed-completion point. bin/fm-spawn.sh copies
# the worktrees into the parent's task record on every launch of that home:
# standing=1 and standing_worktree=<first>, exactly as a one-project home has
# always been stamped, plus one standing_extra_worktree=<path> line per further
# worktree, so a reader of the first field alone still reads a real worktree.
#
# Kind branches. A standing agent is recorded kind=secondmate, so every
# kind=secondmate branch - liveness relaunch, parent-channel resolution and
# publishers, the pending-reply guard, inheritance and sync, restart, scan
# exclusions, capacity, stow cascade, and fleet views - applies to it unchanged,
# and no missed branch can drop one. Only these branches test the declaration:
#   bin/fm-brief.sh --standing        the standing charter wording
#   bin/fm-home-seed.sh --standing    local-only admission and the worktree leases
#   bin/fm-spawn.sh                   the worktree grants; no spawn from a standing home
#   bin/fm-teardown.sh                captain-only retirement; worktree landed checks and returns
#   bin/fm-reclaim-slots.sh           every stamped worktree is held
#   bin/fm-backlog-handoff.sh         no routed backlog of other agents' work
#   bin/fm-pr-merge.sh, bin/fm-merge-local.sh   no merge authority in a standing home
# A gate asks whether the record EXISTS, never whether it parses, so a damaged
# record still counts as standing and keeps every refusal in force.

FM_STANDING_RECORD=".fm-standing-home"
FM_STANDING_SCHEMA="fm-standing-home.v2"
FM_STANDING_SCHEMA_V1="fm-standing-home.v1"

# Sets FM_STANDING_ID, FM_STANDING_SCHEMA_READ, the FM_STANDING_PROJECTS and
# FM_STANDING_WORKTREES arrays, and the first pair as FM_STANDING_PROJECT/WORKTREE.
fm_standing_record_parse() {  # <record-file>
  local file=$1 line schema='' id='' schema_count=0 id_count=0 i j n
  local projects=() worktrees=()

  FM_STANDING_ID=
  FM_STANDING_SCHEMA_READ=
  FM_STANDING_PROJECT=
  FM_STANDING_WORKTREE=
  FM_STANDING_PROJECTS=()
  FM_STANDING_WORKTREES=()

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*) schema_count=$((schema_count + 1)); schema=${line#schema=} ;;
      id=*) id_count=$((id_count + 1)); id=${line#id=} ;;
      project=*) projects+=("${line#project=}") ;;
      worktree=*) worktrees+=("${line#worktree=}") ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] && [ "$id_count" -eq 1 ] || return 1
  n=${#projects[@]}
  [ "$n" -ge 1 ] && [ "${#worktrees[@]}" -eq "$n" ] || return 1
  case "$schema" in
    "$FM_STANDING_SCHEMA") ;;
    "$FM_STANDING_SCHEMA_V1") [ "$n" -eq 1 ] || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$id" ] || return 1
  for ((i = 0; i < n; i++)); do
    case "${projects[$i]}" in '' | */* | . | ..) return 1 ;; esac
    case "${worktrees[$i]}" in /?*) ;; *) return 1 ;; esac
    for ((j = 0; j < i; j++)); do
      [ "${projects[$j]}" != "${projects[$i]}" ] && [ "${worktrees[$j]}" != "${worktrees[$i]}" ] || return 1
    done
  done

  FM_STANDING_ID=$id
  FM_STANDING_SCHEMA_READ=$schema
  FM_STANDING_PROJECTS=("${projects[@]}")
  FM_STANDING_WORKTREES=("${worktrees[@]}")
  FM_STANDING_PROJECT=${projects[0]}
  FM_STANDING_WORKTREE=${worktrees[0]}
}

fm_standing_home() {  # <home>
  [ -n "${1:-}" ] || return 1
  [ -e "$1/$FM_STANDING_RECORD" ] || [ -L "$1/$FM_STANDING_RECORD" ]
}

# A parent task record names a standing agent when spawn stamped it, or when
# the home it names still carries the declaration.
fm_standing_meta() {  # <meta>
  local meta=$1 home
  [ -f "$meta" ] || return 1
  grep -qx 'standing=1' "$meta" 2>/dev/null && return 0
  home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
  fm_standing_home "$home"
}

fm_standing_record_write() {  # <home> <id> <project> <worktree> [<project> <worktree>]...
  local home=$1 id=$2 tmp
  shift 2
  [ $# -ge 2 ] && [ $(($# % 2)) -eq 0 ] || return 1
  tmp="$home/$FM_STANDING_RECORD.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_STANDING_SCHEMA"
    printf 'id=%s\n' "$id"
    while [ $# -gt 0 ]; do
      printf 'project=%s\n' "$1"
      printf 'worktree=%s\n' "$2"
      shift 2
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$home/$FM_STANDING_RECORD"
}

# A standing agent never pushes, so any local commit is unlanded until the
# captain lands it; prints the reason, or nothing when the worktree is landed.
fm_standing_worktree_unlanded() {  # <worktree>
  local wt=$1 dirty ahead
  [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'standing worktree %s is not a readable git worktree\n' "$wt"
    return 0
  }
  dirty=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) || {
    printf 'standing worktree %s status could not be read\n' "$wt"
    return 0
  }
  if [ -n "$dirty" ]; then
    printf 'standing worktree %s has uncommitted changes\n' "$wt"
    return 0
  fi
  ahead=$(git -C "$wt" rev-list --count HEAD --branches --not --remotes 2>/dev/null) || {
    printf 'standing worktree %s history could not be read\n' "$wt"
    return 0
  }
  if [ "$ahead" != 0 ]; then
    printf 'standing worktree %s has %s local commit(s) on no remote\n' "$wt" "$ahead"
  fi
}

fm_standing_refuse_in_home() {  # <home> <action>
  fm_standing_home "$1" || return 0
  printf 'error: %s refused: this is a standing home, which holds no crew, no routed backlog, and no merge authority (bin/fm-standing-lib.sh)\n' "$2" >&2
  return 1
}
