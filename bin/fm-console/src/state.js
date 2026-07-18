// Pure state derivation. No I/O lives here: functions take already-read data
// (the fm-fleet-snapshot.sh --json object, file mtimes, du output) and return
// the shape the UI renders. This is what the unit tests exercise directly.
//
// The snapshot itself is the one owner of fleet parsing (bin/fm-fleet-snapshot.sh);
// the console never re-parses backlog.md or meta files. It only reshapes the
// snapshot into cards and computes a few header facts the snapshot omits
// (disk, watcher liveness, afk), which are cheap, console-local reads.

import {
  WATCHER_GRACE_SECS,
  GROUP_ORDER,
  CARD_ROW_HEIGHT,
  SECTION_ROW_CHROME,
  LAB_PHASES,
  LAB_HEARTBEAT_FRESH_SECS,
} from './constants.js';

// Extract a ticket chip from a task's branch name or brief text, if one is
// present. A ticket is OPTIONAL metadata: many tasks (e.g. poc/* work) have
// none and must render as first-class without it. The pattern is a generic
// uppercase project key plus digits (SMM-2808, DPW-11976), never a hardcoded
// project list. Returns the ticket string or null.
export function extractTicket(sources) {
  const TICKET_RE = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/;
  for (const s of sources) {
    if (!s) continue;
    const m = String(s).match(TICKET_RE);
    if (m) return m[1];
  }
  return null;
}

// Map a snapshot task's current_state + hints into one of the console's card
// groups. Ordering of checks matters: a decision or block that needs the
// captain wins over a plain working state.
export function groupForTask(task) {
  const state = task?.current_state?.state || 'unknown';
  const hints = task?.hints || {};

  if (hints.pending_decision) return 'needs-you';
  if (hints.blocked_event || state === 'blocked') return 'blocked';

  switch (state) {
    case 'needs-decision':
      return 'needs-you';
    case 'done':
    case 'passed':
    case 'checks-passed':
    case 'merged':
      return 'done';
    case 'failed':
    case 'cancelled':
      // A failure needs the captain's attention above routine working cards.
      return 'needs-you';
    case 'ready':
      return 'ready';
    case 'working':
    case 'running':
    case 'fixing':
    case 'ci':
      return 'working';
    default:
      // Unknown/absent state: surface it as working so it is visible rather
      // than hidden, but it will show its raw state string on the card.
      return 'working';
  }
}

// Map a card's group + raw state into a health level for the card's status
// dot: the primary at-a-glance "what needs me" signal. 'needs-you'/'blocked'
// map straight to red (the captain owes a decision or the crew is stuck);
// 'working'/'ready' map to green UNLESS the raw state itself says stale,
// which maps to yellow instead - groupForTask files a wedged-but-not-yet-
// escalated crew under 'working', so the raw state is what actually
// distinguishes "provably working" from "stale". 'done' and 'unknown' (and
// anything else unrecognized) map to dim grey: settled or genuinely unknown,
// never a false green or a false stale-yellow.
export function healthLevel(card) {
  const group = card?.group;
  const state = card?.stateRaw || 'unknown';
  if (group === 'needs-you' || group === 'blocked') return 'red';
  if (state === 'stale') return 'yellow';
  if (state === 'unknown') return 'grey';
  if (group === 'working' || group === 'ready') return 'green';
  return 'grey';
}

// One-line "which Claude instance" label: harness/model, with effort appended
// only when it is not the harness default. This is the headline ask - the
// captain wants to see which model+effort profile each crewmate runs without
// opening its pane. Empty harness (an older meta or a not-yet-recorded field)
// renders as null so the card can omit the chip entirely rather than show a
// blank "/ ".
export function formatProfile(harness, model, effort) {
  const h = String(harness || '').trim();
  if (!h) return null;
  const m = String(model || '').trim();
  const e = String(effort || '').trim();
  let label = m && m !== 'default' ? `${h}/${m}` : h;
  if (e && e !== 'default') label += ` ${e}`;
  return label;
}

// The crew branch, by convention fm/<id> for a ship task (AGENTS.md section
// 11's brief contract). Scout worktrees are declared scratch and never
// branch; secondmates work in their own home, not a task branch - both render
// with no branch chip.
export function branchForTask(task) {
  if (task?.kind !== 'ship') return null;
  return `fm/${task?.id}`;
}

