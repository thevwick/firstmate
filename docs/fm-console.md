# fm-console

`fm-console` is a full-screen terminal control surface for one firstmate home.
The captain runs it in a terminal tab and lives in it: it shows the whole fleet at a glance, shows firstmate's own live activity, and lets the captain issue commands to the running primary firstmate session - all from one window, with no need to ever switch to firstmate's own raw terminal pane.
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

The board is the main event and fills all remaining vertical space, organized into three bordered sections: IN FLIGHT (or FIRSTMATE ACTIVITY - see below), QUEUED, and RECENT DONE.
IN FLIGHT sizes to its own content instead of always claiming a fixed share of the board: with one or two cards in flight it hugs just enough height to show them, and whatever it does not use - all of it when nothing is in flight - flows to QUEUED and RECENT DONE instead of sitting empty, so the board never shows a half-empty box above a starved backlog view.
Once IN FLIGHT's content meets or exceeds its fair-share ceiling (a large fleet), it switches back to competing for space like the other two sections instead of clipping at a fixed size.
Ink has no scrolling, so each section's row count is computed and capped in JS (`computeRowBudget` and `inFlightContentRowCount` in `state.js`) before anything is handed to Ink; a section with more content than its allotted space shows as many rows as fit plus a `… +N more` marker, never by letting the terminal's own overflow silently corrupt the render.
The layout reacts to terminal resize and degrades to a single stacked column below `MIN_COLS_FOR_FULL_LAYOUT`/`MIN_ROWS_FOR_FULL_LAYOUT` (`constants.js`) instead of clipping unreadably; every row that can hold more than one field (the status strip, a card's headline, a backlog row) is set to never wrap onto a second line, degrading by truncating its least essential content instead.

## FIRSTMATE ACTIVITY: watching firstmate itself, not just the fleet

Before this panel, the console only showed CREWMATE tasks: when firstmate itself was working - reading, running commands, deciding - the console looked idle even though the one thing the captain most wants to watch (their own first mate) was busy.
FIRSTMATE ACTIVITY closes that gap: it is a live, read-only tail of firstmate's OWN pane, refreshed on the same poll interval as the rest of the board, so the captain watches firstmate work without ever switching to its raw terminal pane.
This is what makes the console a genuine single window: watch the fleet, watch firstmate, and issue commands, all from the same screen.

It reuses the exact same resolved supervisor target the command bridge already sends into (`bridge.js`'s `resolveSupervisor`), so the panel always shows the activity of the same firstmate the input line talks to - there is no separate resolution path to drift out of sync.
The capture itself shells out to `bin/fm-peek.sh`, the same plain, human-facing pane capture `fm-peek` uses for cheap diagnosis, never the styled composer-only reader (which captures a single cursor row for busy/idle classification, not a readable tail).
It is strictly read-only: it only ever reads pane content, and never sends a keystroke or otherwise interferes with firstmate.
Like every other slow or best-effort read in the console (worktree size, PR checks), the capture runs on its own async side-channel, polled on the board's normal refresh cadence, and is never awaited inline in render - a slow or wedged pane capture shows a stale-but-present frame (or a `capturing...` placeholder on first paint), never a freeze.
The captured text is tailed newest-at-bottom in `state.js`'s `firstmateActivityLines`, trimmed to whatever row budget the panel actually has, so it reads like watching a live terminal rather than a jumbled dump.

Layout choice: an idle fleet (IN FLIGHT empty, the common resting state) is the common case where the board's IN FLIGHT box would otherwise show only "Nothing in flight" - wasted space exactly when firstmate itself may still be busy.
FIRSTMATE ACTIVITY takes over that freed box at no extra row cost, so the biggest block of otherwise-idle space now shows the one thing the board previously could not.
When tasks are in flight, IN FLIGHT keeps its box as before (the fleet must never be crowded out to make room for this), and FIRSTMATE ACTIVITY instead renders as a slim, always-visible strip above the board - but only when the terminal has real slack beyond the existing compact-layout threshold (`MIN_ROWS_FOR_FULL_LAYOUT`); at a cramped terminal height the strip is dropped entirely rather than squeeze the fleet board unreadable, since the row-budget discipline above exists precisely to prevent that.
`Ctrl-A` toggles the strip taller when the captain wants more than a glance and there is room to spare.

If firstmate's pane cannot be resolved (the console launched in a separate tab with no `FM_SUPERVISOR_TARGET`, `$TMUX_PANE`, or herdr signal available - the same fail-closed case the command bridge already reports), the panel shows a clear one-line "not resolved" placeholder instead of guessing a pane, exactly mirroring the bridge's own safety rule: never capture an arbitrary pane.

## What it shows

The board polls firstmate state on a short interval and redraws.
It does not re-parse fleet state itself: it reads the structured `fm-fleet-snapshot.sh --json` contract (schema `fm-fleet-snapshot.v1`), which is the one owner of fleet parsing and already carries each task's authoritative current state from `fm-crew-state.sh`.
On top of the snapshot the console computes a few header facts the snapshot omits: free space on the macOS Data volume via `df`, watcher liveness from the freshness of `state/.last-watcher-beat` (the same beacon and grace window `fm-guard.sh` uses), the away-mode flag from `state/.afk`, and backlog queued/blocked counts from the snapshot's backlog records.
A failed or timed-out snapshot read keeps the last good snapshot on screen rather than blanking the board - a transient read hiccup must never look like an empty fleet.

IN FLIGHT holds every live task card (from `state/<id>.meta`) whose state is not `done`, sub-grouped by state into NEEDS YOU, READY, WORKING, and BLOCKED.
A card is two lines and color-coded by state end to end, not just a small dot: a left border stripe in the health color runs down both lines, so a card needing the captain reads red before the text is even parsed - a heat-map, not a detail to notice on close inspection.
Line 1 (the headline) is the task id in bold, then a colored state BADGE (`WORKING`, `NEEDS YOU`, `BLOCKED`, `STALE` - the badge prefers the crew's raw state over the coarser group label, so a wedged-but-not-yet-escalated crew reads STALE even though it is still filed under the WORKING group), the ticket chip when one was found, the `harness/model` chip with effort appended when it is not the harness default (for example `claude/sonnet` or `claude/opus high`), and the repo.
Line 2 (the metadata row) is dim, labeled, and space-separated rather than a run-on dot-joined sentence: worktree size, `age <duration>` since the task was spawned, `seen <duration> ago` since its last status update, the crew branch (conventionally `fm/<id>` for a ship task, omitted for scout/secondmate work), the PR number and checks status when a PR is recorded, the backend endpoint (the `window=` value, so the captain knows which tab to jump to), and the fuller current-state or last-event text trailing when it fits - narrowing by dropping the endpoint, then branch/PR, then size, one at a time below a width threshold rather than wrapping into soup.
The badge and border stripe both derive from the same health color: green means provably working or ready, yellow means the crew's raw state is `stale`, red means the card needs the captain (a decision, a block, or a failure), and dim grey means done or genuinely unknown.
It is derived from the same `fm-crew-state.sh` read the snapshot already threads through `current_state`, not a separate call.
Worktree size, age/last-event mtimes, and PR-checks are read on their own async side-channels and threaded in as they resolve (`…`/a grey dot placeholder until then), so a slow `du`, a slow `gh-axi` call, or a torn-down worktree never freezes or crashes the board; age/last-event use a cheap single `stat` per file so they refresh on the board's own fast cadence, while worktree size and PR-checks run on the slower `du` cadence.
A ticket key parsed from the branch or brief (for example `SMM-2808`) shows as a small chip, but a ticket is optional metadata: a task without one, such as `poc/*` work, renders as first-class.
`fm-fleet-snapshot.sh` bounds each task's `fm-crew-state.sh` read to `FM_SNAPSHOT_CREW_STATE_TIMEOUT` seconds (default 8) so one slow or wedged `no-mistakes` call cannot blank the entire fleet out of the board - only that one task degrades to an `unknown` state.
The row budget (`computeRowBudget` and `inFlightContentRowCount` in `state.js`) returns a terminal-line count, and the section-capping logic in `app.js` (`capRows`) accounts for each entry's actual row height - a group label is one row, a card is `CARD_ROW_HEIGHT` (two) - so a section can never be handed more rows than it has space for.
`inFlightContentRowCount` is also what lets IN FLIGHT's own box size to its content rather than a fixed share of the board (see "Layout" above).

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

The Node package's unit tests cover the pure logic (state parsing, ticket extraction, card grouping, board-section derivation, row-budget math including the content-sized IN FLIGHT behavior and `inFlightContentRowCount`, command composition, health-level mapping, model/effort profile formatting, branch derivation, fail-closed-but-auto-detecting bridge target resolution, and `firstmateActivityLines`' newest-at-bottom tail/trim behavior including null/empty input, trailing-blank trimming, over/under-budget tailing, and an unbounded `maxLines`), plus render tests that boot the app against a stubbed home with `ink-testing-library`, including a regression test for a rendering bug where multiple IN FLIGHT groups plus non-empty QUEUED/RECENT DONE content overflowed Ink's fixed-height layout and silently blanked card id lines, a render test confirming a card degrades gracefully (no crash, no blank chip) when harness/model/effort/branch/PR/endpoint are all absent from its snapshot task, a render test confirming a single in-flight card leaves QUEUED/RECENT DONE room instead of a half-empty IN FLIGHT box, a render test confirming the status strip stays one line at a narrow terminal width instead of wrapping onto a second row, a set of render tests guarding against a runaway-input regression where a failed send left the command sitting in the buffer and a per-keystroke-recreated input handler could double-append a character: a failed send still clears the input, a successful send still clears the input, a second Enter while a send is in flight never starts a second `fm-send.sh` call, a single keypress appends exactly one character, and typing N characters across many keystrokes and re-renders yields exactly N characters, and a set of FIRSTMATE ACTIVITY render tests (stubbing `bin/fm-peek.sh` the same way the bridge tests stub `bin/fm-send.sh`): the panel renders the captured pane lines in an idle fleet's freed IN FLIGHT box, it tails newest-at-bottom and drops older lines beyond its row budget rather than truncating the newest ones behind a "+N more" marker, it shows the fail-closed not-resolved placeholder (naming `FM_SUPERVISOR_TARGET`) when no supervisor target can be found, a slow/wedged capture never blocks the render (the rest of the board keeps drawing while the capture is still in flight), and in-flight cards and the compact activity strip render together at a tall enough terminal without either crowding the other out.
`tests/fm-console.test.sh` is the shell smoke test: it verifies the launcher self-locates, the app boots headlessly without a crash, and the Node suite passes.
Run the Node suite alone with `npm test` inside `bin/fm-console/`.
