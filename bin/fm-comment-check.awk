# Comment-block analyzer for fm-comment-check.sh.
#
# Reads a list of changed paths, loads each file's head and base content plus its
# added line numbers from $tmp, then walks contiguous comment runs as the FILE
# reads and emits one tab-separated record per block:
#   <tier>\t<file>\t<line>\t<lines>\t<reason>\t<text>
#
# A block spans from its first to its last comment line even when only part of it
# was added, so separately-added legal pieces that assemble into an essay are
# measured as the one block a reader sees.

function trim(s) {
  gsub(/^[ \t]+/, "", s)
  gsub(/[ \t]+$/, "", s)
  return s
}

function lang_of(path) {
  if (path ~ /\.(ts|tsx|js|jsx|mjs|cjs|swift|kt|kts|java|m|mm|h|c|cc|cpp|hpp|go|rs|scala|cs)$/) return "c"
  if (path ~ /\.(sh|bash|zsh|awk|rb|pl|toml|yml|yaml)$/) return "hash"
  if (path ~ /\.py$/) return "py"
  return ""
}

# Strip a comment line down to its prose, or return "" when the line is not a
# whole-line comment. Trailing comments on a code line are not blocks.
function comment_text(line, lang,   t) {
  t = trim(line)
  if (t == "") return ""
  if (lang == "c") {
    if (t ~ /^\/\//) { sub(/^\/\/+/, "", t); return trim(t) }
    if (t ~ /^\/\*/) { sub(/^\/\*+/, "", t); sub(/\*\/[ \t]*$/, "", t); return trim(t) }
    if (t ~ /^\*/ && !(t ~ /^\*\//)) { sub(/^\*+/, "", t); return trim(t) }
    if (t ~ /^\*\//) return trim("")
    return ""
  }
  if (lang == "hash" || lang == "py") {
    if (t ~ /^#!/) return ""
    if (t ~ /^#/) { sub(/^#+/, "", t); return trim(t) }
    return ""
  }
  return ""
}

function is_comment_line(line, lang,   t) {
  t = trim(line)
  if (t == "") return 0
  if (lang == "c") return (t ~ /^\/\// || t ~ /^\/\*/ || t ~ /^\*/)
  if (lang == "hash" || lang == "py") return (t ~ /^#/ && !(t ~ /^#!/))
  return 0
}

# Deliberately NARROW: KEEP bypasses the budget, so a bare common word never
# qualifies - it counts only inside a phrase stating an actual constraint.
function is_marker(text,   t) {
  if (text ~ /(^|[^A-Za-z])(TODO|FIXME|HACK|XXX|NOTE|WARNING|CAUTION|SAFETY|IMPORTANT)([^A-Za-z]|$)/) return 1
  # Caps BEFORE/AFTER/ORDER are an author shouting about sequencing.
  if (text ~ /(^|[^A-Za-z])(BEFORE|AFTER|ORDER|MUST|NEVER|ALWAYS)([^A-Za-z]|$)/) return 1
  t = tolower(text)
  # Explicit ordering constraints, not the words "before"/"after" alone.
  if (t ~ /do not reorder|don't reorder|order matters|ordering matters|keep this order|in this order/) return 1
  if (t ~ /must (run|come|happen|be called|be set|be written|be drained|precede|follow)/) return 1
  if (t ~ /must (be|stay|remain) (before|after|first|last)/) return 1
  if (t ~ /(before|after) (the|this|any|it|that|every) [a-z]+ (is|are|has|have|runs|lands|writes)/) return 1
  if (t ~ /only safe (to|once|after)|not safe (to|until)|safe to (remove|delete|drop) (once|after)/) return 1
  # Invariants and concurrency hazards.
  if (t ~ /invariant|idempoten|must not|never (call|mutate|reorder|remove|delete|assume)/) return 1
  if (t ~ /race condition|data race|deadlock|livelock|atomic(ally)?|thread-safe|not thread/) return 1
  # Storage and index conditions.
  if (t ~ /sparse (index|gsi)|gsi[0-9]|partial index|covering index|index only/) return 1
  # Non-obvious external contracts, named as such.
  if (t ~ /api contract|wire format|upstream bug|bug in [a-z]|workaround for|undocumented|quirk/) return 1
  if (t ~ /eslint-disable|ts-ignore|ts-expect-error|shellcheck disable|noqa|pragma/) return 1
  # A discriminator between two paths that look alike is load-bearing: losing it
  # is how a retry gets mistaken for an edit.
  if (t ~ /tells? (an?|the) [a-z]+ from|distinguish(es)? (an?|the)|discriminat/) return 1
  return 0
}

# A comment that restates the code it sits above adds nothing a reader lacks.
function restates(text, nextline,   t, n) {
  t = tolower(trim(text))
  n = tolower(trim(nextline))
  if (t == "" || n == "") return 0
  if (t ~ /^(set|get|return|call|create|delete|update|add|remove|initiali[sz]e|increment|decrement|loop over|iterate|check if|assign|declare|define|import|export|log)\b/) {
    gsub(/[^a-z0-9]+/, " ", t)
    gsub(/[^a-z0-9]+/, " ", n)
    split(t, tw, " ")
    hits = 0; total = 0
    for (i in tw) {
      if (length(tw[i]) < 4) continue
      total++
      if (index(n, tw[i]) > 0) hits++
    }
    if (total > 0 && hits * 2 >= total) return 1
  }
  return 0
}

# A file's header/licence block: a comment run starting at the file's first
# non-blank, non-shebang line. Identified from the file itself, never from diff
# position, because a -U0 diff carries no context lines.
function header_end(nlines, lang,   i, start) {
  start = 0
  for (i = 1; i <= nlines; i++) {
    if (trim(head[i]) == "") continue
    if (i == 1 && head[i] ~ /^#!/) continue
    if (trim(head[i]) ~ /^#!/) continue
    start = i
    break
  }
  if (start == 0) return 0
  if (!is_comment_line(head[start], lang)) return 0
  for (i = start; i <= nlines; i++) {
    if (!is_comment_line(head[i], lang)) return i - 1
  }
  return nlines
}

BEGIN {
  FS = "\n"
  # Loaded ONCE, keyed "<path>\t<line>": re-reading per file is quadratic and
  # does not finish on a large branch (951 files against 136k added lines).
  af = tmp "/added"
  while ((getline ln < af) > 0) addedidx[ln] = 1
  close(af)
}

{
  path = $0
  if (path == "") next
  lang = lang_of(path)
  if (lang == "") next

  delete head; delete basetext
  nlines = 0
  hf = tmp "/head/" path
  while ((getline ln < hf) > 0) { nlines++; head[nlines] = ln }
  close(hf)
  if (nlines == 0) next

  bf = tmp "/base/" path
  while ((getline ln < bf) > 0) { basetext[trim(ln)] = 1 }
  close(bf)

  hend = header_end(nlines, lang)

  i = 1
  while (i <= nlines) {
    if (!is_comment_line(head[i], lang)) { i++; continue }
    bstart = i
    j = i
    while (j <= nlines && is_comment_line(head[j], lang)) j++
    bend = j - 1
    i = j

    if (bstart <= hend) continue

    # Only report a block that the change actually introduced.
    hasadded = 0
    for (k = bstart; k <= bend; k++) if ((path "\t" k) in addedidx) hasadded = 1
    if (!hasadded) continue

    # Collapse the block's prose, and drop it when every line already existed
    # verbatim on the base.
    text = ""; nnew = 0; nprose = 0
    for (k = bstart; k <= bend; k++) {
      ct = comment_text(head[k], lang)
      if (ct != "") {
        nprose++
        text = (text == "") ? ct : text " " ct
        if (!(trim(head[k]) in basetext)) nnew++
      }
    }
    if (nprose == 0) continue
    if (nnew == 0) continue
    if (addedonly) {
      anyaddedprose = 0
      for (k = bstart; k <= bend; k++) if ((path "\t" k) in addedidx && comment_text(head[k], lang) != "") anyaddedprose = 1
      if (!anyaddedprose) continue
    }

    lines = bend - bstart + 1
    if (length(text) > 160) text = substr(text, 1, 157) "..."

    nextcode = ""
    for (k = bend + 1; k <= nlines; k++) {
      if (trim(head[k]) != "") { nextcode = head[k]; break }
    }

    if (is_marker(text)) {
      printf "KEEP\t%s\t%d\t%d\t%s\t%s\n", path, bstart, lines, "marker or constraint; load-bearing", text
    } else if (lines > max) {
      printf "MUSTGO\t%s\t%d\t%d\t%s\t%s\n", path, bstart, lines, "block exceeds " max "-line budget", text
    } else if (restates(text, nextcode)) {
      printf "MUSTGO\t%s\t%d\t%d\t%s\t%s\n", path, bstart, lines, "restates the code below it", text
    } else {
      printf "JUSTIFY\t%s\t%d\t%d\t%s\t%s\n", path, bstart, lines, "justify or cut", text
    }
  }
}
