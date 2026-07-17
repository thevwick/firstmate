// The Ink app. Written with React.createElement (aliased `h`) rather than JSX
// so the package syncs as plain source with no build/transpile step, matching
// the rest of firstmate's bin/ tooling.
//
// Layout, top to bottom, designed to fill the whole terminal:
//   1. Title bar - "FIRSTMATE" branding + the operating home.
//   2. Status strip - one compact line: disk, watcher dot, afk, in-flight,
//      queued/blocked counts. No prose here, ever.
//   3. Board - fills all remaining height. IN FLIGHT, QUEUED, RECENT DONE.
//      IN FLIGHT sizes to its own content (a fixed height) whenever that
//      content is smaller than its fair share, rather than always stretching
//      to fill the row - a single card must not reserve acres of blank space
//      below it. Whatever it does not use, and all of it when IN FLIGHT is
//      empty, flows to QUEUED/RECENT DONE instead of sitting idle.
//   4. Footer - one line, only present when something needs a warning
//      (watcher down, bridge disabled, a snapshot read error).
//   5. Input line - pinned at the bottom.
//
// Responsibilities: poll firstmate state on REFRESH_INTERVAL_MS and redraw;
// recompute per-worktree du on the slower DU_INTERVAL_MS without blocking a
// redraw; route composed/typed commands to the primary session via the
// bridge. All approval gates stay with firstmate - the input only DELIVERS
// text.

import React from 'react';
import { Box, Text, useApp, useInput, useStdout } from 'ink';
import Spinner from 'ink-spinner';
import Gradient from 'ink-gradient';
import figures from 'figures';

import {
  REFRESH_INTERVAL_MS,
  DU_INTERVAL_MS,
  DATA_VOLUME,
  GROUP_ORDER,
  GROUP_LABELS,
  RECENT_DONE_LIMIT,
  MIN_ROWS_FOR_FULL_LAYOUT,
  MIN_COLS_FOR_FULL_LAYOUT,
  CARD_ROW_HEIGHT,
  CARD_NARROW_WIDTH,
  CARD_VERY_NARROW_WIDTH,
  HEALTH_COLORS,
  SECTION_ROW_CHROME,
  FIRSTMATE_ACTIVITY_CAPTURE_LINES,
  FIRSTMATE_ACTIVITY_STRIP_ROWS,
  CLAUDE_ACCENT,
  OTHER_HARNESS_ACCENT,
  CLAUDE_MARK,
  OTHER_HARNESS_MARK,
} from './constants.js';
import {
  buildCard,
  buildHeader,
  boardSections,
  queuedBacklogRecords,
  recentDoneBacklogRecords,
  computeRowBudget,
  inFlightContentRowCount,
  firstmateActivityLines,
} from './state.js';
import {
  QUICK_ACTIONS,
  actionForKey,
  composeQuickAction,
  isSendable,
  normalizeCommand,
} from './commands.js';
import { humanBytes, humanDuration, truncate } from './format.js';
import {
  readSnapshot,
  readDisk,
  readWorktreeSize,
  readPrChecks,
  readFirstmateActivity,
  fileMtimeSecs,
  fileExists,
} from './io.js';
import { resolveSupervisor, sendCommand } from './bridge.js';

const h = React.createElement;
const { useState, useEffect, useRef, useCallback, useMemo } = React;

// Group-header color, used only for the NEEDS YOU/READY/WORKING/BLOCKED
// section labels inside IN FLIGHT - distinct from a card's own HEALTH_COLORS
// accent (constants.js), which drives the per-card border stripe and badge.
const GROUP_COLORS = {
  'needs-you': 'red',
  ready: 'green',
  working: 'cyan',
  blocked: 'yellow',
  done: 'gray',
};

// Per-state icon glyph (figures, terminal-safe with ASCII fallbacks) shown in
// a card's badge ahead of its state text - the captain reads shape+color
// before parsing the word. Keyed by the same board group badgeText() already
// resolves to a label for, plus a dedicated STALE entry since badgeText can
// override the label independent of group (see badgeText below).
const STATE_ICON = {
  'needs-you': figures.warning,
  ready: figures.tick,
  working: figures.play,
  blocked: figures.circleDotted,
  done: figures.tick,
  STALE: figures.pointerSmall,
};

// Minimum terminal width for the gradient FIRSTMATE wordmark to keep its
// breathing room; below it TitleBar falls back to a plain bold anchor glyph +
// text so the banner never crowds the operating-home path off a narrow line.
const BANNER_MIN_WIDTH = 54;

const BRAND = 'magentaBright';

function nowSecs() {
  return Math.floor(Date.now() / 1000);
}

// Title bar: gradient FIRSTMATE wordmark + operating home, one line. Degrades
// to a plain bold anchor glyph below BANNER_MIN_WIDTH so a narrow terminal
// never loses the home path to banner decoration.
//
// ink-big-text is deliberately NOT used for this banner: cfonts (the library
// it wraps) measures its own idea of terminal width to decide where to wrap,
// and that measurement is unreliable outside a real interactive TTY (it
// under-detects and silently hard-wraps mid-glyph) - verified this corrupts a
// multi-row block-font render (glyph rows split/duplicated) even when an
// explicit oversized width is passed to cfonts directly, bypassing
// ink-big-text entirely. ink-gradient applied to a short, ordinary Text line
// has none of that risk (it measures actual rendered content, not a second
// ambient guess), so the gradient wordmark below is the banner in every
// terminal size instead of an unreliable "sometimes bigger" flourish.
function TitleBar({ home, width }) {
  const wordmark =
    width >= BANNER_MIN_WIDTH
      ? h(Gradient, { name: 'passion' }, h(Text, { bold: true, wrap: 'truncate-end' }, '⚓ FIRSTMATE'))
      : h(Text, { bold: true, color: BRAND, wrap: 'truncate-end' }, '⚓ FIRSTMATE');
  return h(
    Box,
    { justifyContent: 'space-between', paddingX: 1, flexWrap: 'nowrap' },
    h(
      Box,
      { flexWrap: 'nowrap' },
      wordmark,
      h(Text, { dimColor: true, wrap: 'truncate-end' }, '  control console')
    ),
    h(Text, { dimColor: true, wrap: 'truncate-end' }, truncate(home, Math.max(10, width - 34)))
  );
}