// Build a console card from one snapshot task. Pure: du size, PR-check status,
// and crew age/last-event are threaded in from async side-channels keyed by
// task id, defaulting to null when not yet computed.
export function buildCard(task, { duBytes = null, prChecks = null, ageSecs = null, lastEventSecs = null } = {}) {
  const meta = task?.paths || {};
  const worktreePath = meta.worktree?.path || null;
  const ticket = extractTicket([task?.branch, task?.brief_excerpt, task?.id]);
  const lastEvent =
    task?.hints?.last_event_text ||
    meta.status_log?.last_event?.raw ||
    '';

  const card = {
    id: task?.id || '(unknown)',
    ticket,
    repo: shortRepo(task?.project),
    kind: task?.kind || 'ship',
    group: groupForTask(task),
    stateRaw: task?.current_state?.state || 'unknown',
    stateDetail: task?.current_state?.detail || '',
    lastEvent: String(lastEvent).trim(),
    worktreePath,
    duBytes,
    prUrl: task?.pr?.url || null,
    prChecks,
    endpointExists: task?.endpoint?.exists === true,
    harness: task?.harness || '',
    model: task?.model || '',
    effort: task?.effort || '',
    endpointTarget: task?.endpoint?.target || null,
    branch: branchForTask(task),
    ageSecs,
    lastEventSecs,
  };
  card.profile = formatProfile(card.harness, card.model, card.effort);
  card.health = healthLevel(card);
  return card;
}

// Reduce a full project path to a short repo label for the card. The snapshot
// records project as an absolute path; the captain wants the basename.
export function shortRepo(project) {
  if (!project) return '';
  const parts = String(project).replace(/\/+$/, '').split('/');
  return parts[parts.length - 1] || project;
}

// Group cards by their console group, preserving snapshot order within a group.
// Returns a Map keyed by group name.
export function groupCards(cards) {
  const groups = new Map();
  for (const card of cards) {
    if (!groups.has(card.group)) groups.set(card.group, []);
    groups.get(card.group).push(card);
  }
  return groups;
}

// Derive backlog queued/blocked counts from the snapshot's backlog records.
// A record is queued when state === 'queued'; blocked when it also carries a
// blocked_by. This mirrors data/backlog.md's structure without re-parsing it.
export function backlogCounts(snapshot) {
  const records = snapshot?.backlog?.records || [];
  let queued = 0;
  let blocked = 0;
  for (const r of records) {
    if (r?.state !== 'queued') continue;
    queued += 1;
    if (r?.blocked_by) blocked += 1;
  }
  return { queued, blocked };
}

// Decide whether the watcher is alive, from the beacon file's mtime in epoch
// seconds and the current epoch. A missing beacon (mtimeSecs null) is dead.
// Grace mirrors fm-guard.sh (WATCHER_GRACE_SECS).
export function watcherAlive(mtimeSecs, nowSecs, grace = WATCHER_GRACE_SECS) {
  if (mtimeSecs == null) return false;
  return nowSecs - mtimeSecs <= grace;
}

// Backlog records for the QUEUED board section: structured, queued records
// only, in snapshot order (already ordered as written in data/backlog.md).
export function queuedBacklogRecords(snapshot) {
  const records = snapshot?.backlog?.records || [];
  return records.filter((r) => r?.structured && r?.state === 'queued');
}

// Backlog records for the RECENT DONE board section: structured, done
// records only, most-recently-written first (data/backlog.md's Done section
// is append-order, so reversing gives most-recent-first without re-deriving
// dates). Capped by `limit` - the board shows a taste, not the whole archive.
export function recentDoneBacklogRecords(snapshot, limit = 5) {
  const records = snapshot?.backlog?.records || [];
  return records
    .filter((r) => r?.structured && r?.state === 'done')
    .slice(-limit)
    .reverse();
}

