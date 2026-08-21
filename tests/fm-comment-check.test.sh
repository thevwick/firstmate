#!/usr/bin/env bash
# Tests for the comment-standard guard: bin/fm-comment-check.sh and its
# PreToolUse commit gate bin/fm-comment-pretool-check.sh.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CHECK="$ROOT/bin/fm-comment-check.sh"
HOOK="$ROOT/bin/fm-comment-pretool-check.sh"
INLINE="$ROOT/bin/fm-pr-inline-comment.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
no() { FAIL=$((FAIL + 1)); echo "NOT OK - $1"; }

check() {
  local desc=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then ok "$desc"; else no "$desc (want $want, got $got)"; fi
}

contains() {
  local desc=$1 needle=$2 hay=$3
  case "$hay" in
    *"$needle"*) ok "$desc" ;;
    *) no "$desc (missing: $needle)" ;;
  esac
}

lacks() {
  local desc=$1 needle=$2 hay=$3
  case "$hay" in
    *"$needle"*) no "$desc (unexpectedly present: $needle)" ;;
    *) ok "$desc" ;;
  esac
}

newrepo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/fm-comment-test.XXXXXX")
  git -C "$d" init -q .
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  printf 'export const x = 1;\n' > "$d/a.ts"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf '%s' "$d"
}

HASH_BANNER=$(printf '%s\n%s\n%s\n%s' \
  '# a four line banner of ordinary descriptive text' \
  '# that runs past the two-line budget and states' \
  '# nothing load-bearing, used to check whether the' \
  '# header exemption applies to this file or not')

hookcall() {
  local repo=$1 cmd=$2
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$repo" \
    | "$HOOK" --claude 2>&1
}

# --- basic contract ---------------------------------------------------------

for s in "$CHECK" "$HOOK" "$INLINE"; do
  if [ -x "$s" ]; then ok "executable: $(basename "$s")"; else no "executable: $(basename "$s")"; fi
  "$s" --help >/dev/null 2>&1
  check "--help exits 0: $(basename "$s")" 0 $?
done

contains "--help documents the stacked-PR base trap" \
  "gh api repos/<owner>/<repo>/pulls/<n> --jq .base.ref" "$("$CHECK" --help 2>&1)"

# --- MUST GO: over the line budget -----------------------------------------

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// The wallet screen renders a list of cards
// and this paragraph explains at length why
// the design ended up this way, which really
// belongs in the commit message instead.
export function f() { return 2; }
EOF
git -C "$R" add -A && git -C "$R" commit -qm essay
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "essay block exits non-zero" 1 "$RC"
contains "essay block is MUST GO" "MUST GO (1)" "$OUT"
contains "essay block names file:line" "a.ts:3" "$OUT"
rm -rf "$R"

# --- the assemble-an-essay case --------------------------------------------

# Two legal 2-line pieces form one 4-line block; per-hunk measurement misses it.

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// a short remark about the wallet list
// that stays inside the two-line budget
export function f() { return 2; }
EOF
git -C "$R" add -A && git -C "$R" commit -qm piece1
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// a short remark about the wallet list
// that stays inside the two-line budget
// plus a second remark of ordinary prose
// making four contiguous lines of comment
export function f() { return 2; }
EOF
git -C "$R" add -A && git -C "$R" commit -qm piece2

# The second commit adds only 2 comment lines, so a hunk-only auditor passes it;
# measuring as the file reads must charge the whole 4-line block, from any base.
OUT=$(git -C "$R" diff -U0 HEAD~1 HEAD -- | grep -c '^+.*//')
check "second commit adds only 2 comment lines" 2 "$OUT"

OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "assembled block flagged even from the latest commit" 1 "$RC"
contains "assembled block measured as 4 lines from HEAD~1" "(4 line(s))" "$OUT"

OUT=$("$CHECK" --repo "$R" --base HEAD~2 2>&1); RC=$?
check "assembled 4-line block exits non-zero" 1 "$RC"
contains "assembled block is MUST GO" "MUST GO (1)" "$OUT"
contains "assembled block measured as 4 lines" "(4 line(s))" "$OUT"
rm -rf "$R"

