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
| `sim_device` | no | For the x86_64-via-Rosetta `--sim` path only: a device-name substring (e.g. `iPhone 16`) to prefer when the lab must pick an x86_64-capable (iOS <= 18) simulator. Ignored for the native arm64 sim path and for `--device`. |
| `sim_runtime` | no | For the x86_64-via-Rosetta `--sim` path only: an exact iOS runtime version (e.g. `18.5`) to prefer when picking the x86_64-capable simulator. Ignored otherwise. |

Give each repo a distinct `metro_port_base` range so their slots never collide.
The example uses 8101-8103 for sitemate-mobile and 8111-8113 for dashpivot-mobile.

The Xcode scheme, workspace, and configuration are the RN/Expo CLI's concern, so they live inside `run_command` (as `--scheme`, `--mode`, etc.), not as separate lab fields.
This is what lets the lab stay command-agnostic: it never parses or reasons about Xcode flags.

## Usage

```sh
fm-mobile-lab <repo> <branch> --sim|--device [--slot N] [--wait]
fm-mobile-lab ls
fm-mobile-lab stop <slot-name>|--all
fm-mobile-lab gc
fm-mobile-lab doctor
```

Platform is explicit: you must pass `--sim` or `--device`, there is no default.
`<repo>` is a repo key from the config, not a path.
`<branch>` is fetched into a worktree of the clone; the clone itself is never modified.
`--slot N` pins to a specific 0-based slot instead of the automatic least-recently-used choice.
`--wait` (alias `--foreground`) blocks until the build finishes and exits with its status, for CI and scripts; by default the build is detached and the command returns as soon as the build is launched (see "Detached build" below).

Run `fm-mobile-lab doctor` first on a new machine to see what is present (Xcode, CocoaPods, fnm, `lipo`/`vtool`, simulators, connected devices, disk headroom, config) and which platforms each configured repo can actually build for.

### What each step does

The lab runs seven canonical phases (the same phase vocabulary the status file emits).
Not every run hits every phase (a deps cache hit makes the deps phase near-instant).