// Compact single-line status strip: disk, watcher dot, afk, in-flight,
// queued/blocked. This replaces the old multi-line header prose entirely -
// nothing here should ever grow past one line. `flexWrap: 'nowrap'` plus a
// `wrap: 'truncate-end'` Text is deliberate on every segment: Ink's default
// row Box wraps overflowing children onto a second line instead of clipping,
// which silently broke the one-line contract (and the fixed board-chrome
// row-count computeRowBudget assumes) on a narrow terminal - truncating a
// segment is the correct degrade, never a second row. Segments narrow from
// least to most essential below CARD_NARROW_WIDTH: afk drops first (it is
// only ever a state flag, restated in full whenever it actually matters),
// then disk detail shrinks to just the free-space number.
function StatusStrip({ header, width }) {
  const narrow = width < CARD_NARROW_WIDTH;
  const diskText =
    header.diskFree == null
      ? 'disk ?'
      : narrow
        ? humanBytes(header.diskFree)
        : `disk ${humanBytes(header.diskFree)} free${
            header.diskUsePct == null ? '' : ` (${header.diskUsePct}%)`
          }`;
  const diskColor = header.diskUsePct != null && header.diskUsePct >= 90 ? 'red' : 'whiteBright';
  const watcherColor = header.watcherAlive ? 'greenBright' : 'redBright';
  const watcherIcon = header.watcherAlive ? figures.tick : figures.cross;

  const sep = h(Text, { dimColor: true, wrap: 'truncate-end' }, '   ');

  return h(
    Box,
    { paddingX: 1, flexWrap: 'nowrap' },
    h(Text, { color: diskColor, wrap: 'truncate-end' }, diskText),
    sep,
    h(Text, { bold: true, color: watcherColor, wrap: 'truncate-end' }, watcherIcon),
    h(Text, { color: watcherColor, wrap: 'truncate-end' }, header.watcherAlive ? ' watcher' : ' watcher down'),
    narrow ? null : sep,
    narrow
      ? null
      : h(
          Text,
          { bold: header.afk, color: header.afk ? 'yellowBright' : 'gray', wrap: 'truncate-end' },
          header.afk ? `${figures.warning} afk` : `${figures.circle} present`
        ),
    sep,
    h(
      Text,
      { bold: true, color: header.inFlight > 0 ? 'cyanBright' : 'gray', wrap: 'truncate-end' },
      `${figures.play} ${header.inFlight} in flight`
    ),
    sep,
    h(
      Text,
      { wrap: 'truncate-end' },
      `${figures.hamburger} ${header.queued} queued`,
      header.blocked ? h(Text, { bold: true, color: 'yellowBright' }, ` (${figures.circleDotted} ${header.blocked} blocked)`) : null
    )
  );
}

// Footer: one line, present only when something needs a warning. Multi-line
// prose never lives here - every active warning collapses to its shortest
// form and they are joined onto the one line rather than hiding all but the
// highest-priority one, so a real bridge problem is never masked by, say, a
// down watcher in the same render.
function Footer({ header, supervisor, snapError }) {
  const parts = [];
  if (snapError) parts.push({ text: `state read error: ${snapError}`, color: 'red' });
  if (!header.watcherAlive) parts.push({ text: 'watcher down - supervision may be stale', color: 'red' });
  if (supervisor.error) parts.push({ text: `command bridge disabled: ${supervisor.error}`, color: 'yellow' });
  if (!parts.length) return null;
  return h(
    Box,
    { paddingX: 1, flexWrap: 'nowrap' },
    ...parts.flatMap((p, i) => [
      i > 0 ? h(Text, { key: `sep-${i}`, dimColor: true, wrap: 'truncate-end' }, '  ·  ') : null,
      h(Text, { key: `w-${i}`, color: p.color, wrap: 'truncate-end' }, p.text),
    ]).filter(Boolean)
  );
}

// Short badge text for a card's state pill. Prefers the raw crew state over
// the coarser board group when the raw state is more informative - a card
// filed under the 'working' group whose raw state is 'stale' must say STALE,
// not WORKING, since a wedged-but-not-yet-escalated crew is exactly the case
// the badge exists to surface (mirrors state.js's healthLevel reasoning).
function badgeText(card) {
  if (card.stateRaw === 'stale') return 'STALE';
  return GROUP_LABELS[card.group] || String(card.stateRaw || 'working').toUpperCase();
}

// State icon shown ahead of the badge text: an animated braille spinner for a
// card that is actually WORKING (the ink-spinner requirement - the console
// should feel alive, not static, on real in-flight work), otherwise a fixed
// figures glyph per state so shape (not just color) carries the signal.
// ink-spinner's own Text has no `wrap` prop set, which - inside a nowrap
// headline row of several sibling Text nodes - can push the whole row onto a
// second physical line (Ink's no-scrolling wrap corruption every other
// component in this file guards against with `wrap: 'truncate-end'`); wrap
// its single glyph frame in a Text of our own that carries it, rather than
// rendering Spinner directly as a sibling.
function StateIcon({ card, color }) {
  const label = badgeText(card);
  if (label === 'WORKING') {
    return h(Text, { color, bold: true, wrap: 'truncate-end' }, h(Spinner, { type: 'dots' }));
  }
  const icon = label === 'STALE' ? STATE_ICON.STALE : STATE_ICON[card.group];
  return h(Text, { color, bold: true, wrap: 'truncate-end' }, icon || figures.play);
}

// Claude/harness identity chip: a warm-coral sparkle for a claude crew (the
// captain's requested Claude identity mark, since crewmates run on Claude by
// default), a neutral diamond for any other harness, so the Claude accent
// stays a meaningful signal rather than decorating every card the same way.
function HarnessMark({ harness }) {
  const isClaude = String(harness || '').trim().toLowerCase() === 'claude';
  const mark = isClaude ? CLAUDE_MARK : OTHER_HARNESS_MARK;
  const color = isClaude ? CLAUDE_ACCENT : OTHER_HARNESS_ACCENT;
  return h(Text, { color, bold: true, wrap: 'truncate-end' }, mark);
}