# --- KEEP: markers and constraints are never MUST GO ------------------------

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// TODO: the hardcoded sort will cause issues
// once the list grows past a single page and
// the caller starts paginating through it in
// more than one request, which it soon will.
export const y = 2;

// The queue must be drained before the activity row is written,
// or the GSI7 sparse index misses the record entirely.
export const z = 3;
EOF
git -C "$R" add -A && git -C "$R" commit -qm markers
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "marker and constraint blocks exit 0" 0 "$RC"
lacks "over-budget TODO is not MUST GO" "MUST GO (1)" "$OUT"
contains "markers reported as KEEP" "KEEP (2)" "$OUT"
contains "TODO is in the KEEP tier" "TODO" "$OUT"
contains "ordering constraint is in the KEEP tier" "must be drained before" "$OUT"
rm -rf "$R"

# --- KEEP must never mask an over-budget non-marker block -------------------

# Prose using first/after/always with no marker token must still be MUST GO.

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// The first line of this paragraph explains the
// design at length, and after that it keeps going
// with more prose that is always just narrative
// and carries nothing a reader could not deduce.
export function f() { return 2; }
EOF
git -C "$R" add -A && git -C "$R" commit -qm prose
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "prose with first/after/always exits non-zero" 1 "$RC"
contains "prose with common words is MUST GO" "MUST GO (1)" "$OUT"
lacks "prose with common words is not KEEP" "KEEP (" "$OUT"
rm -rf "$R"

# Bare common words must not reach KEEP on their own, one word at a time.
for word in order before after first last already until once must never always "safe to" otherwise; do
  R=$(newrepo)
  {
    echo 'export const x = 1;'
    echo
    echo "// a four line paragraph of ordinary narrative prose"
    echo "// that happens to contain the word $word somewhere in"
    echo "// it, while stating no constraint of any kind at all,"
    echo "// and so must be charged against the comment budget."
    echo 'export function f() { return 2; }'
  } > "$R/a.ts"
  git -C "$R" add -A && git -C "$R" commit -qm "word-$word"
  OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
  check "bare word '$word' does not earn KEEP" 1 "$RC"
  rm -rf "$R"
done

# Genuine constraint phrasing still earns KEEP even over budget.
R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// An edit saves as a new row in the same series, so the row it
// replaces is only safe to remove once the replacement has landed.
// A failure here leaves the superseded row hidden behind the new
// one rather than failing the save the worker just made.
export const y = 2;

// The queue must be drained before the activity row is written,
// or the GSI7 sparse index misses the record entirely.
export const z = 3;

// Do not reorder: the attachment upload must come before the photo
// record is written, or the record points at nothing.
export const w = 4;
EOF
git -C "$R" add -A && git -C "$R" commit -qm constraints
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "genuine constraints exit 0 even over budget" 0 "$RC"
contains "all three constraints are KEEP" "KEEP (3)" "$OUT"
lacks "no constraint is MUST GO" "MUST GO" "$OUT"
rm -rf "$R"

# --- JUSTIFY: every other added comment ------------------------------------

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// A short remark that is neither an essay nor a marker.
export const y = 2;
EOF
git -C "$R" add -A && git -C "$R" commit -qm justify
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "a legal ordinary comment exits 0" 0 "$RC"
contains "ordinary comment is JUSTIFY" "JUSTIFY (1)" "$OUT"
rm -rf "$R"

# --- header exemption, measured from the file, not diff position ------------

R=$(mktemp -d "${TMPDIR:-/tmp}/fm-comment-test.XXXXXX")
git -C "$R" init -q .
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
printf 'export const placeholder = 0;\n' > "$R/keep.ts"
git -C "$R" add -A && git -C "$R" commit -qm base
cat > "$R/hdr.ts" <<'EOF'
// hdr.ts - a file header block that runs well past two lines,
// describing the module's purpose the way a header legitimately
// does, and which must not be charged against the comment budget
// even though every one of its lines is newly added.
export const q = 1;
EOF
git -C "$R" add -A && git -C "$R" commit -qm header
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "a new file's header block exits 0" 0 "$RC"
lacks "header block is not MUST GO" "MUST GO" "$OUT"
rm -rf "$R"

