#!/usr/bin/env bash
# fm-comment-check.sh - deterministic auditor for firstmate's comment standard.
#
# The standard: at most --max lines per comment block, no comment where the code
# is self-evident, rationale in the commit message rather than the source. Marker
# and constraint comments (TODO/FIXME/HACK/XXX/NOTE, ordering, invariant, sparse
# index, API contract) are load-bearing and are never cuttable.
#
# Output tiers:
#   MUST GO  - a comment block over the budget, or one that restates its code.
#   JUSTIFY  - every other added comment, for a human to approve or cut.
#   KEEP     - marker/constraint comments, reported so a trim pass cannot
#              mistake them for cuttable. Never MUST GO even when over budget.
#
# Blocks are measured as the file READS, by walking up and down from each added
# line, so a stack of individually-legal pieces that assemble into an essay is
# still caught. Only a GENUINE licence/copyright or shebang-adjacent header is
# exempt, judged by content from the file itself - position alone would let any
# essay bypass the budget by sitting at line 1 of a new file.
# Every touched file is scanned whole, not only its changed lines.
#
# Exit status: non-zero when MUST GO is non-empty, zero otherwise.
#
# Base selection: comments already on the base are classified pre-existing and
# filtered out. For a stacked PR the base MUST be the PR's own base, not the
# immediate parent branch, or your own earlier commits read as pre-existing and
# become invisible. Resolve it with:
#   gh api repos/<owner>/<repo>/pulls/<n> --jq .base.ref
set -u

MAX=2
BASE=""
HEAD_REF=""
REPO="."
ADDED_ONLY=0
STAGED=0

usage() {
  cat <<'EOF'
Usage: fm-comment-check.sh [--base <ref>] [--head <ref>] [--repo <path>]
                           [--max <n>] [--added-only] [--staged]

Audits comments introduced between <base> and <head> against firstmate's comment
standard and reports them in three tiers.

  --base <ref>    base ref to compare against (default: origin/HEAD, else main)
  --head <ref>    head ref to audit (default: the working tree)
  --repo <path>   repository to audit (default: .)
  --max <n>       maximum lines per comment block (default: 2)
  --added-only    report only comments on added lines, skipping whole-file scan
  --staged        audit the staged changes against HEAD (for a commit gate)

Tiers:
  MUST GO   over the line budget, or restating the code it sits above.
  JUSTIFY   every other added comment; approve it or cut it.
  KEEP      marker and constraint comments; load-bearing, never cut.

Exits non-zero when MUST GO is non-empty.

BASE SELECTION - anything already on the base is treated as pre-existing and
filtered out. When auditing a stacked PR, the base must be the PR's OWN base,
not the immediate parent branch, or your earlier commits on the stack read as
pre-existing and become invisible. Resolve the real base with:

  gh api repos/<owner>/<repo>/pulls/<n> --jq .base.ref
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) [ "$#" -gt 1 ] || { echo "error: --base requires a value" >&2; exit 2; }; BASE=$2; shift 2 ;;
    --base=*) BASE=${1#--base=}; shift ;;
    --head) [ "$#" -gt 1 ] || { echo "error: --head requires a value" >&2; exit 2; }; HEAD_REF=$2; shift 2 ;;
    --head=*) HEAD_REF=${1#--head=}; shift ;;
    --repo) [ "$#" -gt 1 ] || { echo "error: --repo requires a value" >&2; exit 2; }; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --max) [ "$#" -gt 1 ] || { echo "error: --max requires a value" >&2; exit 2; }; MAX=$2; shift 2 ;;
    --max=*) MAX=${1#--max=}; shift ;;
    --added-only) ADDED_ONLY=1; shift ;;
    --staged) STAGED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MAX" in
  ''|*[!0-9]*) echo "error: --max must be a non-negative integer" >&2; exit 2 ;;
esac

[ -d "$REPO" ] || { echo "error: no such repo: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository: $REPO" >&2; exit 2; }

command -v awk >/dev/null 2>&1 || { echo "error: awk is required" >&2; exit 2; }

resolve_default_base() {
  local ref b
  ref=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s' "$ref"; return 0; fi
  for b in origin/main origin/master main master; do
    if git -C "$REPO" rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1; then
      printf '%s' "$b"; return 0
    fi
  done
  return 1
}

if [ "$STAGED" -eq 1 ]; then
  [ -n "$BASE" ] || BASE=HEAD
  [ -z "$HEAD_REF" ] || { echo "error: --staged cannot be combined with --head" >&2; exit 2; }
else
  if [ -z "$BASE" ]; then
    BASE=$(resolve_default_base) || { echo "error: cannot determine a base; pass --base" >&2; exit 2; }
  fi
fi

git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
  || { echo "error: base does not resolve: $BASE" >&2; exit 2; }
