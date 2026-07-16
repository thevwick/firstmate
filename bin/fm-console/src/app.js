// The Ink app. Written with React.createElement (aliased `h`) rather than JSX
// so the package syncs as plain source with no build/transpile step, matching
// the rest of firstmate's bin/ tooling.
//
// Responsibilities: poll firstmate state on REFRESH_INTERVAL_MS and redraw;
// recompute per-worktree du on the slower DU_INTERVAL_MS without blocking a
// redraw; render the header, the grouped cards, and the command input line;
// route composed/typed commands to the primary session via the bridge. All
// approval gates stay with firstmate - the input only DELIVERS text.

import React from 'react';
import { Box, Text, useApp, useInput, useStdout } from 'ink';

import {
  REFRESH_INTERVAL_MS,
  DU_INTERVAL_MS,
  DATA_VOLUME,
  GROUP_ORDER,
  GROUP_LABELS,
} from './constants.js';
import {
  buildCard,
  buildHeader,
  groupCards,
} from './state.js';
import {
  QUICK_ACTIONS,
  actionForKey,
  composeQuickAction,
  isSendable,
  normalizeCommand,
} from './commands.js';
import { humanBytes, truncate } from './format.js';
import {
  readSnapshot,
  readDisk,
  readWorktreeSize,
  readPrChecks,
  fileMtimeSecs,
  fileExists,
} from './io.js';
import { resolveSupervisor, sendCommand } from './bridge.js';

const h = React.createElement;
const { useState, useEffect, useRef, useCallback } = React;

const GROUP_COLORS = {
  'needs-you': 'red',
  ready: 'green',
  working: 'cyan',
  blocked: 'yellow',
  done: 'gray',
};

function nowSecs() {
  return Math.floor(Date.now() / 1000);
}

// Header line: disk, watcher, afk, backlog counts.
function Header({ header, home, supervisor }) {
  const diskText =
    header.diskFree == null
      ? 'disk ?'
      : `disk ${humanBytes(header.diskFree)} free${
          header.diskUsePct == null ? '' : ` (${header.diskUsePct}% used)`
        }`;
  const diskColor =
    header.diskUsePct != null && header.diskUsePct >= 90 ? 'red' : 'white';
  return h(
    Box,
    { flexDirection: 'column' },
    h(
      Box,
      { justifyContent: 'space-between' },
      h(
        Box,
        null,
        h(Text, { bold: true, color: 'magentaBright' }, 'fm-console '),
        h(Text, { dimColor: true }, truncate(home, 48))
      ),
      h(
        Box,
        null,
        h(Text, { color: diskColor }, diskText),
        h(Text, { dimColor: true }, '  ·  '),
        h(
          Text,
          { color: header.watcherAlive ? 'green' : 'red' },
          header.watcherAlive ? 'watcher alive' : 'watcher DOWN'
        ),
        h(Text, { dimColor: true }, '  ·  '),
        h(
          Text,
          { color: header.afk ? 'yellow' : 'gray' },
          header.afk ? 'afk' : 'present'
        ),
        h(Text, { dimColor: true }, '  ·  '),
        h(
          Text,
          null,
          `queued ${header.queued}`,
          header.blocked ? h(Text, { color: 'yellow' }, ` (${header.blocked} blocked)`) : null
        )
      )
    ),
    supervisor.error
      ? h(
          Text,
          { color: 'yellow' },
          `command bridge disabled: ${supervisor.error}`
        )
      : h(
          Text,
          { dimColor: true },
          `bridge → ${supervisor.target}${supervisor.backend ? ` [${supervisor.backend}]` : ''}`
        )
  );
}

// One task card row.
function Card({ card, selected, width }) {
  const color = GROUP_COLORS[card.group] || 'white';
  const chips = [];
  if (card.ticket) chips.push(h(Text, { key: 'tk', color: 'blueBright' }, ` [${card.ticket}]`));
  const prText = card.prUrl
    ? ` PR${card.prChecks ? `:${card.prChecks}` : ''}`
    : '';
  const prColor =
    card.prChecks === 'failing'
      ? 'red'
      : card.prChecks === 'passing'
        ? 'green'
        : 'cyan';
  return h(
    Box,
    { flexDirection: 'column', marginBottom: 0 },
    h(
      Box,
      null,
      h(Text, { color: selected ? 'black' : color, backgroundColor: selected ? color : undefined, bold: true }, ` ${card.id} `),
      ...chips,
      h(Text, { dimColor: true }, ` ${card.repo}`),
      h(Text, { dimColor: true }, ` · ${card.kind}`),
      h(Text, { dimColor: true }, ` · ${humanBytes(card.duBytes)}`),
      card.prUrl ? h(Text, { color: prColor }, prText) : null
    ),
    card.lastEvent
      ? h(Text, { dimColor: true }, `    ${truncate(card.lastEvent, Math.max(10, width - 6))}`)
      : h(Text, { dimColor: true }, `    ${card.stateRaw}${card.stateDetail ? ` · ${card.stateDetail}` : ''}`)
  );
}

function Group({ name, cards, selectedId, width }) {
  if (!cards.length) return null;
  const color = GROUP_COLORS[name] || 'white';
  return h(
    Box,
    { flexDirection: 'column', marginTop: 1 },
    h(Text, { bold: true, color }, `── ${GROUP_LABELS[name]} (${cards.length}) ──`),
    ...cards.map((c) =>
      h(Card, { key: c.id, card: c, selected: c.id === selectedId, width })
    )
  );
}

