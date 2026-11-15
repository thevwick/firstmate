#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Single owner of the standing kind: a persistent agent the captain talks to
# directly, which keeps a secondmate's isolated home, parent channel, pending-reply
# guard, and liveness relaunch, and does its own hands-on work in exactly one
# durably leased project worktree.
#
# Declaration. A standing home carries the gitignored .fm-standing-home record.
# The fm-standing-home.v1 record contains exactly one schema, id, project, and
# absolute worktree. Unknown fields are reserved for forward-compatible
# additions. Duplicate known fields, a malformed value, a NUL-bearing record, and
# a symlinked record fail to parse. bin/fm-home-seed.sh publishes it after
# .fm-secondmate-parent and before .fm-secondmate-home, so the identity marker
# stays the seed-completion point. bin/fm-spawn.sh copies standing=1 and the
# worktree into the parent's task record on every launch of that home.
#
# Kind branches. A standing agent is recorded kind=secondmate, so every
# kind=secondmate branch - liveness relaunch, parent-channel resolution and
# publishers, the pending-reply guard, inheritance and sync, restart, scan
# exclusions, capacity, stow cascade, and fleet views - applies to it unchanged,
# and no missed branch can drop one. Only these branches test the declaration:
#   bin/fm-brief.sh --standing        the standing charter wording
#   bin/fm-home-seed.sh --standing    local-only admission and the worktree lease
#   bin/fm-spawn.sh                   the worktree grant; no spawn from a standing home
#   bin/fm-teardown.sh                captain-only retirement; worktree landed check and return
#   bin/fm-backlog-handoff.sh         no routed backlog of other agents' work
#   bin/fm-pr-merge.sh, bin/fm-merge-local.sh   no merge authority in a standing home
# A gate asks whether the record EXISTS, never whether it parses, so a damaged
# record still counts as standing and keeps every refusal in force.

FM_STANDING_RECORD=".fm-standing-home"
FM_STANDING_SCHEMA="fm-standing-home.v1"

fm_standing_record_parse() {  # <record-file>
  local file=$1 line schema='' id='' project='' worktree=''
  local schema_count=0 id_count=0 project_count=0 worktree_count=0

  FM_STANDING_ID=
  FM_STANDING_PROJECT=
  FM_STANDING_WORKTREE=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*) schema_count=$((schema_count + 1)); schema=${line#schema=} ;;
      id=*) id_count=$((id_count + 1)); id=${line#id=} ;;
      project=*) project_count=$((project_count + 1)); project=${line#project=} ;;
      worktree=*) worktree_count=$((worktree_count + 1)); worktree=${line#worktree=} ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] && [ "$id_count" -eq 1 ] || return 1
  [ "$project_count" -eq 1 ] && [ "$worktree_count" -eq 1 ] || return 1
  [ "$schema" = "$FM_STANDING_SCHEMA" ] || return 1
  [ -n "$id" ] && [ -n "$project" ] || return 1
  case "$project" in */* | . | ..) return 1 ;; esac
  case "$worktree" in /?*) ;; *) return 1 ;; esac

  FM_STANDING_ID=$id
  FM_STANDING_PROJECT=$project
  FM_STANDING_WORKTREE=$worktree
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

fm_standing_record_write() {  # <home> <id> <project> <worktree>
  local home=$1 tmp
  tmp="$home/$FM_STANDING_RECORD.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_STANDING_SCHEMA"
    printf 'id=%s\n' "$2"
    printf 'project=%s\n' "$3"
    printf 'worktree=%s\n' "$4"
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
