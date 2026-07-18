# Cawldron integration

This document records the design connection between **Cawldron** and firstmate: what each tool is, why they connect as two complementary tools sharing a repo rather than one being wired into the other, the contract reconciliation between them, and the one runtime coupling (the coordination lock, `bin/fm-cawldron-lock.sh`).
It is reference material, per the `firstmate-coding-guidelines` decision tree; the lock's own mechanics live in that script's header and `--help`, not here.

## What each tool is

Cawldron is a generic, self-hosted, human-in-the-loop coding shell: a captain drives it interactively (an Electron desktop app) to make scoped edits to a project's working tree in place, composing prompts for a coding CLI against a *running* app.
Firstmate is headless multi-agent delivery: it spawns and supervises autonomous crewmates that work a project's backlog to a PR with no human in the interaction loop.

## Why they connect as complementary tools, not by wiring one into the other

Cawldron and firstmate are two different shapes of "someone edits this repo": a human iterating live in a GUI, and a fleet of autonomous agents working a backlog headlessly.
They connect by **sharing the same repo and one reconciled contract** (below), not by firstmate driving Cawldron or Cawldron driving firstmate.

**Cawldron is not a firstmate backend.**
A firstmate backend (tmux, herdr, zellij, orca, cmux) is a session provider that firstmate supervises a *headless agent process* through - liveness checks, pane capture, turn-end signals, the whole supervision contract in section 8 of `AGENTS.md`.
Cawldron has no headless agent process for firstmate to supervise: it is a GUI a human drives.
There is nothing on the other end of a `fm-crew-state.sh`-style poll.

**Cawldron is not a firstmate harness.**
A firstmate harness (claude, codex, opencode, pi, grok) is a coding CLI firstmate launches directly with a brief.
Cawldron's "scoped edit" is a UI gesture - the captain highlighting an element or typing a prompt in Cawldron's prompt box - that composes a prompt for `claude`, the same CLI firstmate already drives as a harness (see "Code-vs-vault caveats" below: today, in fact, the *only* CLI Cawldron drives).
Cawldron is not a distinct adapter firstmate would add to its harness list; it is a different, human-mediated way of invoking the same underlying CLI.

## Contract reconciliation

Cawldron's per-project `cawldron.yml` (or `cawldron.yaml`) contract and firstmate's own delivery contract (`AGENTS.md` section 7) describe the same underlying concerns from two different angles.
Reconciling them, rather than merging them into one schema, is what lets both tools operate on the same repo without a captain having to keep two independent mental models in sync:

| Cawldron (`cawldron.yml`) | Firstmate (`AGENTS.md`) | What it is |
|---|---|---|
| `gates:` (gate name -> shell command) | The project's no-mistakes pipeline / CI checks | A named validation command that must pass before a change lands. |
| `protected:` (glob paths) | A brief's protected-paths instruction | Paths a change must not touch without deliberate, named authorization. |
| `fork -> gate -> promote` (a manifest action sequence) | `branch -> PR -> captain merge` | Isolate a change, validate it, then land it - the same three-stage shape, different tooling. |

None of these need code to bridge them: a project's `cawldron.yml` gate command and its no-mistakes pipeline command can simply be the same command, named twice; a `protected:` glob and a brief's protected-path instruction can name the same paths.
The reconciliation is a captain/crewmate authoring discipline, not a firstmate feature.

## The coordination lock: the one runtime coupling

The single point where firstmate and Cawldron actually touch at runtime is the coordination lock (`bin/fm-cawldron-lock.sh`, `docs/cawldron-integration.md` you are reading now, `AGENTS.md` section 7).
Firstmate marks a project as live-in-Cawldron so its own ship/scout crews refuse to spawn into that project's working tree - and a scout already there refuses to be promoted to ship, through the same shared gate - while the captain may have unlanded, uncommitted edits sitting there - the same class of collision the worktree-isolation assertion in `bin/fm-spawn.sh` already guards against for firstmate's own crews, extended to cover a human editing session too.
Cawldron itself is not a party to this: it never reads or writes the lock, and does not know firstmate exists.
Firstmate sets and clears the lock explicitly (there is no auto-detection of a live Cawldron session); see `bin/fm-cawldron-lock.sh --help` for the exact marker format and commands.
The refusal is overridable with `--force-locked` or `FM_SPAWN_FORCE_LOCKED=1` when the captain deliberately wants a crew there anyway, and session start surfaces every active lock as a `CAWLDRON_LOCK:` line.
The lock is scoped to the home that holds it: it gates only crews dispatched from that home, and does not propagate into secondmate homes.

## Code-vs-vault caveats

Two conclusions below came from reading the Cawldron repo directly (read-only; nothing there was changed) rather than assuming, but are recorded here only at the level firstmate's own design needs - not as a public audit of a separate, captain-owned project's internals.

**(a) Cawldron is claude-only in practice today, even though its design leaves room for other coding CLIs.**
This is why "Cawldron is not a firstmate harness" above holds cleanly: there is exactly one underlying CLI in the loop right now, and it is the same one firstmate already drives directly.

**(b) A couple of contract actions are named in Cawldron's vocabulary but not reachable end-to-end yet.**
Its scoped-edit governance action and a catalog-based promote/archive flow are declared in the contract but not wired to real execution - a detail worth knowing if a future integration were ever tempted to depend on either, since neither actually runs today.

These are point-in-time facts about an actively developed, captain-owned project; re-verify directly and privately against the current Cawldron source rather than treating this summary as a durable spec of its internals.

## One firstmate per project vs. a generic Cawldron

Firstmate is one fleet supervising a bounded set of registered projects; Cawldron is a generic tool any project can adopt independently of firstmate.
The repo is the join key between them: a project's `cawldron.yml` is committed *in that project's own repo*, not in firstmate's.
Firstmate is the discoverer, not the owner, of that contract - it reads a project's `cawldron.yml` (when reconciling gates/protected paths per the table above) the same way it reads any other committed project convention, never authoring or shipping one itself.

This is a separate relationship from the fact that Cawldron's own source happens to be cloned inside a firstmate home.
That clone means a firstmate instance *builds Cawldron* the same way it would build any other registered project - ordinary project-delivery work, unrelated to whether Cawldron is being used to *drive* some other product repo.
A firstmate developing Cawldron and a firstmate coordinating with a captain's live Cawldron session on an unrelated product repo are two independent relationships that happen to involve the same tool name.
