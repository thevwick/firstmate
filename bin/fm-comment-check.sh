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

# Reasoning notes are the failure the length thresholds miss: a two-line comment
# explaining WHY the code is the way it is passes both checks and still violates
# the rule. These phrasings are how an AI narrates its thinking - they describe
# the author's reasoning, the history, or the bug, none of which belong above a
# line of code. Tuned to flag prose, not the rare genuine hazard warning.
REASONING_RE=${FM_COMMENT_REASONING_RE:-'(so its mere|proves nothing|which is why|the reason|rationale|note that|we (need|want|must|deliberately|intentionally)|this (is|was) (because|why)|turns out|it seems|apparently|for backwards|historically|used to|previously|originally|would (otherwise|reproduce)|falls back to|in other words|that is why|explains why|keep in mind|remember that|be aware|worth noting|as (a|an) (result|aside)|avoid(s|ed)? .* because|prevents .* from|ensures? that)'}

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

# Reasoning notes: the check the length thresholds cannot make. A comment that
# explains the author's thinking is out regardless of how short it is.
reasoning=$(printf '%s\n' "$diff" \
  | grep -E '^\+[[:space:]]*(//|\*|#)' \
  | grep -inE "$REASONING_RE" \
  | head -20 || true)

if [ -n "$reasoning" ]; then
  echo "comment-check: comments that explain reasoning rather than warn of a hazard"
  printf '%s\n' "$reasoning" | sed 's/^/  /'
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

The test that matters is not length. Ask why the comment exists: if it is there
because you were reasoning about the problem and wrote the thought down, cut it -
that belongs in the commit message. Keep a comment only when it warns of a hazard
a reader cannot see from the code: a non-obvious ordering constraint, a platform
quirk, a deliberate deviation that looks like a mistake.

A well-named function or variable removes the need for most comments. Reach for
the name first.
EOF
exit 1
