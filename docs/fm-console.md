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

## What it shows

The board polls firstmate state on a short interval and redraws.
It does not re-parse fleet state itself: it reads the structured `fm-fleet-snapshot.sh --json` contract (schema `fm-fleet-snapshot.v1`), which is the one owner of fleet parsing and already carries each task's authoritative current state from `fm-crew-state.sh`.
On top of the snapshot the console computes a few header facts the snapshot omits: free space on the macOS Data volume via `df`, watcher liveness from the freshness of `state/.last-watcher-beat` (the same beacon and grace window `fm-guard.sh` uses), the away-mode flag from `state/.afk`, and backlog queued/blocked counts from the snapshot's backlog records.

Each in-flight or known task renders as one card, keyed on its stable firstmate task id and grouped by state into NEEDS YOU, READY, WORKING, BLOCKED, and DONE.
A card shows the task id, repo, current state, last event line, PR link and checks status when present, and the task's worktree size on disk.
Worktree size is a first-class column: it is how the captain watches build and dependency bloat accumulate before it becomes a disk crisis.
Worktree size (`du`) and PR-checks (`gh-axi`) are read on a slower cadence and threaded in asynchronously, so a slow `du` or a torn-down worktree never freezes or crashes the board.
A ticket key parsed from the branch or brief (for example `SMM-2808`) shows as a small chip, but a ticket is optional metadata: a task without one, such as `poc/*` work, renders as first-class.
An empty fleet is shown as the healthy resting state it is, not an error.

## The command bridge

The input line delivers the captain's typed or confirmed command into the running primary firstmate session, so firstmate receives it as if the captain had typed it in that pane.
It does this by shelling out to `bin/fm-send.sh` with an explicit backend target, so `fm-send`'s verified-submit, busy-guard, and composer-guard machinery applies unchanged: a command sent while firstmate is mid-turn defers cleanly instead of colliding.
The console adds no keystroke injection of its own.

Because the console runs in its own terminal tab, its own runtime pane signals point at the console, not at firstmate's pane, so auto-detecting a target from them would send commands to the console itself.
The console therefore resolves the primary pane fail-closed and never guesses: it reuses the away-mode daemon's `FM_SUPERVISOR_TARGET` and `FM_SUPERVISOR_BACKEND` conventions (see [`configuration.md`](configuration.md) "Away-mode supervisor backend"), and when no target is set it disables the bridge with an on-screen notice rather than sending to an unknown pane.
A captain who has already set those for `/afk` gets the bridge for free.

## Safety invariant

The bridge changes only where the captain issues a command, never what is allowed without approval.
The console never merges, tears down, or takes any destructive or irreversible action on its own: it only delivers the captain's instruction to firstmate, which still applies every existing gate (yolo off by default, captain approval for merges, teardowns, and destructive actions).
There is no auto-approve or bypass path.
Destructive quick-actions require an explicit confirm keystroke in the console before they even compose their text, and even then they only send the instruction for firstmate to gate.

## Tests

The Node package's unit tests cover the pure logic (state parsing, ticket extraction, card grouping, command composition, and fail-closed bridge target resolution), plus render tests that boot the app against a stubbed home with `ink-testing-library`.
`tests/fm-console.test.sh` is the shell smoke test: it verifies the launcher self-locates, the app boots headlessly without a crash, and the Node suite passes.
Run the Node suite alone with `npm test` inside `bin/fm-console/`.
