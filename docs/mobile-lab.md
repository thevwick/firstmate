# fm-mobile-lab

`bin/fm-mobile-lab.sh` builds and runs React Native branches on iOS simulators and physical devices.
It is a thin, transparent wrapper around each repo's own configured run command (`react-native run-ios` today; `npx expo run:ios` after the Expo migration), not a reimplementation of `xcodebuild`.
The RN/Expo CLI owns build, pods, install, and launch, which it gets right for free (workspace-versus-scheme resolution, a deterministic destination, install and launch handling).
The lab owns only the genuinely lab-specific parts: warm git-worktree slots, per-slot Metro ports, a `node_modules` cache, a pre-flight framework-slice compatibility gate, streaming build progress plus a logfile, a machine-readable build-status file, and a per-slot build lock.

The engine is generic and repo-agnostic, ships to every firstmate home, and is inert until a per-fleet config is created.
The captain's fleet-specific details (repo names, ports, run commands) live in a gitignored `config/mobile-lab.json`, so the shared template stays generic.

The design rationale, including why the previous `xcodebuild` reimplementation was rebuilt into this wrapper, is in `data/mobile-lab-audit-a7/report.md`.
The build-status file contract this engine emits is in `data/mobile-lab-status-contract.md`.

## Setup

The engine does nothing until you create `config/mobile-lab.json`.
Copy the committed example and edit it for your fleet:

```sh
mkdir -p config
cp docs/examples/mobile-lab.json config/mobile-lab.json
```

`config/mobile-lab.json` is gitignored (personal fleet state), like every other file under `config/`.
The committed template lives at `docs/examples/mobile-lab.json`.

### Config fields

The config is a single object with a `repos` map.
Each key is the repo name you pass on the command line; each value is an object:

