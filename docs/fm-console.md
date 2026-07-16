# fm-console

`fm-console` is a full-screen terminal control surface for one firstmate home.
The captain runs it in a terminal tab and lives in it: it shows the whole fleet at a glance and lets the captain issue commands to the running primary firstmate session without switching tabs.
It is a pure terminal UI.
There is no web server, no browser, and no network port: it reads firstmate's on-disk state and shells out to the existing `bin/` helpers, nothing more.

## What it is

The console is a small Node + Ink package under `bin/fm-console/`, launched by the thin `bin/fm-console.sh` wrapper.
Ink was chosen because the engine already assumes Node is present, so the console adds no new language runtime, and it syncs as plain source with no compiled per-platform artifact.
The source is written with `React.createElement`, not JSX, so there is no build or transpile step.
`node_modules` is gitignored; the launcher installs the pinned dependencies once on first run.

## How to launch it

```sh
bin/fm-console.sh
```

The launcher self-locates this firstmate checkout, ensures the Ink package's dependencies are installed, and execs the app.
`FM_HOME` selects which firstmate home the console operates on, defaulting to the repo root, exactly as the rest of the lifecycle commands resolve it.
Arrow keys select a task, Tab opens a quick-action menu for the selected task (status, merge, teardown) that composes an instruction into the input line, Enter sends the current line, and Ctrl-C quits cleanly.
Quick-actions live behind the Tab menu on purpose, so the input line is always plain text and typing a command never collides with an action key.
`bin/fm-console.sh --check` boots the app headlessly and exits, which is what the smoke test drives.

## Layout

The console fills the whole terminal, top to bottom: a title bar, a compact one-line status strip, the board, an optional one-line footer warning, and the input line pinned at the bottom.

The status strip is deliberately a single line: disk free, a watcher liveness dot, the away-mode flag, an in-flight task count, and queued/blocked backlog counts.
There is no multi-line prose header; warnings (watcher down, command bridge disabled, a snapshot read error) collapse to the one-line footer instead of dominating the top of the screen.

The board is the main event and fills all remaining vertical space, organized into three bordered sections: IN FLIGHT, QUEUED, and RECENT DONE.
When nothing is in flight, QUEUED and RECENT DONE expand to fill the space with real backlog content instead of leaving a void - an idle fleet still shows something useful.
Ink has no scrolling, so each section's row count is computed and capped in JS (`computeRowBudget` in `state.js`) before anything is handed to Ink; a section with more content than its allotted space shows as many rows as fit plus a `… +N more` marker, never by letting the terminal's own overflow silently corrupt the render.
The layout reacts to terminal resize and degrades to a single stacked column below `MIN_COLS_FOR_FULL_LAYOUT`/`MIN_ROWS_FOR_FULL_LAYOUT` (`constants.js`) instead of clipping unreadably.

## What it shows

The board polls firstmate state on a short interval and redraws.
It does not re-parse fleet state itself: it reads the structured `fm-fleet-snapshot.sh --json` contract (schema `fm-fleet-snapshot.v1`), which is the one owner of fleet parsing and already carries each task's authoritative current state from `fm-crew-state.sh`.
On top of the snapshot the console computes a few header facts the snapshot omits: free space on the macOS Data volume via `df`, watcher liveness from the freshness of `state/.last-watcher-beat` (the same beacon and grace window `fm-guard.sh` uses), the away-mode flag from `state/.afk`, and backlog queued/blocked counts from the snapshot's backlog records.
A failed or timed-out snapshot read keeps the last good snapshot on screen rather than blanking the board - a transient read hiccup must never look like an empty fleet.

IN FLIGHT holds every live task card (from `state/<id>.meta`) whose state is not `done`, sub-grouped by state into NEEDS YOU, READY, WORKING, and BLOCKED.
A card is one line: the task id, repo, kind, PR checks status when present, and its current state or last event line.
Worktree size (`du`) and PR-checks (`gh-axi`) are read on a slower cadence and threaded in asynchronously, so a slow `du` or a torn-down worktree never freezes or crashes the board.
A ticket key parsed from the branch or brief (for example `SMM-2808`) shows as a small chip, but a ticket is optional metadata: a task without one, such as `poc/*` work, renders as first-class.
`fm-fleet-snapshot.sh` bounds each task's `fm-crew-state.sh` read to `FM_SNAPSHOT_CREW_STATE_TIMEOUT` seconds (default 8) so one slow or wedged `no-mistakes` call cannot blank the entire fleet out of the board - only that one task degrades to an `unknown` state.

QUEUED holds structured queued backlog records; RECENT DONE holds the most recent structured Done backlog records plus any live `done`-state task cards, most-recent-first.
An empty fleet is shown as the healthy resting state it is, not an error.

## The command bridge

The input line delivers the captain's typed or confirmed command into the running primary firstmate session, so firstmate receives it as if the captain had typed it in that pane.
It does this by shelling out to `bin/fm-send.sh` with an explicit backend target, so `fm-send`'s verified-submit, busy-guard, and composer-guard machinery applies unchanged: a command sent while firstmate is mid-turn defers cleanly instead of colliding.
The console adds no keystroke injection of its own.

The console resolves the primary pane fail-closed and never guesses an arbitrary pane.
It reuses the away-mode daemon's own auto-detect order (see [`configuration.md`](configuration.md) "Away-mode supervisor backend") rather than reinventing it: an explicit `FM_SUPERVISOR_TARGET`/`FM_SUPERVISOR_BACKEND` override wins first, then `$TMUX_PANE`, then `$HERDR_ENV=1` with `$HERDR_PANE_ID`.
A captain who has already set `FM_SUPERVISOR_TARGET` for `/afk` gets the bridge for free, as before; when the console happens to inherit firstmate's own pane environment (for example launched as a child of the primary session), the bridge now comes up enabled with no manual export needed.
When the console runs in a genuinely separate terminal tab whose own pane signals point at the console rather than firstmate, none of the above resolves to firstmate's pane and the bridge stays disabled with the on-screen notice, exactly as before - it is auto-detection of an already-verified signal, never a guess.

## Safety invariant

The bridge changes only where the captain issues a command, never what is allowed without approval.
The console never merges, tears down, or takes any destructive or irreversible action on its own: it only delivers the captain's instruction to firstmate, which still applies every existing gate (yolo off by default, captain approval for merges, teardowns, and destructive actions).
There is no auto-approve or bypass path.
Destructive quick-actions require an explicit confirm keystroke in the console before they even compose their text, and even then they only send the instruction for firstmate to gate.

## Tests

The Node package's unit tests cover the pure logic (state parsing, ticket extraction, card grouping, board-section derivation, row-budget math, command composition, and fail-closed-but-auto-detecting bridge target resolution), plus render tests that boot the app against a stubbed home with `ink-testing-library`, including a regression test for a rendering bug where multiple IN FLIGHT groups plus non-empty QUEUED/RECENT DONE content overflowed Ink's fixed-height layout and silently blanked card id lines.
`tests/fm-console.test.sh` is the shell smoke test: it verifies the launcher self-locates, the app boots headlessly without a crash, and the Node suite passes.
Run the Node suite alone with `npm test` inside `bin/fm-console/`.
