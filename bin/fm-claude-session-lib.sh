#!/usr/bin/env bash
# fm-claude-session-lib.sh - single owner of a Claude worker's durable conversation
# identity: a task record's `claude_session_id=` field, the primary's
# state/primary-claude-session record, and the transcript lookups behind a resume.
#
# Contract:
#   - bin/fm-spawn.sh mints the id (`claude --session-id`) and records it; the
#     SessionStart hook (bin/fm-claude-session.sh record) rewrites it when a pane
#     starts a new conversation, under the meta lock with a bounded wait.
#   - A transcript lives at <config-root>/projects/<cwd-slug>/<id>.jsonl, and
#     `claude --resume <id>` continues it under the same id.
#   - state/primary-claude-session holds session_id, cwd, launch_flags (`?` when
#     they could not be captured safely), rex_session, rex_block, recorded_at.
#   - A record with no id is matched to the newest transcript in its launch
#     directory that names the task id and postdates its spawn: a heuristic the
#     caller reports, never a licence to resume a session absent from disk.

FM_CLAUDE_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_claude_uuid_valid() {  # <session-id>
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

fm_claude_mint_session_id() {
  local id
  id=$(uuidgen 2>/dev/null | tr 'A-F' 'a-f') || id=
  if ! fm_claude_uuid_valid "$id" && [ -r /proc/sys/kernel/random/uuid ]; then
    id=$(tr 'A-F' 'a-f' </proc/sys/kernel/random/uuid)
  fi
  fm_claude_uuid_valid "$id" || return 1
  printf '%s' "$id"
}

# Claude names a project's transcript directory after its launch directory with
# every non-alphanumeric byte replaced by `-`.
fm_claude_project_slug() {  # <cwd>
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'
}

# The config roots a worker's transcripts can live under, most specific first.
fm_claude_config_roots() {
  local root seen=
  for root in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
    [ -n "$root" ] && [ -d "$root/projects" ] || continue
    case "$seen" in *"|$root|"*) continue ;; esac
    seen="$seen|$root|"
    printf '%s\n' "$root"
  done
}

fm_claude_transcript_path() {  # <cwd> <session-id>
  local cwd=$1 sid=$2 slug root
  fm_claude_uuid_valid "$sid" || return 1
  slug=$(fm_claude_project_slug "$cwd")
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ -f "$root/projects/$slug/$sid.jsonl" ]; then
      printf '%s' "$root/projects/$slug/$sid.jsonl"
      return 0
    fi
  done <<EOF
$(fm_claude_config_roots)
EOF
  return 1
}

# Prints "<session-id>\t<transcript>" for the newest transcript under <cwd>
# that names <needle> and was modified at or after <min-epoch>.
fm_claude_match_transcript() {  # <cwd> <needle> [min-epoch]
  local cwd=$1 needle=$2 min=${3:-0} slug root file mtime best="" best_mtime=-1 sid
  [ -n "$needle" ] || return 1
  slug=$(fm_claude_project_slug "$cwd")
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/projects/$slug" ] || continue
    for file in "$root/projects/$slug"/*.jsonl; do
      [ -f "$file" ] || continue
      sid=$(basename "$file" .jsonl)
      fm_claude_uuid_valid "$sid" || continue
      mtime=$(fm_claude_mtime "$file") || continue
      [ "$mtime" -ge "$min" ] || continue
      [ "$mtime" -gt "$best_mtime" ] || continue
      grep -qF -- "$needle" "$file" 2>/dev/null || continue
      best=$file
      best_mtime=$mtime
    done
  done <<EOF
$(fm_claude_config_roots)
EOF
  [ -n "$best" ] || return 1
  printf '%s\t%s' "$(basename "$best" .jsonl)" "$best"
}

fm_claude_mtime() {  # <path>
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# The epoch a task record was spawned at, from its spawn_gen (s<epoch>.<pid>.<n>).
fm_claude_spawn_epoch() {  # <meta>
  local gen
  gen=$(sed -n 's/^spawn_gen=s\([0-9][0-9]*\)\..*/\1/p' "$1" 2>/dev/null | tail -1)
  printf '%s' "${gen:-0}"
}

