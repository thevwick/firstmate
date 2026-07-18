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
Firstmate marks a project as live-in-Cawldron so its own ship/scout crews refuse to spawn into that project's working tree while the captain may have unlanded, uncommitted edits sitting there - the same class of collision the worktree-isolation assertion in `bin/fm-spawn.sh` already guards against for firstmate's own crews, extended to cover a human editing session too.
Cawldron itself is not a party to this: it never reads or writes the lock, and does not know firstmate exists.
Firstmate sets and clears the lock explicitly (there is no auto-detection of a live Cawldron session); see `bin/fm-cawldron-lock.sh --help` for the exact marker format and commands.

## Code-vs-vault caveats

Two specific claims below were verified by reading the Cawldron repo directly (read-only; nothing there was changed), at commit `4b6b664` (2026-06-24), path `/Users/thev/cawldron/firstmate/projects/cawldron`.

**(a) Cawldron is claude-only in fact, though its agent registry is adapter-shaped for other CLIs.**
`packages/engine/src/agents.ts` documents itself as a v1, claude-only spike: its `AGENTS` registry (an array of `{id, bin, ...}` entries) has exactly one entry, `{id: "claude", bin: "claude"}`, with a trailing comment marking where `codex` / `opencode` / other CLIs would land.
But the actual invocation in `packages/engine/src/runAgent.ts` hardcodes `spawn("claude", args, ...)` directly - it does not look up `bin` from the registry at all.
So the registry's shape invites other adapters, but nothing today reads it generically; only `claude` runs.

**(b) The `runScopedEdit`-as-a-governance-action and the `{slug}` catalog promote/archive path are declared but not wired.**
`apps/desktop/src/main/services/contract-service.ts` defines an `EXECUTABLE` set of primitives the runner actually performs (`runCommand`, `commit`, `tag`, `branch`, `push`, `pull`, `revert`, `merge`, `move`, `copy`, `delete`, `fork`) - these do real git/fs work via `runShell`/`host.spawn`.
A separate `NOT_WIRED` map stubs `runScopedEdit` and `runAgentTask` with the placeholder reason `"Edit from the prompt box"`: they are named in the contract vocabulary but excluded from `EXECUTABLE`, so `blockedReason()` refuses them before anything runs.
Separately, `move`/`fork` steps that still contain an unfilled `{slug}` placeholder (the promote/archive catalog path in the example manifests) are blocked by the same function with `"Select a flow first — the catalog lands next"` - the primitives themselves are executable, but no catalog-selection UI exists yet to fill `{slug}`, so that path is unreachable end-to-end today.
Contrast this with gate-run and the rest of the git primitives, which do execute for real.

Also confirmed while reading: `apps/desktop` is a plain Electron app (`electron-vite dev`, `electron` as a direct dependency, the classic `main`/`preload`/`renderer` process split) with no headless or server entrypoint - reinforcing "Cawldron is not a firstmate backend" above.

These are point-in-time facts about an actively developed project; re-verify against the current Cawldron source before relying on them for anything beyond this document's own reasoning.

## One firstmate per project vs. a generic Cawldron

Firstmate is one fleet supervising a bounded set of registered projects; Cawldron is a generic tool any project can adopt independently of firstmate.
The repo is the join key between them: a project's `cawldron.yml` is committed *in that project's own repo*, not in firstmate's.
Firstmate is the discoverer, not the owner, of that contract - it reads a project's `cawldron.yml` (when reconciling gates/protected paths per the table above) the same way it reads any other committed project convention, never authoring or shipping one itself.

This is a separate relationship from the fact that Cawldron's own source happens to be cloned inside a firstmate home (`/Users/thev/cawldron/firstmate/projects/cawldron`, the path read for this document).
That clone means a firstmate instance *builds Cawldron* the same way it would build any other registered project - ordinary project-delivery work, unrelated to whether Cawldron is being used to *drive* some other product repo.
A firstmate developing Cawldron and a firstmate coordinating with a captain's live Cawldron session on an unrelated product repo are two independent relationships that happen to involve the same tool name.