# --- the header exemption must not become a bypass -------------------------
# Position alone must not exempt a block. A new file's line 1 is exactly where
# an essay gets written, so exempting any top-of-file comment let the gate be
# bypassed by moving the essay upwards.

R=$(newrepo)
cat > "$R/b.ts" <<'EOF'
// This paragraph of ordinary narrative prose sits
// at the very top of a brand new file, where it is
// the natural place to write it, and it carries
// nothing a reader could not deduce from the code.
export const y = 2;
EOF
git -C "$R" add -A
OUT=$("$CHECK" --repo "$R" --staged --added-only 2>&1); RC=$?
check "essay at line 1 of a new staged file exits non-zero" 1 "$RC"
contains "essay at line 1 is MUST GO" "MUST GO (1)" "$OUT"
contains "essay at line 1 is named at b.ts:1" "b.ts:1" "$OUT"

# The enforcement path the gate actually runs.
OUT=$(hookcall "$R" "git commit -m wip"); RC=$?
check "pretool hook blocks a line-1 essay in a new file" 2 "$RC"
contains "hook deny names b.ts:1" "b.ts:1" "$OUT"

# The identical block lower in the file must behave the same way.
cat > "$R/b.ts" <<'EOF'
export const z = 0;

// This paragraph of ordinary narrative prose sits
// at the very top of a brand new file, where it is
// the natural place to write it, and it carries
// nothing a reader could not deduce from the code.
export const y = 2;
EOF
git -C "$R" add -A
OUT=$("$CHECK" --repo "$R" --staged --added-only 2>&1); RC=$?
check "same block at line 3 exits non-zero too" 1 "$RC"
rm -rf "$R"

# A genuine licence/copyright header stays exempt.
R=$(newrepo)
cat > "$R/lic.ts" <<'EOF'
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Example Pty Ltd. All rights reserved.
// Licensed under the Apache License, Version 2.0; you may not
// use this file except in compliance with the License.
export const y = 2;
EOF
git -C "$R" add -A
OUT=$("$CHECK" --repo "$R" --staged --added-only 2>&1); RC=$?
check "an SPDX/copyright licence header stays exempt" 0 "$RC"
lacks "licence header is not MUST GO" "MUST GO" "$OUT"
OUT=$(hookcall "$R" "git commit -m wip"); RC=$?
check "pretool hook allows a licence header" 0 "$RC"
rm -rf "$R"

# A script banner directly under a shebang stays exempt (firstmate's own style).
R=$(newrepo)
{ echo '#!/usr/bin/env bash'
  printf '%s\n' "$HASH_BANNER"
  echo 'echo hi'; } > "$R/s2.sh"
git -C "$R" add -A
OUT=$("$CHECK" --repo "$R" --staged --added-only 2>&1); RC=$?
check "a shebang-adjacent script banner stays exempt" 0 "$RC"
rm -rf "$R"

# ... but a shebang-less file gets no such pass for plain prose.
R=$(newrepo)
{ printf '%s\n' "$HASH_BANNER"
  echo 'echo hi'; } > "$R/p2.sh"
git -C "$R" add -A
OUT=$("$CHECK" --repo "$R" --staged --added-only 2>&1); RC=$?
check "prose at line 1 with no shebang is MUST GO" 1 "$RC"
rm -rf "$R"

# A dash in prose must not fake a "file.ext - purpose" banner.
R=$(newrepo)
cat > "$R/d.ts" <<'EOF'
// wallet - this is not really a file banner but a
// paragraph of narrative prose that keeps going on
// for four lines with nothing load-bearing in it
// at all, so the budget must still be enforced.
export const y = 2;
EOF
git -C "$R" add -A
OUT=$("$CHECK" --repo "$R" --staged --added-only 2>&1); RC=$?
check "a dash in prose does not fake a file banner" 1 "$RC"
rm -rf "$R"

