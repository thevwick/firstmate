#!/usr/bin/env bash
# fm-comment-check.sh - flag comment bloat in a crewmate branch before it reaches a PR.
#
# The captain's standing rule: two lines max per comment, none where the code is
# self-evident, rationale belongs in the commit message. Crewmates inherit no
# memory, so they violate it unless the brief says otherwise - and firstmate has
# shipped the violation to a PR more than once by reviewing for correctness and
# not for this.
#
# Usage:
#   bin/fm-comment-check.sh <base-ref> [<head-ref>]   # e.g. origin/main HEAD
#   bin/fm-comment-check.sh --id <task-id>            # resolve base/head from task meta
#
# Run from inside the repo being checked. Exits 1 when something needs a look,
# 0 when clean, so it can gate a push. Advisory: it reports, never edits.

set -uo pipefail

MAX_RUN=${FM_COMMENT_MAX_RUN:-2}          # longest allowed consecutive comment run
MAX_RATIO=${FM_COMMENT_MAX_RATIO:-15}     # percent of added lines that may be comments

# The rule is about whether a comment should exist, which no pattern can decide. Phrase
# matching let 14 lines of narration through on one diff: none of the listed phrases
# appeared and every block sat at the run limit. So every added comment is reported and
# the check fails until a reader has been through them. FM_COMMENT_ACK=1 says that
# happened and each remaining line is deliberate.
ACK=${FM_COMMENT_ACK:-0}

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -ge 1 ] || usage

if [ "$1" = "--id" ]; then
  [ $# -ge 2 ] || usage
  meta="${FM_STATE_OVERRIDE:-${FM_HOME:-$PWD}/state}/$2.meta"
  [ -f "$meta" ] || { echo "no meta for task $2" >&2; exit 2; }
  base=$(grep -m1 '^base=' "$meta" | cut -d= -f2-)
  [ -n "$base" ] || base=origin/main
  head=HEAD
else
  base=$1
  head=${2:-HEAD}
fi

git rev-parse --verify "$base" >/dev/null 2>&1 || { echo "unknown base ref: $base" >&2; exit 2; }

diff=$(git diff "$base...$head" 2>/dev/null) || { echo "cannot diff $base...$head" >&2; exit 2; }
[ -n "$diff" ] || { echo "comment-check: no changes against $base"; exit 0; }

added=$(printf '%s\n' "$diff" | grep -c '^+[^+]' || true)
comments=$(printf '%s\n' "$diff" | grep -cE '^\+[[:space:]]*(//|\*|/\*)' || true)
[ "$added" -gt 0 ] || exit 0

ratio=$(( comments * 100 / added ))
problems=0

# Long runs: consecutive added comment lines in one file. A paragraph explaining
# code that already says it is the shape the captain rejects.
printf '%s\n' "$diff" | awk -v max="$MAX_RUN" '
  /^\+\+\+ b\// { file=substr($0,7); run=0; start=0; next }
  # Bare block delimiters carry no prose, so counting them would fail a two-line JSDoc.
  /^\+[[:space:]]*(\/\*\*?|\*\/)[[:space:]]*$/ { next }
  /^\+[[:space:]]*(\/\/|\*|\/\*)/ {
    run++; if (run==1) first=$0
    next
  }
  {
    if (run > max) printf "  %s: %d consecutive comment lines\n", file, run
    run=0
  }
  END { if (run > max) printf "  %s: %d consecutive comment lines\n", file, run }
' > /tmp/fm-comment-runs.$$ 2>/dev/null

if [ -s /tmp/fm-comment-runs.$$ ]; then
  echo "comment-check: comment blocks longer than $MAX_RUN lines"
  cat /tmp/fm-comment-runs.$$
  problems=1
fi
rm -f /tmp/fm-comment-runs.$$

# Every added comment, listed. The reader judges; the script does not pretend to.
added_comments=$(printf '%s\n' "$diff" \
  | grep -nE '^\+[[:space:]]*(//|\*|/\*|#)' \
  | grep -vE ':\+[[:space:]]*(/\*\*?|\*/)[[:space:]]*$' \
  || true)

if [ -n "$added_comments" ] && [ "$ACK" != "1" ]; then
  echo "comment-check: $comments added comment line(s) - read each and cut what narrates"
  printf '%s\n' "$added_comments" | sed 's/^/  /'
  problems=1
fi

if [ "$ratio" -gt "$MAX_RATIO" ]; then
  echo "comment-check: $comments of $added added lines are comments (${ratio}%, over ${MAX_RATIO}%)"
  problems=1
fi

if [ "$problems" -eq 0 ]; then
  echo "comment-check: clean ($comments/$added added lines are comments, ${ratio}%)"
  exit 0
fi

cat <<'EOF'

The rule: two lines maximum, and none where the code is self-evident.

Every added comment is listed above, because no pattern can judge which ones earn their
place. Read each one and ask why it exists. If it is there because you were reasoning about
the problem and wrote the thought down, cut it - that belongs in the commit message. Keep a
comment only when it warns of a hazard a reader cannot see from the code: a non-obvious
ordering constraint, a platform quirk, a deliberate deviation that looks like a mistake.

A well-named function or variable removes the need for most comments. Reach for the name
first. Once every remaining line has been read and kept on purpose, re-run with
FM_COMMENT_ACK=1 to confirm.
EOF
exit 1
