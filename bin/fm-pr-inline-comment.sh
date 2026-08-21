#!/usr/bin/env bash
# Post a line-level inline review comment on a PR.
#
# This is the one GitHub operation gh-axi cannot perform: `gh-axi api --method
# POST --input` silently returns [] and posts nothing, which is why this wrapper
# exists rather than a gh-axi call. gh-axi remains the tool for every other
# GitHub operation - raw `gh` is NOT a general substitute for it (one `gh pr
# view` returned 22,653 bytes against gh-axi's 916).
#
# Posts to /repos/{owner}/{repo}/pulls/{n}/comments, which requires the PR's head
# commit SHA; this script resolves that itself. --side LEFT comments on a deleted
# line (the base side); the default RIGHT comments on the head side.
#
# Usage:
#   fm-pr-inline-comment.sh <pr-number-or-url> <file> <line> <body> [--side LEFT|RIGHT]
#   fm-pr-inline-comment.sh <pr> <file> <line> --body-file <path> [--side ...]
set -eu

usage() {
  cat <<'EOF'
Usage: fm-pr-inline-comment.sh <pr-number-or-url> <file> <line> <body> [options]
       fm-pr-inline-comment.sh <pr-number-or-url> <file> <line> --body-file <path> [options]

Posts a line-level inline review comment on a pull request. For a general PR
comment, or any other GitHub operation, use gh-axi instead.

Arguments:
  <pr-number-or-url>  PR number, or a full https://github.com/<o>/<r>/pull/<n> URL
  <file>              path of the file to comment on, as the PR reports it
  <line>              line number to attach the comment to
  <body>              comment text (or use --body-file)

Options:
  --side LEFT|RIGHT   RIGHT (default) comments on the head side; LEFT comments
                      on a line the PR deletes
  --body-file <path>  read the comment body from a file
  --repo <owner/repo> target repository (default: inferred from the cwd or URL)
  -h, --help          show this help

Requires `gh` authenticated for the target repository. The PR head SHA is
resolved automatically.
EOF
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

PR=""
FILE=""
LINE=""
BODY=""
BODY_SET=0
SIDE="RIGHT"
REPO=""
POSITIONAL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --side)
      [ "$#" -gt 1 ] || { echo "error: --side requires a value" >&2; exit 2; }
      SIDE=$2; shift 2 ;;
    --side=*) SIDE=${1#--side=}; shift ;;
    --body-file)
      [ "$#" -gt 1 ] || { echo "error: --body-file requires a value" >&2; exit 2; }
      [ -f "$2" ] || { echo "error: no such body file: $2" >&2; exit 2; }
      BODY=$(cat "$2"); BODY_SET=1; shift 2 ;;
    --body-file=*)
      f=${1#--body-file=}
      [ -f "$f" ] || { echo "error: no such body file: $f" >&2; exit 2; }
      BODY=$(cat "$f"); BODY_SET=1; shift ;;
    --repo)
      [ "$#" -gt 1 ] || { echo "error: --repo requires a value" >&2; exit 2; }
      REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      POSITIONAL=$((POSITIONAL + 1))
      case "$POSITIONAL" in
        1) PR=$1 ;;
        2) FILE=$1 ;;
        3) LINE=$1 ;;
        4) BODY=$1; BODY_SET=1 ;;
        *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
      esac
      shift ;;
  esac
done

[ -n "$PR" ] || { echo "error: a PR number or URL is required" >&2; exit 2; }
[ -n "$FILE" ] || { echo "error: a file path is required" >&2; exit 2; }
[ -n "$LINE" ] || { echo "error: a line number is required" >&2; exit 2; }
[ "$BODY_SET" -eq 1 ] || { echo "error: a comment body is required (positional or --body-file)" >&2; exit 2; }
[ -n "$BODY" ] || { echo "error: the comment body is empty" >&2; exit 2; }

case "$LINE" in
  ''|*[!0-9]*) echo "error: line must be a positive integer: $LINE" >&2; exit 2 ;;
esac
case "$SIDE" in
  LEFT|RIGHT) ;;
  *) echo "error: --side must be LEFT or RIGHT, got: $SIDE" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "error: gh is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

# Accept a full PR URL, which also carries the repo when the cwd is elsewhere.
case "$PR" in
  *"/pull/"*)
    URLREPO=${PR#*github.com/}
    URLREPO=${URLREPO%%/pull/*}
    [ -n "$REPO" ] || REPO=$URLREPO
    PR=${PR##*/pull/}
    PR=${PR%%[!0-9]*}
    ;;
esac
case "$PR" in
  ''|*[!0-9]*) echo "error: cannot parse a PR number from the first argument" >&2; exit 2 ;;
esac

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [ -n "$REPO" ] || { echo "error: cannot determine the repository; pass --repo <owner/repo>" >&2; exit 2; }
fi

HEAD_SHA=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)
[ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "null" ] \
  || { echo "error: cannot resolve the head SHA for $REPO#$PR" >&2; exit 2; }

PAYLOAD=$(jq -nc \
  --arg body "$BODY" \
  --arg commit_id "$HEAD_SHA" \
  --arg path "$FILE" \
  --arg side "$SIDE" \
  --argjson line "$LINE" \
  '{body: $body, commit_id: $commit_id, path: $path, line: $line, side: $side}')

RESPONSE=$(printf '%s' "$PAYLOAD" | gh api "repos/$REPO/pulls/$PR/comments" \
  --method POST --input - 2>&1) || {
  echo "error: posting the inline comment failed:" >&2
  printf '%s\n' "$RESPONSE" >&2
  exit 1
}

URL=$(printf '%s' "$RESPONSE" | jq -r '.html_url // empty' 2>/dev/null || true)
if [ -n "$URL" ]; then
  echo "$URL"
else
  echo "warning: comment posted but no URL returned; response follows" >&2
  printf '%s\n' "$RESPONSE" >&2
fi