if [ -n "$HEAD_REF" ]; then
  git -C "$REPO" rev-parse --verify --quiet "$HEAD_REF^{commit}" >/dev/null 2>&1 \
    || { echo "error: head does not resolve: $HEAD_REF" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-comment-check.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

# Changed files and their added line numbers on the head side. -U0 keeps the
# hunk headers minimal; added line numbers come from the hunk arithmetic.
if [ "$STAGED" -eq 1 ]; then
  git -C "$REPO" diff --cached --no-color --no-ext-diff --no-prefix -U0 --diff-filter=d -- > "$TMP/diff" 2>/dev/null || true
elif [ -n "$HEAD_REF" ]; then
  git -C "$REPO" diff --no-color --no-ext-diff --no-prefix -U0 --diff-filter=d "$BASE...$HEAD_REF" -- > "$TMP/diff" 2>/dev/null || true
else
  git -C "$REPO" diff --no-color --no-ext-diff --no-prefix -U0 --diff-filter=d "$BASE" -- > "$TMP/diff" 2>/dev/null || true
fi

awk '
  /^\+\+\+ / {
    path = substr($0, 5)
    if (path == "/dev/null") { path = ""; next }
    sub(/^b\//, "", path)
    next
  }
  /^@@ / {
    if (path == "") next
    # @@ -a,b +c,d @@
    plus = $3
    sub(/^\+/, "", plus)
    n = split(plus, parts, ",")
    start = parts[1] + 0
    count = (n > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print path "\t" (start + i)
    next
  }
' "$TMP/diff" > "$TMP/added" || true

cut -f1 "$TMP/added" | sort -u > "$TMP/files"

if [ ! -s "$TMP/files" ]; then
  echo "no changed files vs $BASE"
  exit 0
fi

# Extracted in bulk: a per-file `git show` costs two subprocesses each and does
# not finish on a large branch (951 files).
mkdir -p "$TMP/head" "$TMP/base"
if [ "$STAGED" -eq 1 ]; then
  git -C "$REPO" checkout-index --prefix="$TMP/head/" -a 2>/dev/null || true
elif [ -n "$HEAD_REF" ]; then
  git -C "$REPO" archive --format=tar "$HEAD_REF" 2>/dev/null | tar -x -C "$TMP/head" -f - 2>/dev/null || true
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO/$f" ] || continue
    mkdir -p "$TMP/head/$(dirname "$f")" 2>/dev/null || continue
    cat "$REPO/$f" > "$TMP/head/$f" 2>/dev/null || true
  done < "$TMP/files"
fi
git -C "$REPO" archive --format=tar "$BASE" 2>/dev/null | tar -x -C "$TMP/base" -f - 2>/dev/null || true

AWK_LIB=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/fm-comment-check.awk
[ -f "$AWK_LIB" ] || { echo "error: missing analyzer: $AWK_LIB" >&2; exit 2; }

# LC_ALL=C keeps awk byte-oriented: comment syntax is pure ASCII, and a real
# source file carrying a non-UTF-8 byte otherwise aborts the analyzer outright.
LC_ALL=C awk -v max="$MAX" -v addedonly="$ADDED_ONLY" -v tmp="$TMP" -f "$AWK_LIB" \
  "$TMP/files" > "$TMP/report" 2>"$TMP/err"
RC=$?
if [ "$RC" -ne 0 ] && [ -s "$TMP/err" ]; then
  cat "$TMP/err" >&2
  exit 2
fi

MUSTGO=$(awk -F'\t' '$1=="MUSTGO"' "$TMP/report" | wc -l | tr -d ' ')
JUSTIFY=$(awk -F'\t' '$1=="JUSTIFY"' "$TMP/report" | wc -l | tr -d ' ')
KEEP=$(awk -F'\t' '$1=="KEEP"' "$TMP/report" | wc -l | tr -d ' ')

print_tier() {
  local tier=$1 label=$2 note=$3
  awk -F'\t' -v t="$tier" '$1==t' "$TMP/report" > "$TMP/tier" || true
  [ -s "$TMP/tier" ] || return 0
  echo "$label"
  [ -z "$note" ] || echo "  $note"
  while IFS=$'\t' read -r _ file line lines reason text; do
    printf '  %s:%s  (%s line(s)) %s\n' "$file" "$line" "$lines" "$reason"
    printf '      %s\n' "$text"
  done < "$TMP/tier"
  echo
}

echo "comment audit: base $BASE, max $MAX line(s) per block"
echo
print_tier MUSTGO "MUST GO ($MUSTGO):" "over the line budget, or restating the code."
print_tier JUSTIFY "JUSTIFY ($JUSTIFY):" "approve each of these explicitly, or cut it."
print_tier KEEP "KEEP ($KEEP):" "marker or constraint comments; load-bearing, do not cut."

if [ "$MUSTGO" -gt 0 ]; then
  echo "result: $MUSTGO comment(s) must go, $JUSTIFY to justify, $KEEP to keep."
  exit 1
fi
echo "result: no comments must go; $JUSTIFY to justify, $KEEP to keep."
exit 0