// Compute how many body rows each board section may draw, given the terminal
// height and how many rows IN FLIGHT's actual content needs. Pure and
// unit-testable on purpose: Ink has no scrolling, so handing a fixed-height
// flex tree more rows than it has space for can corrupt the render rather
// than clip it cleanly (rows losing content unpredictably, not just the last
// ones, because Yoga distributes the shortfall across the whole tree). Every
// row that will be drawn must therefore be counted here, in JS, before Ink
// ever sees it - the caller caps each section's row list to the returned
// budget.
//
// Fixed chrome subtracted from `height` before splitting: title(1) + status
// strip(1) + footer(0 or 1) + input box (2 borders + 1 message/menu/confirm
// line + input line + hint line = 5). Each of the three board sections then
// pays its own SECTION_ROW_CHROME rows of border+title chrome before the
// remainder is split into body rows.
//
// IN FLIGHT is now content-sized, not percentage-sized: it is capped at
// exactly what `inFlightContentRows` needs (plus one row of breathing room),
// so a single card never reserves the same acreage as a full board - this is
// the fix for the "half-empty box" problem. Whatever IN FLIGHT does not use
// flows to QUEUED/RECENT DONE instead of sitting empty. `inFlightContentRows`
// defaults to a generous cap when omitted (an older caller, or a caller that
// has not computed it yet) so this function never regresses to 0 rows.
export function computeRowBudget({ height, hasFooter = false, hasInFlight = false, inFlightContentRows = null }) {
  const fixedChrome = 1 + 1 + (hasFooter ? 1 : 0) + 5;
  // A board needs at least 1 body row per section on top of its own chrome to
  // render without losing content (a section handed less can lose its own
  // title row, not just body content - the Ink no-scrolling corruption this
  // function exists to prevent). Floor availableForBoard at that true
  // minimum (3 * SECTION_ROW_CHROME + 3 body rows) rather than the looser `3`
  // this used before variable per-card row heights made the floor mismatch
  // visible: a too-small terminal is a degenerate case no TUI renders
  // cleanly, but the three sections should at least agree on a consistent,
  // in-budget split instead of collectively requesting more than fits.
  const minBoardHeight = SECTION_ROW_CHROME * 3 + 3;
  const availableForBoard = Math.max(minBoardHeight, height - fixedChrome);
  const bodyBudget = availableForBoard - SECTION_ROW_CHROME * 3;

  // Reserve at most a "fair share" ceiling for IN FLIGHT so a large fleet
  // still leaves QUEUED/RECENT DONE something, then shrink that reservation
  // down to what the content actually needs (plus 1 row of margin) when the
  // content is smaller than the ceiling - freeing the rest to the bottom row.
  const fairShareCeiling = hasInFlight ? Math.round(bodyBudget * 0.6) : Math.round(bodyBudget * 0.34);
  const desiredInFlight = inFlightContentRows == null ? fairShareCeiling : inFlightContentRows + 1;
  const inFlightRows = Math.max(1, Math.min(fairShareCeiling, desiredInFlight));

  const bottomBudget = Math.max(2, bodyBudget - inFlightRows);
  const queuedRows = Math.max(1, Math.floor(bottomBudget / 2));
  const doneRows = Math.max(1, bottomBudget - queuedRows);
  return { inFlightRows, queuedRows, doneRows };
}

// Rows IN FLIGHT's actual content will draw: one label row per non-empty
// group plus CARD_ROW_HEIGHT rows per card in it. This is what lets
// computeRowBudget size the section to its content instead of a fixed share -
// a fleet with one card must not reserve the same acreage as a full board.
export function inFlightContentRowCount(grouped) {
  let rows = 0;
  for (const g of GROUP_ORDER) {
    const cards = grouped.get(g) || [];
    if (!cards.length) continue;
    rows += 1 + cards.length * CARD_ROW_HEIGHT;
  }
  return rows;
}

// Partition task cards into the three board sections the redesigned UI shows:
//   inFlight  - every card whose group is not 'done' (needs-you/ready/working/
//               blocked), sub-grouped by groupCards so the board can still
//               show state-colored rows within the section.
//   done      - card group 'done' only, most recently reported first.
// QUEUED has no task cards of its own (queued work has no meta yet); the
// caller merges in queuedBacklogRecords/recentDoneBacklogRecords for the
// backlog-derived rows that belong in QUEUED and RECENT DONE respectively.
export function boardSections(cards) {
  const inFlight = cards.filter((c) => c.group !== 'done');
  const done = cards.filter((c) => c.group === 'done');
  return { inFlight, inFlightGrouped: groupCards(inFlight), done };
}

// Pure trim/tail for the FIRSTMATE ACTIVITY panel: split a raw pane capture
// (fm-peek.sh's stdout - trailing blank rows are normal for a short-busy pane
// in a tall terminal) into a bounded list of lines, dropping trailing blanks
// and keeping at most the last `maxLines` non-trailing lines so the panel
// reads like a live tail (newest content at the bottom) rather than mostly
// whitespace. Never throws on null/empty input - an unreadable capture is the
// caller's job to report via its own error placeholder, not this function's.
export function firstmateActivityLines(rawText, maxLines) {
  if (!rawText) return [];
  const lines = String(rawText).split('\n');
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  if (maxLines == null || lines.length <= maxLines) return lines;
  return lines.slice(lines.length - maxLines);
}