# --- pre-existing comments are filtered out --------------------------------

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// An essay that already existed on the base and
// therefore is not this change's doing at all, so
// it must not be charged to this branch even though
// the file itself is touched by the change.
export const y = 2;
EOF
git -C "$R" add -A && git -C "$R" commit -qm preexisting
BASEREF=$(git -C "$R" rev-parse HEAD)
printf 'export const later = 3;\n' >> "$R/a.ts"
git -C "$R" add -A && git -C "$R" commit -qm unrelated
OUT=$("$CHECK" --repo "$R" --base "$BASEREF" 2>&1); RC=$?
check "pre-existing essay is not charged to this change" 0 "$RC"
lacks "pre-existing essay absent from MUST GO" "MUST GO" "$OUT"
rm -rf "$R"

# --- shell and python detection -------------------------------------------

R=$(newrepo)
# Emitted at runtime rather than written literally: an over-budget hash-comment
# fixture sitting in this file would be flagged in firstmate's own commit gate.
HASH_ESSAY=$(printf '%s\n%s\n%s\n%s\n' \
  '# a paragraph about the value below that runs' \
  '# past the two-line budget with nothing in it' \
  '# a reader could not get from the code, and so' \
  '# should be reported as cuttable prose')
# shellcheck disable=SC2016  # the fixture needs this text literally, unexpanded
{ echo '#!/usr/bin/env bash'; echo 'code_line=1'; printf '%s\n' "$HASH_ESSAY"; echo 'echo "$code_line"'; } > "$R/s.sh"
{ echo 'value = 1'; printf '%s\n' "$HASH_ESSAY"; echo 'print(value)'; } > "$R/p.py"
git -C "$R" add -A && git -C "$R" commit -qm langs
OUT=$("$CHECK" --repo "$R" --base HEAD~1 2>&1); RC=$?
check "shell and python essays exit non-zero" 1 "$RC"
contains "shell essay flagged" "s.sh:" "$OUT"
contains "python essay flagged" "p.py:" "$OUT"
rm -rf "$R"

# --- the PreToolUse commit gate -------------------------------------------

R=$(newrepo)
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// a staged comment paragraph of five lines
// of ordinary prose about this function and
// its history, carrying nothing load-bearing
// in its wording, which the commit gate is
// expected to report as cuttable prose
export function f() { return 2; }
EOF
git -C "$R" add -A
OUT=$(hookcall "$R" "git commit -m wip"); RC=$?
check "gate blocks a commit carrying a 5-line block" 2 "$RC"
contains "deny is Claude-shaped" '"permissionDecision":"deny"' "$OUT"
contains "deny names the offending file:line" "a.ts:3" "$OUT"

git -C "$R" reset -q
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// Two lines is the budget, and this
// comment stays inside it.
export function f() { return 2; }
EOF
git -C "$R" add -A
OUT=$(hookcall "$R" "git commit -m wip"); RC=$?
check "gate allows a clean commit" 0 "$RC"
check "gate is silent on allow" "" "$OUT"

git -C "$R" reset -q
cat > "$R/a.ts" <<'EOF'
export const x = 1;

// TODO: this marker block runs past the budget
// on purpose, because a marker is load-bearing
// and the gate must never block a commit for
// carrying one, however long it happens to be.
export function f() { return 2; }
EOF
git -C "$R" add -A
OUT=$(hookcall "$R" "git commit -m wip"); RC=$?
check "gate allows an over-budget marker block" 0 "$RC"

OUT=$(hookcall "$R" "ls -la"); RC=$?
check "gate ignores a non-commit command" 0 "$RC"

OUT=$(printf '%s' 'not json at all' | "$HOOK" --claude 2>&1); RC=$?
check "gate fails open on malformed stdin" 0 "$RC"

OUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | "$HOOK" --claude 2>&1); RC=$?
check "gate ignores a non-Bash tool" 0 "$RC"
rm -rf "$R"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