1. `preflight` - resolve the concrete target (the booted simulator's udid for `--sim`, the connected device's udid for `--device`) and, after checkout, resolve the simulator build arch and run the framework-slice gate (see "Pre-flight framework-slice gate and simulator arch resolution"). For the x86_64-via-Rosetta sim path the target may be re-resolved to an x86_64-capable (iOS <= 18) simulator after the arch is known.
2. `worktree` - fetch the branch (into the clone's object store only, never a checkout in the clone) and check it out in the slot's worktree (detached, so slots never collide over a branch).
3. `deps` - hash the lockfile. Cache hit restores `node_modules` by APFS clone; miss installs and then snapshots to the cache.
4. `pods`, then `compile`, `link`, `install` - all owned by the wrapped `run_command`. The lab assembles the full command (`run_command` + `--udid <target>` + `--port <slot-port>`), runs it from the slot with the fixed `RCT_METRO_PORT` in the environment, and streams and infers phases from the CLI's own output. Before invoking `run_command`, the `pods` phase runs `pod install` itself when the slot is missing `ios/Pods/` or the app target's `Pods-*.xcconfig` (see "CocoaPods install" below).

Between step 2 and step 3 the lab also detects the toolchain from the checkout (the package manager from the lockfile, the node version from `.nvmrc`/`.node-version`/`package.json` engines, switching via fnm when available) and starts Metro on this slot's fixed port.

Steps 1-3 (plus Metro) run synchronously when you invoke the lab; the long native build in step 4 is then launched detached and runs on its own (see "Detached build").

### Pre-flight framework-slice gate and simulator arch resolution

Before the build, the lab enumerates the app's vendored `*.framework` binaries and `*.a` static libraries under `ios/`, runs `lipo` and `vtool` on each, and confirms every vendored binary carries a slice for the target platform and the build arch.

For `--device` the build arch is the host arch, and the gate fails fast (naming the framework and missing slice) when a vendored binary has no matching device slice.

For `--sim` the lab resolves the build arch by trying two viable paths in order:

1. **Native arm64.** If every vendored framework has an `arm64`-simulator slice, the sim build uses the host arch (arm64 on Apple Silicon), the fast native path.
2. **x86_64 via Rosetta.** If there is no `arm64`-simulator slice but every vendored framework has an `x86_64`-simulator slice, and Rosetta can run x86_64 on the host, the lab builds the sim app as `x86_64` (forcing `ARCHS=x86_64` through the RN CLI's `--extra-params`) and runs it on the simulator under Rosetta.

The motivating case is dashpivot's FFmpeg frameworks: `ios/libavcodec.framework/libavcodec` (and the other FFmpeg frameworks) carry only an `x86_64`-IOSSIMULATOR slice and an `arm64`-IOS (device) slice, with no `arm64`-simulator slice.
A native arm64 sim build cannot link them, so the lab takes the x86_64-via-Rosetta path instead: this is how dashpivot runs on the simulator.
Only if neither path is viable (no simulator slice at all, or an x86_64-only sim app with no Rosetta) does `--sim` fail fast, steering to `--device`.

An `x86_64` simulator build has one further constraint: Apple dropped x86_64 execution from the iOS 26 simulator runtimes, so an x86_64 app installs and runs only on a simulator whose runtime is iOS 18 or earlier (an iOS 26+ simulator rejects it with "Needs to Be Updated").
When the x86_64 path is chosen, the lab therefore targets an x86_64-capable simulator: it reuses an already-booted iOS <= 18 simulator, otherwise picks one (honouring the repo's optional `sim_device` / `sim_runtime` config hints, else the newest iOS <= 18 iPhone) and boots it.
If no iOS <= 18 runtime is installed at all, the build fails fast with a message steering to install an older runtime in Xcode or use `--device`.
(This iOS 18 boundary is verified live: an x86_64 dashpivot build installed and launched on an iOS 18.5 simulator via Rosetta, while the iOS 26.4 simulator refused the same binary. See "Verification evidence".)

`doctor` runs this same resolution per repo and reports which platforms are viable, including `viable (x86_64 via Rosetta)` for the FFmpeg case, so the path surfaces before any build.

### Streaming progress, logfile, and status file

While the wrapped command runs, the lab streams its output to the terminal and appends the full output to the lab's own private state dir (`<lab home>/state/build-<slot>.log`, `~/.fm-mobile-lab/state` by default), so a wedged build is always diagnosable after the fact.
It prints a phase banner (with a `[index/total]` marker) at each inferred transition and a heartbeat line (`... still <phase> (Ns elapsed)`) on long phases, so slow is distinguishable from wedged.

It also writes a machine-readable status file at `state/lab-build-<slot>.json` under **firstmate's own** state dir (`$FM_HOME/state`, resolved the same way every other `bin/` script resolves it: `FM_STATE_OVERRIDE`, else `$FM_HOME/state`), not the lab's private home, because that is what the console's `readLabBuildStatuses` scans.
The file is written atomically (temp file then `mv`) on every phase transition and at least every 10 seconds.
The file follows the contract in `data/mobile-lab-status-contract.md`: phase, phase index/total, an honest percent (`null` when genuinely unknown; never a fake smooth bar; refined within `compile` only when the CLI emits a parseable `X/Y` count), status (`running`/`success`/`failed`), timestamps, the resolved target, the wrapped `run_command`, a `metro_running` boolean (whether Metro is actually answering on the slot's port, refreshed from a real liveness probe on every write), and, on failure, a specific `error` string.
The `logfile` field is an absolute path to the build log under the lab's own private state dir, since that log does not live alongside the status file: an absolute path is what lets the console (or a captain) actually open it regardless of which state dir they are reading from.
A separate console reads the status file to render a live Mobile Lab view; the lab is the sole writer of the contract.

### Detached build

A native iOS build runs for 10-15 minutes, so its lifetime is decoupled from whoever invoked the lab.
After the synchronous setup (preflight, worktree, deps, Metro), the lab launches the native build (pods, compile, link, install) in a process that has its own session and is detached from the caller's controlling terminal and stdio, then returns immediately, printing `build started in slot <slot>` plus where to watch it (the status file and the logfile).
The build keeps running to completion even if the process that invoked `fm-mobile-lab` exits, is killed, or times out (a background task, a shell with a time limit, a reaped process).
This is what makes a real device build completable: a reaped caller can no longer kill an in-progress build.

The detached build always reaches a terminal status on its own exit.
On success or a build failure it writes `success`/`failed` as before; and an exit trap catches the build process itself being killed or crashing and writes a terminal `failed` (`build process terminated ...`), so a killed build never leaves a zombie file stuck at `running`.
The build's owning pid is recorded in the status file's `pid` field, so a reader can tell a live build from a zombie `running` file with `kill -0 <pid>`.
When a new build starts in a slot whose previous status file is still `running` but whose recorded `pid` is no longer alive, the lab reaps that zombie (rewrites it `failed`) before starting.

Pass `--wait` (or `--foreground`) to block until the build finishes and exit with the build's own status, which is the behavior CI and scripts want.

### CocoaPods install

The `deps` cache clones `node_modules` by APFS from a shared layer, so the RN CLI sees an already-populated `node_modules` and skips its own `pod install`.
But `Pods/` is not part of `node_modules`: a fresh slot worktree can have `ios/` with no `Pods/`, and the build then dies with `Unable to open base configuration reference file ... Pods-<App>.debug.xcconfig` because the pod-generated xcconfig the Xcode project references was never produced.
So the `pods` phase runs `pod install` itself when the slot is missing `ios/Pods/` or the app target's `Pods-*.xcconfig` under `ios/Pods/Target Support Files`.
It uses `bundle exec pod install` when a `Gemfile` is present (the repo pins CocoaPods via bundler), otherwise `pod install`, run in the slot's `ios/` dir under the fnm-switched node.
A pod-install failure is loud and fails the build (rather than proceeding to the same xcconfig death).

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
| `FM_MOBILE_LAB_NO_PODS` | unset | When `1`, report the `pod install` that would run but do not run it. |
| `FM_MOBILE_LAB_LIB` | unset | When `1`, sourcing the script defines its functions without running `main`; the test hook. |
| `FM_MOBILE_LAB_X86_SIM_MAX_MAJOR` | `18` | Highest iOS major version whose simulator runtime still runs x86_64 apps under Rosetta. The x86_64-via-Rosetta sim path targets a runtime at or below this; raise it only if a future iOS restores x86_64 simulator support. |
| `FM_MOBILE_LAB_FORCE_ROSETTA` | unset | Test-only override for the Rosetta probe: `1` forces "Rosetta available", `0` forces "not available", unset probes with `arch -x86_64`. |

## Verification evidence

The two risky mechanics were de-risked by a smoke test before the original engine was built (`data/mobile-lab-smoketest-s4/report.md`, 2026-07-17), verdict green:

- APFS clonefile copy-on-write of a hoisted `node_modules` across a git-worktree boundary: PASS. The full 8.6 GiB, 188,165-file `node_modules` of sitemate-mobile cloned in about 71 seconds with near-zero additional disk, a fully functional module tree, and correct copy-on-write divergence. Caveat carried into the engine: clone time scales with file count, not byte count, so a slot restore is seconds-to-low-minutes, not instant.
- `RCT_METRO_PORT` baked at compile time: PASS on the mechanism and on the dual-Metro side-by-side requirement (two Metro servers on distinct fixed ports ran concurrently).

The FFmpeg slice layout that drives the sim-arch resolution was verified against the live dashpivot slot (`data/mobile-lab-audit-a7/report.md`, 2026-07-18): `lipo -archs libavcodec` reports `x86_64 arm64`, `vtool -arch arm64 -show-build` reports `platform IOS` (device), and `vtool -arch x86_64 -show-build` reports `platform IOSSIMULATOR`. So there is no arm64-simulator slice; a native arm64 simulator build is impossible, but an x86_64-simulator build is available.

The x86_64-via-Rosetta simulator path was verified live on an Apple Silicon Mac (arm64), 2026-07-18:

- `arch -x86_64 /usr/bin/true` succeeds, so Rosetta can run x86_64 here.
- Building dashpivot's `release/26.9` for the simulator with `ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO` (via `react-native run-ios --extra-params`, which the RN 0.80 CLI forwards to xcodebuild against its `generic/platform=iOS Simulator` sim destination) linked the FFmpeg `x86_64`-simulator slices and reached `** BUILD SUCCEEDED **`.
- The produced `Dashpivot.app` binary is `Mach-O 64-bit executable x86_64` (`lipo -archs` reports `x86_64`; `vtool` reports `platform IOSSIMULATOR`).
- That x86_64 app installed and launched on an iOS 18.5 simulator (`com.au.constructioncloud`, pid live in `launchctl`, splash screen rendered), running via Rosetta on the arm64 host.
- The same x86_64 app was REFUSED by the iOS 26.4 simulator ("Failed to find matching arch ... Needs to Be Updated"), which is why the lab targets an iOS <= 18 runtime for the x86_64 path.

A native x86_64-host build is not exercised here (this machine is Apple Silicon); on such a host the sim build is simply the native arch and no Rosetta is involved.

## Testing

`tests/fm-mobile-lab.test.sh` covers the unit-testable logic without a real device build: package-manager and node-version detection, lockfile-hash determinism, per-slot port assignment, LRU slot picking, config parsing (including `run_command`), run-command assembly (the exact command string built from a config plus a resolved target and port), the framework-slice gate (with a fixture fat binary and stubbed `lipo`/`vtool`, asserting fail-fast for an incompatible target and pass for a compatible one), build-status-file emission (a contract-shaped JSON is written for a phase, including the `pid` field), the per-slot build lock (a second build refuses a locked slot and a stale lock is cleared), stale-zombie reaping (a `running` file with a dead `pid` is marked `failed`, a live-`pid` or terminal file is left), and the CocoaPods gap (`pod install` runs when `Pods/` or the app xcconfig is missing, with a stubbed `pod`/`bundle`).
It also drives the detached-build behavior end to end against the real binary with a stubbed CLI: the default invocation launches detached and returns before the build finishes, the build runs to a terminal status on its own, a killed detached build writes a terminal `failed` (no zombie), `--wait` blocks until completion and propagates the exit code, and a new build reaps a stale zombie slot file.
Full device and simulator builds cannot run in CI, so the tests exercise the logic and the process-level detach/terminal-status behavior with a stubbed CLI, not a real xcodebuild.
The device-dependent build and launch are exercised on real hardware via `doctor` plus a live dry-run.
