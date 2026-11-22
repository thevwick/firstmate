#!/usr/bin/env bash
# fm-claude-session.sh - the Claude SessionStart hook writer for a task record's
# claude_session_id (bin/fm-claude-session-lib.sh owns the field).
#
# Usage: fm-claude-session.sh record <state-dir> <task-id>   (payload on stdin)
#
# Always exits 0: a SessionStart hook that fails or blocks delays Claude's own
# startup, and a missed rewrite only leaves the previous, still-valid id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-claude-session-lib.sh
. "$SCRIPT_DIR/fm-claude-session-lib.sh"

case "${1:-}" in
  record)
    state=${2:-}
    id=${3:-}
    case "$id" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    [ -d "$state" ] || exit 0
    payload=$(cat 2>/dev/null || true)
    sid=$(fm_claude_payload_session_id "$payload") || exit 0
    fm_claude_meta_set_session "$state/$id.meta" "$sid" 30 >/dev/null 2>&1 || true
    ;;
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
    ;;
esac
exit 0