# The session id a SessionStart hook payload names, or nothing.
fm_claude_payload_session_id() {  # <json-payload>
  local sid
  if command -v jq >/dev/null 2>&1; then
    sid=$(printf '%s' "$1" | jq -r '.session_id // empty' 2>/dev/null) || sid=
  else
    sid=$(printf '%s' "$1" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([0-9a-f-]*\)".*/\1/p' | head -1)
  fi
  fm_claude_uuid_valid "$sid" || return 1
  printf '%s' "$sid"
}

fm_claude_session_require_locks() {
  declare -F fm_meta_lock_path >/dev/null 2>&1 && declare -F fm_lock_try_acquire >/dev/null 2>&1 \
    && declare -F fm_backlog_atomic_transition >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_CLAUDE_SESSION_LIB_DIR/fm-wake-lib.sh" || return 1
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$FM_CLAUDE_SESSION_LIB_DIR/fm-tasks-axi-lib.sh" || return 1
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$FM_CLAUDE_SESSION_LIB_DIR/fm-backlog-transition-lib.sh" || return 1
}

# 0 when the record holds <session-id> afterwards, 1 on failure, 2 when the meta
# lock stayed busy for <attempts> tries of 0.1s.
fm_claude_meta_set_session() {  # <meta> <session-id> [attempts]
  local meta=$1 sid=$2 attempts=${3:-50} state lock tmp line i=0 status=0
  fm_claude_uuid_valid "$sid" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_claude_meta_value "$meta" claude_session_id)" != "$sid" ] || return 0
  fm_claude_session_require_locks || return 1
  state=${meta%/*}
  lock=$(fm_meta_lock_path "$meta") || return 1
  until fm_lock_try_acquire "$lock"; do
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] || return 2
    sleep 0.1
  done
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    fm_lock_release "$lock" || true
    return 1
  fi
  tmp=$(mktemp "$state/.${meta##*/}.session.XXXXXX") || { fm_lock_release "$lock" || true; return 1; }
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in claude_session_id=*) ;; *) printf '%s\n' "$line" ;; esac
    done <"$meta"
    printf 'claude_session_id=%s\n' "$sid"
  } >"$tmp" || status=1
  if [ "$status" -eq 0 ] && ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$state"; then
    status=1
  fi
  [ "$status" -eq 0 ] || rm -f "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

fm_claude_meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

# The owning claude process's launch flags minus session selection; 1 when no
# claude ancestor exists, 2 when a token is not plain enough to retype safely.
fm_claude_ancestor_flags() {  # <start-pid>
  local pid=$1 i=0 cmd comm out="" tok skip=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$i" -lt 8 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    case "${comm##*/}" in
      claude)
        cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null) || return 1
        set -f
        # shellcheck disable=SC2086  # word splitting is the point; quoted args are refused below
        set -- $cmd
        set +f
        shift
        for tok in "$@"; do
          if [ "$skip" = 1 ]; then skip=0; continue; fi
          case "$tok" in
            --continue|-c|--fork-session) continue ;;
            --resume|-r|--session-id) skip=1; continue ;;
            --resume=*|--session-id=*) continue ;;
          esac
          printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9._/=:@%+,-]+$' || return 2
          out="$out${out:+ }$tok"
        done
        printf '%s' "$out"
        return 0
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    i=$((i + 1))
  done
  return 1
}

# Records the primary session for <state-dir> from a Claude SessionStart payload.
fm_claude_primary_record() {  # <state-dir> <json-payload> [start-pid]
  local state=$1 payload=$2 start=${3:-$PPID} sid cwd flags='' tmp
  sid=$(fm_claude_payload_session_id "$payload") || return 1
  [ -d "$state" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || cwd=
  fi
  [ -n "${cwd:-}" ] || cwd=$(pwd -P)
  flags=$(fm_claude_ancestor_flags "$start") || case $? in 2) flags='?' ;; *) return 1 ;; esac
  tmp=$(mktemp "$state/.primary-claude-session.XXXXXX") || return 1
  {
    printf 'session_id=%s\n' "$sid"
    printf 'cwd=%s\n' "$cwd"
    printf 'launch_flags=%s\n' "$flags"
    printf 'rex_session=%s\n' "${REX_SESSION:-}"
    printf 'rex_block=%s\n' "${REX_BLOCK:-}"
    printf 'recorded_at=%s\n' "$(date +%s)"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$state/primary-claude-session" || { rm -f "$tmp"; return 1; }
}
