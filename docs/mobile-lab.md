# fm-mobile-lab

`bin/fm-mobile-lab.sh` builds and runs React Native branches on iOS simulators and physical devices, with a cache that only rebuilds what a branch actually changed.
The common case, a JS-only branch change, is a checkout plus a Metro reload: no reinstall and no native rebuild.
Dependency changes restore-or-install; native changes rebuild once and are then cached.
JS is never cached (it is always served live from Metro), which is the deliberate line that keeps stale-cache ghosts out.

The engine is generic and repo-agnostic, ships to every firstmate home, and is inert until a per-fleet config is created.
The captain's fleet-specific details (repo names, ports, schemes, sim devices) live in a gitignored `config/mobile-lab.json`, so the shared template stays generic.

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
| `default_branch` | no | Documentation only today (the repo's default release branch). Not required to run. |
| `pkgmgr` | no | Documentation hint only. The engine detects the package manager per checkout from the lockfile, so this is not authoritative. |
| `ios_scheme` | for native build | The Xcode scheme name used by `xcodebuild`. Required only to run a real native build. The `.xcworkspace` is discovered under `ios/` at build time (it is named after the Xcode project, not the scheme). |
| `sim_device` | no | Default simulator device name (e.g. `iPhone 16 Pro`). |
| `metro_port_base` | no | Base Metro port for this repo's slots. Slot N gets `base + N`. Defaults to 8081. |
| `pool_size` | no | Number of warm slots for this repo. Defaults to 3. |

Give each repo a distinct `metro_port_base` range so their slots never collide.
The example uses 8101-8103 for sitemate-mobile and 8111-8113 for dashpivot-mobile.

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

Run `fm-mobile-lab doctor` first on a new machine to see what is present (Xcode, CocoaPods, fnm, simulators, connected devices, disk headroom, config).

### What each step does

1. Resolve the repo from config to its clone under `projects/`, and fetch the branch (into the clone's object store only, never a checkout in the clone).
2. Pick or reuse a slot for this repo (least-recently-used within the pool).
3. Check out the branch in the slot worktree (detached, so slots never collide over a branch).
4. Detect the toolchain from the checkout: the package manager from the lockfile (`pnpm-lock.yaml` -> pnpm, `yarn.lock` -> yarn, `package-lock.json` -> npm) and the node version from `.nvmrc`, `.node-version`, or `package.json` engines, switching via fnm when available.
5. Deps: hash the lockfile. Cache hit restores `node_modules` by APFS clone; miss installs and then snapshots to the cache.
6. Native: compute a self-computed fingerprint over `ios/Podfile`, `ios/Podfile.lock`, the native-relevant dependency set, `patches/` contents, and the platform. Cache hit for `(fingerprint, platform)` restores the prebuilt app; miss rebuilds and caches.
7. Metro: ensure Metro is running on this slot's fixed port.
8. Launch: install and boot the app on the chosen simulator or device, pointed at this slot's Metro.
9. Report: slot, port, what was cached versus rebuilt, ready.

### Fixed per-slot Metro port

Each slot owns a fixed Metro port (`metro_port_base + slot_index`).
The port is baked into that slot's build at compile time via `RCT_METRO_PORT` (written to `ios/.xcode.env.local`, which the React Native build phase sources and which is gitignored in the target repos).
A compiled binary therefore always asks its own slot's port for the JS bundle, so a port mismatch ("No script URL" / red screen) is structurally impossible.
Changing a slot's port forces a clean React-Core rebuild, because `RCT_METRO_PORT` is a compile-time C preprocessor constant and an incremental build would keep the old baked port.

### Disk headroom

The engine refuses a multi-GB clone or install when free disk is below `FM_MOBILE_LAB_MIN_FREE_GB` (default 15 GiB), loudly, rather than filling the disk.
`node_modules` restores are APFS copy-on-write clones (`cp -c`), so N warm slots do not cost N times the full `node_modules` size.
On a non-APFS volume the engine falls back to a full copy and says so.

### Native build and device launch

The device- and simulator-dependent tail (native build, install, boot) is gated behind `doctor`-style capability checks.
When the environment cannot build (no Xcode, no simulator runtime, no connected device, or tight disk) the engine still warms the slot (worktree checked out, deps ready, Metro up) and reports exactly what remains, then exits cleanly.
This is intentional: a JS-only workflow never needs a device, and the first real end-to-end iOS build on a given machine is the captain's one-time rollout smoke-check, not a prerequisite for the engine.

## Subcommands

- `ls` lists slots (repo/branch/port/Metro state/last-used) and disk used per slot and cache layer.
- `stop <slot-name>|--all` stops a slot's Metro and frees the slot record; the worktree is left warm.
- `gc` prunes cache layers that no live slot references and that are older than `FM_MOBILE_LAB_GC_DAYS` (default 14), logging everything it drops.
- `doctor` reports environment state: config presence, jq, node, fnm, Xcode, CocoaPods, watchman, available simulators, connected devices, disk headroom, and filesystem type.

## Environment overrides

| Variable | Default | Effect |
| --- | --- | --- |
| `FM_MOBILE_LAB_CONFIG` | `$FM_HOME/config/mobile-lab.json` | Config path. |
| `FM_MOBILE_LAB_HOME` | `$HOME/.fm-mobile-lab` | Lab home (cache, slots, state). |
| `FM_MOBILE_LAB_MIN_FREE_GB` | `15` | Free-disk floor for a multi-GB operation. |
| `FM_MOBILE_LAB_GC_DAYS` | `14` | `gc` age threshold in days. |
| `FM_MOBILE_LAB_NO_METRO` | unset | When `1`, report the Metro port but do not start Metro. |

## Verification evidence

The two risky mechanics were de-risked by a smoke test before the engine was built (`data/mobile-lab-smoketest-s4/report.md`, 2026-07-17), verdict green:

- APFS clonefile copy-on-write of a hoisted `node_modules` across a git-worktree boundary: PASS. The full 8.6 GiB, 188,165-file `node_modules` of sitemate-mobile cloned in about 71 seconds with near-zero additional disk, a fully functional module tree (verified by node module resolution and running `tsc` through the cloned tree), and correct copy-on-write divergence (the source was untouched when the clone was modified). Caveat carried into the engine: clone time scales with file count, not byte count, so a slot restore is seconds-to-low-minutes, not instant.
- `RCT_METRO_PORT` baked at compile time: PASS on the mechanism (traced through source in both target repos: build-phase script to the CocoaPods-generated xcconfig to the `RCT_METRO_PORT` preprocessor constant used to build the bundle URL) and PASS on the dual-Metro side-by-side requirement (two Metro servers on distinct fixed ports ran concurrently). The one gap is that a full end-to-end iOS build was not run in the scout (no simulator runtime installed and a near-full disk), so the engine gates the native build and install behind `doctor` checks and treats the first real build as the captain's rollout smoke-check. Caveat carried into the engine: a port change must force a clean React-Core recompile, or the old port stays baked in.

## Testing

`tests/fm-mobile-lab.test.sh` covers the unit-testable pure logic without a device: package-manager detection from a lockfile, node-version detection, lockfile and native-fingerprint hashing determinism (and that a JS-only change does not bust the native fingerprint), per-slot port assignment, LRU slot picking, config parsing, and the "no config prints guidance and exits non-zero" path.
The device-dependent build and launch are exercised on real hardware via `doctor` plus the captain's rollout smoke-check.