| Field | Required | Meaning |
| --- | --- | --- |
| `clone` | no | Directory name under `projects/` holding the git clone. Defaults to the repo key. |
| `run_command` | for a build | The repo's own run command, which the lab wraps. E.g. `react-native run-ios --scheme 'Dashpivot Dev'`. Post-Expo this becomes `npx expo run:ios` with no lab code change. The lab appends the resolved target (`--udid <id>`) and this slot's Metro port (`--port <N>`); do not put a target or port in `run_command` yourself. |
| `default_branch` | no | Documentation only (the repo's default release branch). Not required to run. |
| `pkgmgr` | no | Documentation hint only. The engine detects the package manager per checkout from the lockfile, so this is not authoritative. |
| `metro_port_base` | no | Base Metro port for this repo's slots. Slot N gets `base + N`. Defaults to 8081. |
| `pool_size` | no | Number of warm slots for this repo. Defaults to 3. |

Give each repo a distinct `metro_port_base` range so their slots never collide.
The example uses 8101-8103 for sitemate-mobile and 8111-8113 for dashpivot-mobile.

The Xcode scheme, workspace, and configuration are the RN/Expo CLI's concern, so they live inside `run_command` (as `--scheme`, `--mode`, etc.), not as separate lab fields.
This is what lets the lab stay command-agnostic: it never parses or reasons about Xcode flags.

## Usage

```sh
fm-mobile-lab <repo> <branch> --sim|--device [--slot N]
fm-mobile-lab ls
fm-mobile-lab stop <slot-name>|--all
fm-mobile-lab gc
fm-mobile-lab doctor
```

Platform is explicit: you must pass `--sim` or `--device`, there is no default.
`<repo>` is a repo key from the config, not a path.
`<branch>` is fetched into a worktree of the clone; the clone itself is never modified.
`--slot N` pins to a specific 0-based slot instead of the automatic least-recently-used choice.

Run `fm-mobile-lab doctor` first on a new machine to see what is present (Xcode, CocoaPods, fnm, `lipo`/`vtool`, simulators, connected devices, disk headroom, config) and which platforms each configured repo can actually build for.

### What each step does

The lab runs seven canonical phases (the same phase vocabulary the status file emits).
Not every run hits every phase (a deps cache hit makes the deps phase near-instant).

1. `preflight` - resolve the concrete target (the booted simulator's udid for `--sim`, the connected device's udid for `--device`) and, after checkout, run the framework-slice gate. There is no vague `generic/platform=iOS Simulator` destination; the lab always resolves a specific udid.
2. `worktree` - fetch the branch (into the clone's object store only, never a checkout in the clone) and check it out in the slot's worktree (detached, so slots never collide over a branch).
3. `deps` - hash the lockfile. Cache hit restores `node_modules` by APFS clone; miss installs and then snapshots to the cache.
4. `pods`, then `compile`, `link`, `install` - all owned by the wrapped `run_command`. The lab assembles the full command (`run_command` + `--udid <target>` + `--port <slot-port>`), runs it from the slot with the fixed `RCT_METRO_PORT` in the environment, and streams and infers phases from the CLI's own output.

Between step 2 and step 3 the lab also detects the toolchain from the checkout (the package manager from the lockfile, the node version from `.nvmrc`/`.node-version`/`package.json` engines, switching via fnm when available) and starts Metro on this slot's fixed port.

### Pre-flight framework-slice gate

Before the build, the lab enumerates the app's vendored `*.framework` binaries and `*.a` static libraries under `ios/`, runs `lipo` and `vtool` on each, and confirms at least one carries a slice for the concrete target platform and arch.
If a vendored binary declares the target arch but has no slice for the target platform, the build fails fast with a one-line error naming the framework, the missing slice, and the viable alternative, instead of starting a long build that dies at link time.

The motivating case is dashpivot's FFmpeg framework: `ios/libavcodec.framework/libavcodec` carries only an `x86_64`-IOSSIMULATOR slice and an `arm64`-IOS (device) slice, with no `arm64`-simulator slice.
On Apple Silicon an arm64 simulator build therefore cannot link it, so `--sim` fails immediately with `libavcodec has no arm64-simulator slice ... re-run with --device`, and `--device` is the viable path.
`doctor` runs this same check per repo and reports which platforms are viable, so the incompatibility surfaces before any build.

### Streaming progress, logfile, and status file

While the wrapped command runs, the lab streams its output to the terminal and appends the full output to `state/build-<slot>.log`, so a wedged build is always diagnosable after the fact.
It prints a phase banner (with a `[index/total]` marker) at each inferred transition and a heartbeat line (`... still <phase> (Ns elapsed)`) on long phases, so slow is distinguishable from wedged.

It also writes a machine-readable status file at `state/lab-build-<slot>.json`, atomically (temp file then `mv`), on every phase transition and at least every 10 seconds.
The file follows the contract in `data/mobile-lab-status-contract.md`: phase, phase index/total, an honest percent (`null` when genuinely unknown; never a fake smooth bar; refined within `compile` only when the CLI emits a parseable `X/Y` count), status (`running`/`success`/`failed`), timestamps, the resolved target, the wrapped `run_command`, the logfile path, and, on failure, a specific `error` string.
A separate console reads this file to render a live Mobile Lab view; the lab is the sole writer of the contract.

### Per-slot build lock

A build takes an exclusive per-slot lock (an atomic `mkdir` of `state/<slot>.build.lock`, since macOS lacks `flock`) around the pods, build, and install sequence, so two builds into the same slot's derivedData cannot collide.
A second build into a locked slot fails fast with a clear message (use a different `--slot` or wait); set `FM_MOBILE_LAB_LOCK_WAIT=<seconds>` to make it wait instead.
A lock left by a dead process (a killed or crashed build) is detected via the recorded holder PID and cleared automatically.

### Fixed per-slot Metro port

Each slot owns a fixed Metro port (`metro_port_base + slot_index`), exported as `RCT_METRO_PORT` when the wrapped build runs and passed to the CLI as `--port`.
A compiled binary asks its own slot's port for the JS bundle, so a port mismatch across concurrent slots is avoided.

### Deps cache (kept); app cache (removed)

The `node_modules` cache is kept: restores are APFS copy-on-write clones (`cp -c`), so N warm slots do not cost N times the full `node_modules` size, and on a non-APFS volume the engine falls back to a full copy and says so.

There is no native-artifact (app) cache.
The audit proved a fingerprint-keyed `.app` cache can serve a wrong-arch binary (it cached an `x86_64` simulator build and later tried to install it on an `arm64` simulator), and its fingerprint did not include the resolved target arch or runtime.
The RN/Expo CLI does its own incremental build, so the app cache was removed rather than made correct.

### Disk headroom

The engine refuses a multi-GB clone or install when free disk is below `FM_MOBILE_LAB_MIN_FREE_GB` (default 15 GiB), loudly, rather than filling the disk.

## Subcommands

- `ls` lists slots (repo/branch/port/Metro state/last-used) and disk used per slot and for the `node_modules` cache.
- `stop <slot-name>|--all` stops a slot's Metro and frees the slot record; the worktree is left warm.
- `gc` prunes `node_modules` cache layers older than `FM_MOBILE_LAB_GC_DAYS` (default 14), logging everything it drops.
- `doctor` reports environment state (config presence, jq, node, fnm, Xcode, CocoaPods, `lipo`, `vtool`, watchman, available simulators, connected devices, disk headroom, filesystem type) and, per repo, which platforms are viable by the framework-slice check.

## Environment overrides

| Variable | Default | Effect |
| --- | --- | --- |
| `FM_MOBILE_LAB_CONFIG` | `$FM_HOME/config/mobile-lab.json` | Config path. |
| `FM_MOBILE_LAB_HOME` | `$HOME/.fm-mobile-lab` | Lab home (cache, slots, state). |
| `FM_MOBILE_LAB_MIN_FREE_GB` | `15` | Free-disk floor for a multi-GB operation. |
| `FM_MOBILE_LAB_GC_DAYS` | `14` | `gc` age threshold in days. |
| `FM_MOBILE_LAB_HEARTBEAT_SECS` | `10` | Heartbeat cadence (seconds) for a long build phase and the minimum status-file refresh interval. |
| `FM_MOBILE_LAB_LOCK_WAIT` | `0` | Seconds to wait for a busy slot's build lock before failing. |
| `FM_MOBILE_LAB_NO_METRO` | unset | When `1`, report the Metro port but do not start Metro. |

## Verification evidence

The two risky mechanics were de-risked by a smoke test before the original engine was built (`data/mobile-lab-smoketest-s4/report.md`, 2026-07-17), verdict green:

- APFS clonefile copy-on-write of a hoisted `node_modules` across a git-worktree boundary: PASS. The full 8.6 GiB, 188,165-file `node_modules` of sitemate-mobile cloned in about 71 seconds with near-zero additional disk, a fully functional module tree, and correct copy-on-write divergence. Caveat carried into the engine: clone time scales with file count, not byte count, so a slot restore is seconds-to-low-minutes, not instant.
- `RCT_METRO_PORT` baked at compile time: PASS on the mechanism and on the dual-Metro side-by-side requirement (two Metro servers on distinct fixed ports ran concurrently).

The FFmpeg slice incompatibility that motivates the pre-flight gate was verified against the live dashpivot slot (`data/mobile-lab-audit-a7/report.md`, 2026-07-18): `lipo -archs libavcodec` reports `x86_64 arm64`, `vtool -arch arm64 -show-build` reports `platform IOS` (device), and `vtool -arch x86_64 -show-build` reports `platform IOSSIMULATOR`, so there is no arm64-simulator slice and an Apple Silicon simulator build is impossible.

## Testing

`tests/fm-mobile-lab.test.sh` covers the unit-testable logic without a real build: package-manager and node-version detection, lockfile-hash determinism, per-slot port assignment, LRU slot picking, config parsing (including `run_command`), run-command assembly (the exact command string built from a config plus a resolved target and port), the framework-slice gate (with a fixture fat binary and stubbed `lipo`/`vtool`, asserting fail-fast for an incompatible target and pass for a compatible one), build-status-file emission (a contract-shaped JSON is written for a phase), and the per-slot build lock (a second build refuses a locked slot and a stale lock is cleared).
Full device and simulator builds cannot run in CI, so the tests exercise the logic (command assembly, gate, status shape, lock), not a real build.
The device-dependent build and launch are exercised on real hardware via `doctor` plus a live dry-run.