// The input/command line, quick-action menu, and hints. Quick-actions live
// behind a Tab-opened menu so free-typing a command never collides with the
// action keys - the input line is always plain text.
function InputLine({ input, pendingConfirm, quickMenu, selectedId, message }) {
  return h(
    Box,
    { flexDirection: 'column', marginTop: 1 },
    message
      ? h(Text, { color: message.color || 'white' }, message.text)
      : null,
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
  const width = (stdout && stdout.columns) || 80;

  const [snapshot, setSnapshot] = useState(null);
  const [snapError, setSnapError] = useState(null);
  const [disk, setDisk] = useState({ free: null, usePct: null });
  const [watcherBeat, setWatcherBeat] = useState(null);
  const [afk, setAfk] = useState(false);
  const [duById, setDuById] = useState({});
  const [prById, setPrById] = useState({});
  const [selectedId, setSelectedId] = useState(null);
  const [input, setInput] = useState('');
  const [pendingConfirm, setPendingConfirm] = useState(null);
  const [quickMenu, setQuickMenu] = useState(false);
  const [message, setMessage] = useState(null);

  const supervisor = resolveSupervisor();
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
    setSnapshot(snap);
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

  // Slower, non-blocking du + PR-checks pass over the current tasks.
  const tasks = (snapshot && snapshot.tasks) || [];
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

  const cards = tasks.map((t) =>
    buildCard(t, { duBytes: duById[t.id] ?? null, prChecks: prById[t.id] ?? null })
  );
  const grouped = groupCards(cards);
  const orderedIds = GROUP_ORDER.flatMap((g) => (grouped.get(g) || []).map((c) => c.id));

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
  });

  const doSend = useCallback(async (raw) => {
    const command = normalizeCommand(raw);
    if (!isSendable(command)) return;
    if (supervisor.error) {
      setMessage({ text: `cannot send: ${supervisor.error}`, color: 'red' });
      return;
    }
    setMessage({ text: `sending: ${command}`, color: 'cyan' });
    const res = await sendCommand({
      bin,
      home,
      target: supervisor.target,
      command,
    });
    if (!mounted.current) return;
    if (res.ok) {
      setMessage({ text: `sent: ${command}`, color: 'green' });
      setInput('');
    } else {
      setMessage({ text: `send failed (${res.code}): ${truncate(res.stderr, 60)}`, color: 'red' });
    }
  }, [bin, home, supervisor]);

  useInput((inputChar, key) => {
    // Ctrl-C handled by Ink's exit, but be explicit for clean quit.
    if (key.ctrl && inputChar === 'c') {
      exit();
      return;
    }

    // A pending destructive-confirm intercepts the next keystroke.
    if (pendingConfirm) {
      if (inputChar === 'y') {
        setInput(composeQuickAction(pendingConfirm.verb, selectedId));
        setMessage({ text: `composed ${pendingConfirm.verb} ${selectedId} - review and press Enter to send`, color: 'yellow' });
      } else {
        setMessage({ text: 'cancelled', color: 'gray' });
      }
      setPendingConfirm(null);
      return;
    }

    // The Tab-opened quick-action menu intercepts the next keystroke. This is
    // why free-typing never collides with the action keys: s/m/t only mean
    // "quick action" inside this menu, never in the plain input line.
    if (quickMenu) {
      setQuickMenu(false);
      if (key.escape) {
        setMessage({ text: 'cancelled', color: 'gray' });
        return;
      }
      const action = actionForKey(inputChar);
      if (action && selectedId) {
        if (action.destructive) {
          setPendingConfirm(action);
        } else {
          setInput(composeQuickAction(action.verb, selectedId));
          setMessage({ text: `composed ${action.verb} ${selectedId} - review and press Enter to send`, color: 'yellow' });
        }
      } else {
        setMessage({ text: 'cancelled', color: 'gray' });
      }
      return;
    }

    // Tab opens the quick-action menu for the selected task.
    if (key.tab) {
      if (selectedId) {
        setQuickMenu(true);
      } else {
        setMessage({ text: 'select a task first (↑/↓)', color: 'gray' });
      }
      return;
    }

    if (key.upArrow) {
      if (!orderedIds.length) return;
      const i = selectedId ? orderedIds.indexOf(selectedId) : 0;
      setSelectedId(orderedIds[Math.max(0, i - 1)]);
      return;
    }
    if (key.downArrow) {
      if (!orderedIds.length) return;
      const i = selectedId ? orderedIds.indexOf(selectedId) : -1;
      setSelectedId(orderedIds[Math.min(orderedIds.length - 1, i + 1)]);
      return;
    }

    if (key.return) {
      doSend(input);
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
  });

  const anyCards = cards.length > 0;

  return h(
    Box,
    { flexDirection: 'column', width },
    h(Header, { header, home, supervisor }),
    snapError
      ? h(Text, { color: 'red' }, `state read error: ${truncate(snapError, width - 20)}`)
      : null,
    anyCards
      ? h(
          Box,
          { flexDirection: 'column' },
          ...GROUP_ORDER.map((g) =>
            h(Group, { key: g, name: g, cards: grouped.get(g) || [], selectedId, width })
          )
        )
      : h(
          Box,
          { marginTop: 1 },
          h(Text, { color: 'green' }, 'Fleet is empty. Nothing in flight - a healthy resting state.')
        ),
    h(InputLine, { input, pendingConfirm, quickMenu, selectedId, message })
  );
}