// One task card, colour-coded by state end to end: a left border stripe in
// the health color (the heat-map requirement - a card needing the captain
// reads red before you even parse the text), a headline row (id, then a
// colored state BADGE, then the model/effort chip), and a dim metadata row
// (size, age/last-event, branch/PR, endpoint - labeled and space-separated,
// not a run-on dot-joined sentence), narrowing by dropping fields below
// CARD_NARROW_WIDTH / CARD_VERY_NARROW_WIDTH. Exactly CARD_ROW_HEIGHT (2)
// terminal rows: Ink has no scrolling and a fixed-height flex tree that
// receives more rows than it has space for can visibly corrupt the render
// (rows silently losing content) rather than clipping cleanly, so sections
// cap their row COUNT in JS (see capRows below) instead of relying on
// Yoga/terminal overflow to hide the excess - which is why this component's
// actual row count must stay in lockstep with CARD_ROW_HEIGHT in
// constants.js. The border stripe itself costs 0 extra rows (borderTop/
// borderBottom are disabled; only the left column draws).
function Card({ card, selected, width }) {
  const healthColor = HEALTH_COLORS[card.health] || 'gray';
  const chips = card.ticket ? ` [${card.ticket}]` : '';
  const contentWidth = Math.max(6, width - 2);

  const headline = h(
    Box,
    { flexWrap: 'nowrap' },
    h(
      Text,
      { color: selected ? 'black' : 'whiteBright', backgroundColor: selected ? healthColor : undefined, bold: true, wrap: 'truncate-end' },
      ` ${card.id} `
    ),
    h(StateIcon, { card, color: healthColor }),
    h(Text, { color: healthColor, bold: true, wrap: 'truncate-end' }, ` ${badgeText(card)} `),
    chips ? h(Text, { color: 'blueBright', wrap: 'truncate-end' }, chips) : null,
    card.profile ? h(Text, { color: 'magentaBright', wrap: 'truncate-end' }, ` ${card.profile} `) : null,
    card.profile ? h(HarnessMark, { harness: card.harness }) : null,
    h(Text, { dimColor: true, wrap: 'truncate-end' }, ` ${card.repo}${card.kind !== 'ship' ? ` · ${card.kind}` : ''}`)
  );

  const metaParts = [];
  if (card.duBytes != null || width >= CARD_NARROW_WIDTH) {
    metaParts.push(card.duBytes != null ? humanBytes(card.duBytes) : '…');
  }
  const ageText = card.ageSecs != null ? humanDuration(card.ageSecs) : '…';
  metaParts.push(`age ${ageText}`);
  if (card.lastEventSecs != null) metaParts.push(`seen ${humanDuration(card.lastEventSecs)} ago`);
  if (width >= CARD_NARROW_WIDTH) {
    if (card.branch) metaParts.push(card.branch);
    if (card.prUrl) {
      const prNum = (String(card.prUrl).match(/\/pull\/(\d+)/) || [])[1];
      const prChecksText = card.prChecks ? `:${card.prChecks}` : '';
      metaParts.push(`PR${prNum ? `#${prNum}` : ''}${prChecksText}`);
    }
  }
  if (width >= CARD_VERY_NARROW_WIDTH && card.endpointTarget) {
    metaParts.push(card.endpointTarget);
  }
  const detail = card.lastEvent || card.stateDetail || '';
  if (detail) metaParts.push(detail);

  const prColor = card.prChecks === 'failing' ? 'redBright' : card.prChecks === 'passing' ? 'greenBright' : 'cyan';
  // A PR whose checks have not resolved yet (prUrl present, prChecks still
  // null) is genuine async work in progress - the PR-check poll - so it gets
  // its own live spinner node ahead of the meta text rather than a static
  // dim string, matching the captain's "loaders on async work" ask. This is
  // a real sibling Ink node (not string-joined into metaParts) so the spinner
  // still animates independent of the surrounding text's own truncation.
  const prPending = !!card.prUrl && card.prChecks == null;
  const metaText = truncate(metaParts.join('  '), Math.max(6, contentWidth - (prPending ? 3 : 1)));
  const meta = h(
    Box,
    { flexWrap: 'nowrap' },
    prPending
      ? h(Text, { color: 'cyan', wrap: 'truncate-end' }, ' ', h(Spinner, { type: 'dots' }))
      : null,
    h(Text, { dimColor: true, color: card.prUrl ? prColor : undefined, wrap: 'truncate-end' }, ` ${metaText}`)
  );

  return h(
    Box,
    {
      flexDirection: 'column',
      borderStyle: 'round',
      borderTop: false,
      borderBottom: false,
      borderRight: false,
      borderLeft: true,
      borderLeftColor: healthColor,
    },
    headline,
    meta
  );
}

// A backlog-only row (QUEUED, RECENT DONE) that has no live task card: one
// line, dimmer and colorless relative to a live Card so the two are visually
// distinct at a glance.
function BacklogRow({ record, width }) {
  const title = record?.title || record?.raw || '(untitled)';
  const meta = [];
  if (record?.repo) meta.push(record.repo);
  if (record?.blocked_by) meta.push(`blocked-by ${record.blocked_by}`);
  if (record?.completion?.date) meta.push(`${record.completion.verb || 'done'} ${record.completion.date}`);
  const metaText = meta.length ? ` (${meta.join(', ')})` : '';
  const text = `${record?.id ? `${record.id} - ` : ''}${title}${metaText}`;
  // width is the section's content width already net of its own border+
  // padding (see Section's contentWidth below); only the marker prefix (" • "
  // / " ⏸ ", 3 cols) needs accounting for here, plus a 1-col safety margin so
  // Ink's own wrapping never kicks in even when a terminal's wide glyphs
  // measure a hair wider than truncate()'s plain character count.
  return h(
    Box,
    { flexWrap: 'nowrap' },
    h(
      Text,
      { bold: !!record?.blocked_by, color: record?.blocked_by ? 'yellowBright' : 'gray', wrap: 'truncate-end' },
      record?.blocked_by ? ` ${figures.circleDotted} ` : ` ${figures.bullet} `
    ),
    h(Text, { dimColor: true, wrap: 'truncate-end' }, truncate(text, Math.max(4, width - 4)))
  );
}

// Cap a flat list of section rows to `maxRows` terminal rows, appending a
// "+N more" marker (itself counted in the budget) instead of silently
// dropping the overflow or handing Ink more rows than the section's allotted
// space - see the Card comment above for why that overflow path corrupts the
// render. Entries are plain Ink nodes (implicit height 1, e.g. a group label
// or a BacklogRow) or `{ node, height }` for a multi-row entry such as a
// 2-row Card; a plain-node entry list therefore behaves exactly as before
// this height-aware accounting was added.
function capRows(entries, maxRows, moreLabel) {
  const heightOf = (e) => (e && typeof e === 'object' && 'height' in e ? e.height : 1);
  const nodeOf = (e) => (e && typeof e === 'object' && 'height' in e ? e.node : e);
  const totalHeight = entries.reduce((sum, e) => sum + heightOf(e), 0);
  if (maxRows == null || totalHeight <= maxRows) return entries.map(nodeOf);
  if (maxRows <= 0) return [];
  // Over budget, so a "+N more" marker (1 row) is always needed - reserve its
  // row upfront and take entries in order until the next one would no longer
  // fit, stopping there rather than skipping a too-tall entry to admit a
  // later, smaller one out of order.
  const budget = maxRows - 1;
  const kept = [];
  let used = 0;
  let i = 0;
  for (; i < entries.length; i++) {
    const eh = heightOf(entries[i]);
    if (used + eh > budget) break;
    kept.push(nodeOf(entries[i]));
    used += eh;
  }
  const droppedCount = entries.length - i;
  if (droppedCount > 0) {
    kept.push(h(Text, { key: '__more', dimColor: true, italic: true }, `  … +${droppedCount} more ${moreLabel}`));
  }
  return kept;
}

// One board section: a bordered, colour-titled box whose title doubles as a
// single-line divider (no separate blank row beneath it - deliberate spacing
// discipline, not a default). Pass `height` for a section that should hug its
// own content instead of stretching to fill the parent flex row (IN FLIGHT
// when it is smaller than its fair share - the fix for the half-empty-box
// problem); pass `flexGrow` for a section that should absorb whatever space
// siblings leave unclaimed (QUEUED/RECENT DONE always, IN FLIGHT when its
// content meets or exceeds its fair share). `maxRows`, when given, caps how
// many body rows are handed to Ink (see capRows) so this section alone can
// never overflow its allotted height.
function Section({ title, icon, color, count, rows, maxRows, flexGrow, height, emptyText }) {
  const body = rows && rows.length ? capRows(rows, maxRows, 'below') : null;
  const box = { flexDirection: 'column', borderStyle: 'round', borderColor: color, paddingX: 1 };
  if (height != null) box.height = height;
  else box.flexGrow = flexGrow || 1;
  return h(
    Box,
    box,
    h(Text, { bold: true, color }, `${icon ? `${icon} ` : ''}${title}${count != null ? ` (${count})` : ''}`),
    body || h(Text, { dimColor: true }, emptyText || 'nothing here')
  );
}

// FIRSTMATE ACTIVITY: a live tail of firstmate's OWN pane (the same resolved
// supervisor target the command bridge sends into - see bridge.js), so the
// captain watches firstmate work without ever switching to its raw terminal
// pane. Rows are capped to `maxRows` (capRows, same discipline as every other
// section - Ink has no scrolling) and each line is truncated to width rather
// than wrapped, matching the Card/BacklogRow contract. Newest content is at
// the bottom (activityLines is already tailed in state.js), so it reads like
// watching a live terminal rather than a jumbled dump.
function FirstmateActivityPanel({ lines, error, width, flexGrow, height, maxRows }) {
  const contentWidth = Math.max(6, width - 2);
  // A transient capture error (a slow poll, a momentarily unreadable pane)
  // must not blank a stale-but-still-useful prior capture: prefer showing the
  // last good lines over the error text whenever we have any, and reserve the
  // error placeholder for when there is truly nothing to show yet (including
  // the fail-closed not-resolved case, where lines is always empty).
  let rows;
  if (lines.length) {
    rows = lines.map((l, i) => h(Text, { key: i, dimColor: true, wrap: 'truncate-end' }, truncate(l, contentWidth) || ' '));
  } else if (error) {
    rows = [
      h(
        Text,
        { key: 'err', color: 'yellowBright', wrap: 'truncate-end' },
        `${figures.warning} ${truncate(error, Math.max(1, contentWidth - 2))}`
      ),
    ];
  } else {
    rows = null;
  }
  return h(Section, {
    title: 'FIRSTMATE ACTIVITY',
    icon: figures.radioOn,
    color: 'blueBright',
    flexGrow,
    height,
    maxRows,
    rows,
    emptyText: error ? error : `${figures.ellipsis} capturing...`,
  });
}

function InFlightSection({ grouped, selectedId, width, flexGrow, height, maxRows }) {
  const anyCards = GROUP_ORDER.some((g) => (grouped.get(g) || []).length > 0);
  const rows = anyCards
    ? GROUP_ORDER.flatMap((g) => {
        const cards = grouped.get(g) || [];
        if (!cards.length) return [];
        const color = GROUP_COLORS[g] || 'white';
        return [
          h(Text, { key: `${g}-label`, bold: true, color }, `${GROUP_LABELS[g]} (${cards.length})`),
          ...cards.map((c) => ({
            node: h(Card, { key: c.id, card: c, selected: c.id === selectedId, width }),
            height: CARD_ROW_HEIGHT,
          })),
        ];
      })
    : [];
  return h(Section, {
    title: 'IN FLIGHT',
    icon: figures.play,
    color: 'cyan',
    flexGrow,
    height,
    maxRows,
    rows,
    emptyText: `${figures.tick} Nothing in flight - a healthy resting state.`,
  });
}

function QueuedSection({ records, blockedCount, width, flexGrow, maxRows }) {
  const rows = records.map((r, i) => h(BacklogRow, { key: r.id || `q${i}`, record: r, width }));
  const title = blockedCount ? `QUEUED (${records.length}, ${blockedCount} blocked)` : 'QUEUED';
  return h(Section, {
    title,
    icon: figures.hamburger,
    color: 'yellow',
    count: blockedCount ? null : records.length,
    flexGrow,
    maxRows,
    rows,
    emptyText: 'Backlog is empty.',
  });
}

function RecentDoneSection({ doneCards, doneRecords, width, flexGrow, maxRows }) {
  const rows = [
    ...doneCards.map((c) => ({
      node: h(Card, { key: `c-${c.id}`, card: c, selected: false, width }),
      height: CARD_ROW_HEIGHT,
    })),
    ...doneRecords.map((r, i) => h(BacklogRow, { key: `r-${r.id || i}`, record: r, width })),
  ];
  return h(Section, {
    title: 'RECENT DONE',
    icon: figures.tick,
    color: 'gray',
    flexGrow,
    maxRows,
    rows,
    emptyText: 'Nothing done yet.',
  });
}

// The input/command line, quick-action menu, and hints. Quick-actions live
// behind a Tab-opened menu so free-typing a command never collides with the
// action keys - the input line is always plain text.
function InputLine({ input, pendingConfirm, quickMenu, selectedId, message }) {
  return h(
    Box,
    { flexDirection: 'column', borderStyle: 'single', borderColor: 'gray', paddingX: 1 },
    message ? h(Text, { color: message.color || 'white' }, message.text) : null,
    quickMenu
      ? h(
          Text,
          { color: 'cyan' },
          `quick-actions for ${selectedId}: ${QUICK_ACTIONS.map(
            (a) => `${a.key}:${a.label}${a.destructive ? '!' : ''}`
          ).join('  ')}  ·  Esc cancel`
        )
      : null,
    pendingConfirm
      ? h(
          Text,
          { color: 'red', bold: true },
          `confirm ${pendingConfirm.verb} ${selectedId}? press y to compose, any other key to cancel`
        )
      : null,
    h(
      Box,
      null,
      h(Text, { color: 'greenBright' }, '❯ '),
      h(Text, null, input.length ? input : ''),
      h(Text, { inverse: true }, ' ')
    ),
    h(
      Text,
      { dimColor: true },
      selectedId
        ? '↑/↓ select · Tab quick-actions · type a command · Enter send · Ctrl-C quit'
        : '↑/↓ select a task · type a command · Enter send · Ctrl-C quit'
    )
  );
}

export default function App({ bin, home }) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [dims, setDims] = useState({
    width: (stdout && stdout.columns) || 80,
    height: (stdout && stdout.rows) || 24,
  });

  // React to terminal resize so the board keeps filling the screen rather
  // than drawing at whatever size was current at first paint.
  useEffect(() => {
    if (!stdout || typeof stdout.on !== 'function') return undefined;
    const onResize = () => setDims({ width: stdout.columns || 80, height: stdout.rows || 24 });
    stdout.on('resize', onResize);
    return () => {
      if (typeof stdout.off === 'function') stdout.off('resize', onResize);
      else if (typeof stdout.removeListener === 'function') stdout.removeListener('resize', onResize);
    };
  }, [stdout]);

  const { width, height } = dims;
  const compact = width < MIN_COLS_FOR_FULL_LAYOUT || height < MIN_ROWS_FOR_FULL_LAYOUT;

  const [snapshot, setSnapshot] = useState(null);
  const [snapError, setSnapError] = useState(null);
  const [disk, setDisk] = useState({ free: null, usePct: null });
  const [watcherBeat, setWatcherBeat] = useState(null);
  const [afk, setAfk] = useState(false);
  const [duById, setDuById] = useState({});
  const [prById, setPrById] = useState({});
  const [mtimeById, setMtimeById] = useState({});
  const [selectedId, setSelectedId] = useState(null);
  const [input, setInput] = useState('');
  const [pendingConfirm, setPendingConfirm] = useState(null);
  const [quickMenu, setQuickMenu] = useState(false);
  const [message, setMessage] = useState(null);
  const [activityText, setActivityText] = useState(null);
  const [activityError, setActivityError] = useState(null);
  const [activityExpanded, setActivityExpanded] = useState(false);

  // inputRef mirrors `input` so doSend/handleInput can read the CURRENT value
  // without closing over the `input` state itself. Closing over `input`
  // directly would put it in useCallback's dependency array, and since
  // `input` changes on every keystroke that would recreate handleInput on
  // every keystroke too - see the handleInput comment below for why that is
  // the actual root cause of the runaway-input bug, not just a performance
  // wrinkle: a recreated callback churns Ink's useInput stdin listener
  // (detach + reattach) on every single character, and a keystroke landing in
  // that gap can be delivered to more than one listener instance, appending
  // more than once per keypress and compounding exponentially.
  const inputRef = useRef('');
  useEffect(() => {
    inputRef.current = input;
  }, [input]);

  // Memoized (computed once per mount): process.env-derived and does not
  // change within a session. A fresh object every render would otherwise
  // cascade into doSend/handleInput below never stabilizing their own
  // useCallback identity, which churns Ink's useInput stdin listener on every
  // render and can drop a keystroke that lands in the reattach gap (see the
  // handleInput comment below).
  const supervisor = useMemo(() => resolveSupervisor(), []);
  const mounted = useRef(true);
  useEffect(() => () => { mounted.current = false; }, []);

  // Fast board refresh: snapshot + disk + watcher beacon + afk flag.
  const refresh = useCallback(async () => {
    const [{ snapshot: snap, error }, d, beat, afkPresent] = await Promise.all([
      readSnapshot(bin, home),
      readDisk(DATA_VOLUME),
      fileMtimeSecs(`${home}/state/.last-watcher-beat`),
      fileExists(`${home}/state/.afk`),
    ]);
    if (!mounted.current) return;
    // Keep the last good snapshot on screen if this read failed (a timed-out
    // or wedged read is transient) - degrading the whole board to empty on one
    // bad read would look exactly like the "reports nothing in flight" bug
    // this console exists to avoid; only replace it when we actually got JSON.
    if (snap) setSnapshot(snap);
    setSnapError(error);
    setDisk(d);
    setWatcherBeat(beat);
    setAfk(afkPresent);
  }, [bin, home]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, REFRESH_INTERVAL_MS);
    return () => clearInterval(t);
  }, [refresh]);

  // FIRSTMATE ACTIVITY: a read-only tail of firstmate's own pane, on the same
  // fast board-refresh cadence as the snapshot poll. Reuses the SAME resolved
  // supervisor target the command bridge sends into (supervisor, memoized
  // above from resolveSupervisor()), so the panel always shows the activity of
  // the exact firstmate the input line talks to. This is an async side-channel
  // exactly like the du/PR-checks/mtime passes above: a slow or wedged pane
  // capture must never block a redraw, so it is never awaited inline in
  // render - only its result lands in state once it resolves. When the
  // supervisor target could not be resolved (the same fail-closed case the
  // bridge already reports), this never shells out at all and the panel shows
  // the not-resolved placeholder instead of guessing a pane.
  useEffect(() => {
    if (supervisor.error || !supervisor.target) {
      setActivityText(null);
      setActivityError(supervisor.error || 'no supervisor target resolved');
      return undefined;
    }
    let cancelled = false;
    async function captureActivity() {
      const { text, error } = await readFirstmateActivity(
        bin,
        home,
        supervisor.target,
        FIRSTMATE_ACTIVITY_CAPTURE_LINES
      );
      if (cancelled || !mounted.current) return;
      if (text != null) setActivityText(text);
      setActivityError(error);
    }
    captureActivity();
    const t = setInterval(captureActivity, REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, [bin, home, supervisor]);

  // Age/last-event mtime pass: a single stat() per file, unlike du's tree walk,
  // so it is cheap enough to run on the fast board-refresh cadence rather than
  // the slower du/PR one - but it is still threaded in as an async side-channel
  // (never awaited inline in the card build) so a slow or missing file never
  // blocks a redraw, matching the du/PR pattern below.
  const tasks = (snapshot && snapshot.tasks) || [];
  const mtimeTaskKey = tasks
    .map((t) => `${t.id}:${t.paths?.meta?.path || ''}:${t.paths?.status_log?.path || ''}`)
    .join('|');
  useEffect(() => {
    let cancelled = false;
    async function measureMtimes() {
      for (const t of tasks) {
        const metaPath = t.paths?.meta?.path;
        const statusPath = t.paths?.status_log?.path;
        const [metaMtime, statusMtime] = await Promise.all([
          metaPath ? fileMtimeSecs(metaPath) : null,
          statusPath ? fileMtimeSecs(statusPath) : null,
        ]);
        if (cancelled || !mounted.current) return;
        setMtimeById((prev) => ({ ...prev, [t.id]: { metaMtime, statusMtime } }));
      }
    }
    measureMtimes();
    const t = setInterval(measureMtimes, REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
    // Re-run when the set of tasks/meta/status paths changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mtimeTaskKey]);

  // Slower, non-blocking du + PR-checks pass over the current tasks.
  const taskKey = tasks.map((t) => `${t.id}:${t.paths?.worktree?.path || ''}:${t.pr?.url || ''}`).join('|');
  useEffect(() => {
    let cancelled = false;
    async function measure() {
      for (const t of tasks) {
        const wt = t.paths?.worktree?.path;
        if (wt) {
          const size = await readWorktreeSize(wt);
          if (cancelled || !mounted.current) return;
          if (size != null) setDuById((prev) => ({ ...prev, [t.id]: size }));
        }
        const prUrl = t.pr?.url;
        if (prUrl) {
          const checks = await readPrChecks(prUrl);
          if (cancelled || !mounted.current) return;
          if (checks != null) setPrById((prev) => ({ ...prev, [t.id]: checks }));
        }
      }
    }
    measure();
    const t = setInterval(measure, DU_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
    // Re-run when the set of tasks/worktrees/PRs changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [taskKey]);

  const nowForCards = nowSecs();
  const cards = tasks.map((t) => {
    const mtimes = mtimeById[t.id];
    const ageSecs = mtimes?.metaMtime != null ? Math.max(0, nowForCards - mtimes.metaMtime) : null;
    const lastEventSecs = mtimes?.statusMtime != null ? Math.max(0, nowForCards - mtimes.statusMtime) : null;
    return buildCard(t, { duBytes: duById[t.id] ?? null, prChecks: prById[t.id] ?? null, ageSecs, lastEventSecs });
  });
  const { inFlight, inFlightGrouped, done } = boardSections(cards);
  const queuedRecords = queuedBacklogRecords(snapshot);
  const doneRecords = recentDoneBacklogRecords(snapshot, RECENT_DONE_LIMIT);
  const orderedIds = GROUP_ORDER.flatMap((g) => (inFlightGrouped.get(g) || []).map((c) => c.id));

  // orderedIds is a fresh array every render (recomputed from the polled
  // snapshot), and selectedId/pendingConfirm/quickMenu all change on their own
  // interactions - mirrored into refs for the same reason inputRef exists
  // above: handleInput reads the CURRENT value through the ref rather than
  // closing over the state, so none of these belong in its useCallback deps.
  const orderedIdsRef = useRef(orderedIds);
  useEffect(() => {
    orderedIdsRef.current = orderedIds;
  });
  const selectedIdRef = useRef(selectedId);
  useEffect(() => {
    selectedIdRef.current = selectedId;
  }, [selectedId]);
  const pendingConfirmRef = useRef(pendingConfirm);
  useEffect(() => {
    pendingConfirmRef.current = pendingConfirm;
  }, [pendingConfirm]);
  const quickMenuRef = useRef(quickMenu);
  useEffect(() => {
    quickMenuRef.current = quickMenu;
  }, [quickMenu]);

  // Keep selection valid as the fleet changes.
  useEffect(() => {
    if (selectedId && !orderedIds.includes(selectedId)) setSelectedId(null);
  }, [orderedIds.join(','), selectedId]);

  const header = buildHeader({
    diskFree: disk.free,
    diskUsePct: disk.usePct,
    watcherBeatSecs: watcherBeat,
    nowSecs: nowSecs(),
    afkPresent: afk,
    snapshot,
    inFlightCount: inFlight.length,
  });

  // sendingRef guards re-entrancy: doSend is async, so without this a second
  // Enter (or key auto-repeat) firing mid-flight could start a second send
  // and/or let the char handler keep appending, compounding the input buffer
  // into a screen-filling wall. The ref (not state) is read synchronously by
  // handleInput on every keystroke, with no render lag between check and set.
  const sendingRef = useRef(false);

  const doSend = useCallback(async () => {
    const command = normalizeCommand(inputRef.current);
    if (!isSendable(command)) return;
    if (sendingRef.current) {
      setMessage({ text: 'still sending, please wait...', color: 'yellow' });
      return;
    }
    if (supervisor.error) {
      setMessage({ text: `cannot send: ${supervisor.error}`, color: 'red' });
      return;
    }
    // Clear the input the moment the send starts, not conditionally after the
    // async call resolves - a failed send must leave the input empty exactly
    // like a successful one, never re-populated with the failed command.
    setInput('');
    sendingRef.current = true;
    setMessage({ text: `sending: ${command}`, color: 'cyan' });
    try {
      const res = await sendCommand({
        bin,
        home,
        target: supervisor.target,
        command,
      });
      if (!mounted.current) return;
      if (res.ok) {
        setMessage({ text: `sent: ${command}`, color: 'green' });
      } else {
        setMessage({ text: `send failed (${res.code}): ${truncate(res.stderr, 60)}`, color: 'red' });
      }
    } finally {
      sendingRef.current = false;
    }
  }, [bin, home, supervisor]);

  // Stable across every keystroke: this is the fix for the runaway-input bug.
  // Ink's useInput effect re-attaches its stdin listener whenever this
  // callback's identity changes, and a keystroke landing in that detach/
  // reattach gap can be delivered more than once. The old handler closed over
  // `input`, `selectedId`, `pendingConfirm`, `quickMenu`, and `orderedIds`
  // directly, so its useCallback deps included `input` - which changes on
  // EVERY keystroke - meaning the listener reattached on every single
  // character typed, letting a keystroke double- or quadruple-append and
  // compound exponentially into a screen-filling wall. Reading every one of
  // those current values through a ref (inputRef, selectedIdRef,
  // pendingConfirmRef, quickMenuRef, orderedIdsRef, all synced above) instead
  // of closing over the state means this handler needs no per-render or
  // per-keystroke value in its dependency array, so it is created exactly
  // once and the stdin listener attaches exactly once for the life of the app.
  const handleInput = useCallback((inputChar, key) => {
    // Ctrl-C handled by Ink's exit, but be explicit for clean quit.
    if (key.ctrl && inputChar === 'c') {
      exit();
      return;
    }

    // Ctrl-A toggles the in-flight FIRSTMATE ACTIVITY strip taller, for when
    // the captain wants more than a glance while crews are running. A plain
    // 'a' is never stolen here - only the Ctrl-combo - so free typing is
    // unaffected (mirrors why quick-actions live behind Tab, not bare keys).
    if (key.ctrl && inputChar === 'a') {
      setActivityExpanded((v) => !v);
      return;
    }

    const pending = pendingConfirmRef.current;
    const selId = selectedIdRef.current;

    // A pending destructive-confirm intercepts the next keystroke.
    if (pending) {
      if (inputChar === 'y') {
        setInput(composeQuickAction(pending.verb, selId));
        setMessage({ text: `composed ${pending.verb} ${selId} - review and press Enter to send`, color: 'yellow' });
      } else {
        setMessage({ text: 'cancelled', color: 'gray' });
      }
      setPendingConfirm(null);
      return;
    }

    // The Tab-opened quick-action menu intercepts the next keystroke. This is
    // why free-typing never collides with the action keys: s/m/t only mean
    // "quick action" inside this menu, never in the plain input line.
    if (quickMenuRef.current) {
      setQuickMenu(false);
      if (key.escape) {
        setMessage({ text: 'cancelled', color: 'gray' });
        return;
      }
      const action = actionForKey(inputChar);
      if (action && selId) {
        if (action.destructive) {
          setPendingConfirm(action);
        } else {
          setInput(composeQuickAction(action.verb, selId));
          setMessage({ text: `composed ${action.verb} ${selId} - review and press Enter to send`, color: 'yellow' });
        }
      } else {
        setMessage({ text: 'cancelled', color: 'gray' });
      }
      return;
    }

    // Tab opens the quick-action menu for the selected task.
    if (key.tab) {
      if (selId) {
        setQuickMenu(true);
      } else {
        setMessage({ text: 'select a task first (↑/↓)', color: 'gray' });
      }
      return;
    }

    if (key.upArrow) {
      const ids = orderedIdsRef.current;
      if (!ids.length) return;
      const i = selId ? ids.indexOf(selId) : 0;
      setSelectedId(ids[Math.max(0, i - 1)]);
      return;
    }
    if (key.downArrow) {
      const ids = orderedIdsRef.current;
      if (!ids.length) return;
      const i = selId ? ids.indexOf(selId) : -1;
      setSelectedId(ids[Math.min(ids.length - 1, i + 1)]);
      return;
    }

    if (key.return) {
      doSend();
      return;
    }

    if (key.backspace || key.delete) {
      setInput((s) => s.slice(0, -1));
      return;
    }

    // Printable character into the input line. The input line is always plain
    // text - quick-actions live behind the Tab menu, never here - so no key is
    // stolen from typing a command.
    if (inputChar && !key.ctrl && !key.meta && !key.tab) {
      setInput((s) => s + inputChar);
    }
  }, [exit, doSend]);

  useInput(handleInput);

  // FIRSTMATE ACTIVITY panel state, derived once per render from the polled
  // capture (activityText/activityError, set by the async side-channel above)
  // plus the not-resolved case surfaced by the same fail-closed bridge check
  // the command bridge already reports (supervisor.error). Idle fleet: the
  // panel takes over IN FLIGHT's whole freed box (see boardRow below) at no
  // extra row cost - it reuses a box the board would otherwise devote to
  // "Nothing in flight" text. In-flight: it renders as a slim ADDITIONAL strip
  // above the board, which only fits by taking rows away from IN FLIGHT/
  // QUEUED/RECENT DONE - so it is only added when the terminal has real slack
  // beyond the existing compact-layout threshold (MIN_ROWS_FOR_FULL_LAYOUT):
  // below that, the strip would squeeze the fleet board unreadable in exactly
  // the way the row-budget discipline above exists to prevent, so it is
  // dropped entirely rather than degrading the board everyone already relies
  // on. A captain-pressed toggle (Ctrl-A) expands it a bit further when there
  // is room to spare.
  const activityIdle = inFlight.length === 0;
  const activityStripRows = activityExpanded ? FIRSTMATE_ACTIVITY_STRIP_ROWS * 2 : FIRSTMATE_ACTIVITY_STRIP_ROWS;
  const activityStripHeight = SECTION_ROW_CHROME + activityStripRows;
  const activityStripFits = height >= MIN_ROWS_FOR_FULL_LAYOUT + activityStripHeight;
  const showActivityStrip = !activityIdle && activityStripFits;

  // Row budget: Ink has no scrolling, and handing a fixed-height flex tree
  // more rows than it has space for can corrupt the render rather than clip
  // it cleanly (see the Card/capRows comments above) - it silently loses
  // content on WHATEVER auto-sized rows come first, not just the last ones,
  // because Yoga distributes the shortfall across the tree rather than
  // truncating at the bottom. So every row that will be drawn is counted
  // BEFORE Ink ever sees it - computeRowBudget (state.js) is the pure,
  // unit-tested math; each section is then capped to fit via capRows.
  const footerLines = snapError || !header.watcherAlive || supervisor.error ? 1 : 0;
  const inFlightContentRows = inFlightContentRowCount(inFlightGrouped);
  // The in-flight activity strip is its own fixed-height box outside
  // computeRowBudget's three-section split (IN FLIGHT/QUEUED/RECENT DONE), so
  // its total row cost (chrome + body) is subtracted from the height handed to
  // that budget when it is actually shown - exactly like fixedChrome already
  // accounts for the title bar/status strip/footer/input box - or the budget
  // would hand out rows the strip has already claimed and the board would
  // overflow its allotted height.
  const { inFlightRows, queuedRows, doneRows } = computeRowBudget({
    height: height - (showActivityStrip ? activityStripHeight : 0),
    hasFooter: footerLines > 0,
    hasInFlight: inFlight.length > 0,
    inFlightContentRows: inFlight.length ? inFlightContentRows : null,
  });

  // IN FLIGHT hugs its own content (a fixed height: SECTION_ROW_CHROME plus
  // its capped body rows) whenever that content is smaller than the space
  // computeRowBudget would otherwise give it - this is the fix for the
  // half-empty-box problem: a single card no longer reserves acres of blank
  // space below it. Once content meets or exceeds the row budget (a large
  // fleet), IN FLIGHT switches to flexGrow so it still competes for space
  // like the other sections instead of clipping at an arbitrary fixed size.
  const inFlightHugsContent = inFlight.length > 0 && inFlightContentRows < inFlightRows;
  const inFlightHeight = inFlightHugsContent ? SECTION_ROW_CHROME + inFlightRows : null;
  const inFlightGrow = inFlight.length ? 3 : 1;

  // Each Section pays 1 col of border + 1 col of padding on each side (4
  // total), so the content width handed to Card/BacklogRow must already net
  // that out - otherwise their own truncate() budget under-counts and Ink's
  // own wrapping kicks in on the overflow (a second, wrapped line inside the
  // box) instead of a clean single-line truncation.
  const SECTION_CHROME_WIDTH = 4;
  const fullContentWidth = Math.max(10, width - SECTION_CHROME_WIDTH);
  const halfContentWidth = Math.max(10, Math.floor(width / 2) - SECTION_CHROME_WIDTH);

  // Tail exactly to each panel's own row budget (never more) so capRows never
  // has to truncate this content - capRows keeps a list's EARLIEST entries and
  // drops the tail behind a "+N more" marker, which is right for IN FLIGHT
  // cards/backlog rows (most-important-first) but wrong for a live tail
  // (newest-at-bottom is the whole point): truncating post-tail would show
  // stale lines and hide the newest one behind "+N more" instead.
  const idleActivityLines = firstmateActivityLines(activityText, inFlightRows);
  const stripActivityLines = firstmateActivityLines(activityText, activityStripRows);

  // Idle fleet (the common case): IN FLIGHT's whole freed box shows firstmate
  // working instead of an empty "Nothing in flight" message - this is the
  // console's single-window point in its clearest form, since the biggest
  // block of otherwise-wasted space now shows the one thing the board could
  // not show before. In-flight, with room to spare: a compact strip sits above
  // IN FLIGHT/QUEUED/RECENT DONE instead, so the captain still sees firstmate
  // working at a glance without the fleet board losing its own room; Ctrl-A
  // toggles it taller when more context is wanted. In-flight at a cramped
  // terminal height: the strip is dropped entirely (showActivityStrip false)
  // rather than squeeze the fleet board unreadable - the row-budget discipline
  // above already reserves nothing for it in that case.
  const inFlightOrActivity = activityIdle
    ? h(FirstmateActivityPanel, {
        lines: idleActivityLines,
        error: activityError,
        width: fullContentWidth,
        flexGrow: inFlightHeight == null ? inFlightGrow : undefined,
        height: inFlightHeight,
        maxRows: inFlightRows,
      })
    : h(InFlightSection, {
        grouped: inFlightGrouped,
        selectedId,
        width: fullContentWidth,
        flexGrow: inFlightHeight == null ? inFlightGrow : undefined,
        height: inFlightHeight,
        maxRows: inFlightRows,
      });

  const activityStrip = showActivityStrip
    ? h(FirstmateActivityPanel, {
        lines: stripActivityLines,
        error: activityError,
        width: fullContentWidth,
        height: activityStripHeight,
        maxRows: activityStripRows,
      })
    : null;

  const boardRow = compact
    ? h(
        Box,
        { flexDirection: 'column', flexGrow: 1 },
        activityStrip,
        inFlightOrActivity,
        h(QueuedSection, {
          records: queuedRecords,
          blockedCount: header.blocked,
          width: fullContentWidth,
          flexGrow: 1,
          maxRows: queuedRows,
        }),
        h(RecentDoneSection, { doneCards: done, doneRecords, width: fullContentWidth, flexGrow: 1, maxRows: doneRows })
      )
    : h(
        Box,
        { flexDirection: 'column', flexGrow: 1 },
        activityStrip,
        inFlightOrActivity,
        h(
          Box,
          { flexGrow: 2 },
          h(QueuedSection, {
            records: queuedRecords,
            blockedCount: header.blocked,
            width: halfContentWidth,
            flexGrow: 1,
            maxRows: queuedRows,
          }),
          h(RecentDoneSection, {
            doneCards: done,
            doneRecords,
            width: halfContentWidth,
            flexGrow: 1,
            maxRows: doneRows,
          })
        )
      );

  return h(
    Box,
    { flexDirection: 'column', width, height, overflowY: 'hidden' },
    h(TitleBar, { home, width }),
    h(StatusStrip, { header, width }),
    boardRow,
    h(Footer, { header, supervisor, snapError }),
    h(InputLine, { input, pendingConfirm, quickMenu, selectedId, message })
  );
}
