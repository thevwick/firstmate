#!/usr/bin/env bash
# PreToolUse transport that gates `git commit` on firstmate's comment standard.
#
# Instructions alone do not hold this rule across a long session, so the gate
# lives in the tool path. bin/fm-comment-check.sh is the sole owner of the
# standard, tiering, and block measurement; this wrapper only acquires the
# harness payload, decides whether the command is a commit, runs the checker
# against the staged tree, and renders the harness-shaped response.
#
# NOT a Stop/turn-end hook: a turn-end hook fires on firstmate's own turns and
# only after the code is already committed. NOT a git hook either: a git hook in
# a linked worktree resolves to the shared common dir and leaks into the primary
# checkout. PreToolUse on the commit is the correct gate.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-comment-pretool-check.sh --claude
#   bin/fm-comment-pretool-check.sh --command '<cmd>' [--repo <path>]
#
# Exit/output contract, matching bin/fm-arm-pretool-check.sh:
#   ALLOW     - exit 0 and no output.
#   DENY      - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#               deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq, a missing or failing
#               checker, or a non-repo cwd. A commit is never blocked because
#               the hook itself could not run.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
REPO=""

usage() {
  cat <<'EOF'
Usage: fm-comment-pretool-check.sh [--command <cmd>] [--repo <path>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Blocks a `git commit` whose staged changes carry a MUST GO comment block; allows
everything else silently.
Exits 0 to allow and 2 to deny, with the deny reason on stderr and a Grok
decision object on stdout unless --claude is supplied.
Malformed transport and an unavailable checker fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2; CMD_SET=1; shift 2 ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --repo)
      [ "$#" -gt 1 ] || { echo "error: --repo requires a value" >&2; exit 2; }
      REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.toolName // .tool_name // empty)' 2>/dev/null) || exit 0
  case "$TOOL" in
    ''|Bash|bash) ;;
    *) exit 0 ;;
  esac
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
  [ -n "$REPO" ] || REPO=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty)' 2>/dev/null) || REPO=""
fi

[ -n "$CMD" ] || exit 0
[ -n "$REPO" ] || REPO=$PWD

# Prefilter only; stripping these bytes can never destroy a real `git commit`,
# so a command that still cannot contain one is safe to fast-allow.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/ }
PREFILTER=${PREFILTER//$'\r'/ }
case "$PREFILTER" in
  *commit*) ;;
  *) exit 0 ;;
esac
case "$PREFILTER" in
  *git*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
CHECKER="$SCRIPT_DIR/fm-comment-check.sh"
[ -x "$CHECKER" ] || exit 0
[ -d "$REPO" ] || exit 0
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Audit the staged tree; with nothing staged there is nothing to judge, so allow.
# `git commit -a` still stages tracked edits, so check the worktree for that case.
if [ -z "$(git -C "$REPO" diff --cached --name-only 2>/dev/null)" ]; then
  case "$PREFILTER" in
    *" -a"*|*" --all"*|*-am*)
      git -C "$REPO" diff --name-only --quiet 2>/dev/null && exit 0 ;;
    *) exit 0 ;;
  esac
fi

REPORT=$("$CHECKER" --repo "$REPO" --staged --added-only 2>/dev/null) || CHECK_RC=$?
CHECK_RC=${CHECK_RC:-0}
[ "$CHECK_RC" -eq 1 ] || exit 0

OFFENDERS=$(printf '%s\n' "$REPORT" | awk '
  /^MUST GO/ { inblock = 1; next }
  /^(JUSTIFY|KEEP|result:)/ { inblock = 0 }
  inblock && /^  [^ ]+:[0-9]+/ { gsub(/^[ \t]+/, ""); print $1; }
' | paste -sd' ' - | sed 's/[[:space:]]*$//')
[ -n "$OFFENDERS" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[comment-standard] Commit blocked: comment block(s) over the 2-line budget at $OFFENDERS. Two lines maximum per comment block, none where the code is self-evident, rationale in the commit message instead. Cut or shorten them and commit again. Markers (TODO/FIXME/HACK/XXX/NOTE) and ordering, invariant, sparse-index, or API-contract notes are load-bearing - never cut those; run bin/fm-comment-check.sh --staged --added-only for the full tiered report."
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