// Compose the whole header model from the pieces the UI has read. inFlight is
// derived from the snapshot's tasks[] (live state/<id>.meta rows), NOT from
// the backlog's "In flight" section text, so it reflects actual live work
// even when data/backlog.md is stale, absent, or hand-edited out of sync.
export function buildHeader({
  diskFree = null,
  diskUsePct = null,
  watcherBeatSecs = null,
  nowSecs,
  afkPresent = false,
  snapshot = null,
  inFlightCount = 0,
}) {
  const counts = backlogCounts(snapshot);
  return {
    diskFree,
    diskUsePct,
    watcherAlive: watcherAlive(watcherBeatSecs, nowSecs),
    afk: afkPresent === true,
    inFlight: inFlightCount,
    queued: counts.queued,
    blocked: counts.blocked,
  };
}

// Build one MOBILE LAB card from a raw lab-build-<slot>.json read (io.js's
// readLabBuildStatuses entry: { slot, raw, parseError }), per
// data/mobile-lab-status-contract.md v1. This is the ONE place the console
// interprets that contract - every field is defaulted defensively here so a
// malformed, partial, or oddly-shaped file (the lab crew builds against the
// same contract independently; a field could be missing or the wrong type)
// renders as an "unavailable" card instead of propagating nulls/undefined
// into the UI or throwing. `nowSecs` is passed in (not read from Date.now())
// so this stays pure and unit-testable like every other function in this
// file.
export function buildLabBuildCard(entry, nowSecs) {
  const slot = entry?.slot || '(unknown)';
  if (entry?.parseError || !entry?.raw || typeof entry.raw !== 'object') {
    return {
      slot,
      available: false,
      error: entry?.parseError || 'no status file',
    };
  }

  const raw = entry.raw;
  const str = (v, fallback = null) => (typeof v === 'string' && v ? v : fallback);
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const int = (v) => {
    const n = num(v);
    return n == null ? null : Math.trunc(n);
  };

  const status = str(raw.status, 'running');
  const phase = str(raw.phase);
  const phaseIndex = int(raw.phase_index);
  const phaseTotal = int(raw.phase_total);
  let percent = num(raw.percent);
  if (percent != null) percent = Math.max(0, Math.min(100, percent));

  const updatedEpoch = num(raw.updated_epoch);
  const startedEpoch = num(raw.started_epoch);
  const phaseStartedEpoch = num(raw.phase_started_epoch);

  const ageSecs = updatedEpoch != null ? Math.max(0, nowSecs - updatedEpoch) : null;
  const totalElapsedSecs = startedEpoch != null ? Math.max(0, nowSecs - startedEpoch) : null;
  const phaseElapsedSecs = phaseStartedEpoch != null ? Math.max(0, nowSecs - phaseStartedEpoch) : null;

  // Heartbeat: 'failed' always reads red regardless of age (a failure is
  // terminal, not stale); 'success' reads green (a finished build has no
  // heartbeat to keep fresh); 'running' derives fresh/amber from updated_epoch
  // per the contract, and an unresolvable age (no updated_epoch at all)
  // degrades to amber rather than a false-fresh green.
  let heartbeat;
  if (status === 'failed') heartbeat = 'red';
  else if (status === 'success') heartbeat = 'green';
  else if (ageSecs == null) heartbeat = 'amber';
  else heartbeat = ageSecs < LAB_HEARTBEAT_FRESH_SECS ? 'green' : 'amber';

  const phaseKnown = phase != null && LAB_PHASES.includes(phase);

  return {
    slot,
    available: true,
    repo: str(raw.repo),
    branch: str(raw.branch),
    platform: str(raw.platform),
    target: str(raw.target),
    runCommand: str(raw.run_command),
    port: int(raw.port),
    phase,
    phaseKnown,
    phaseIndex,
    phaseTotal,
    percent,
    percentUnknown: percent == null,
    status,
    startedEpoch,
    updatedEpoch,
    phaseStartedEpoch,
    totalElapsedSecs,
    phaseElapsedSecs,
    ageSecs,
    message: str(raw.message, ''),
    logfile: str(raw.logfile),
    error: str(raw.error),
    heartbeat,
  };
}

// Build every MOBILE LAB card from io.js's readLabBuildStatuses output, most
// recently updated first so an actively-building slot always leads. Pure:
// `nowSecs` is threaded in rather than read internally, matching every other
// time-dependent builder in this file.
export function buildLabBuildCards(entries, nowSecs) {
  const cards = (entries || []).map((e) => buildLabBuildCard(e, nowSecs));
  return cards.sort((a, b) => {
    const au = a.updatedEpoch ?? -Infinity;
    const bu = b.updatedEpoch ?? -Infinity;
    return bu - au;
  });
}
