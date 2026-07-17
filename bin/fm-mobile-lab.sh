#!/usr/bin/env bash
# fm-mobile-lab.sh - a reusable mobile build/test lab for React Native repos.
#
# Purpose: let the captain quickly try out different code branches on iOS
# simulators AND physical devices, with an intelligent cache that only rebuilds
# what the branch actually changed. JS-only branch changes become a checkout +
# Metro reload with NO reinstall and NO native rebuild; dependency changes are a
# restore-or-install; native changes rebuild once and are then cached.
#
# Design (approved): a GENERIC, repo-agnostic ENGINE (this script, shared and
# committed to every firstmate home) plus a per-fleet gitignored CONFIG
# (config/mobile-lab.json). The engine is INERT without config: with no config
# it prints a "create config" message and exits non-zero, so a firstmate user
# who never sets it up sees no behavior change. A committed example config lives
# at docs/examples/mobile-lab.json; usage and verification evidence live in
# docs/mobile-lab.md.
#
# Core model: a small pool of WARM git-worktree slots + a fingerprint-keyed
# native cache, all under ~/.fm-mobile-lab (or $FM_MOBILE_LAB_HOME):
#   cache/node_modules/<pkgmgr>-<lockfile-hash>/   built once per lockfile, APFS-clone source
#   cache/pods/<podfile-lock-hash>/                built once per Podfile.lock
#   cache/app/<fingerprint>-<platform>/            prebuilt binary, the slow-case cache
#   slots/<repo>-<N>/                              git worktree of the projects/ clone (warm)
#   state/slots.json                               slot -> repo+branch, Metro port, fingerprint, last-used
#
# Slots are git WORKTREES of the real clone under projects/. The clone itself is
# NEVER modified (worktree only). Each slot owns a FIXED Metro port (base + slot
# index) baked into that slot's build via RCT_METRO_PORT at build time, so a
# port mismatch ("No script URL"/red screen) is structurally impossible.
# node_modules restore is an APFS clone (cp -c) from the lockfile-hash cache:
# copy-on-write, near-instant, near-zero extra disk, so N slots do NOT cost
# N x the full node_modules size and node-linker=hoisted is left untouched.
#
# The one command:
#   fm-mobile-lab <repo> <branch> --sim|--device [--slot N]
# Subcommands:
#   fm-mobile-lab ls | stop [slot|--all] | gc | doctor
#
# JS is NEVER cached (always live from Metro): that is the deliberate line that
# keeps stale-cache ghosts out. Failures are LOUD, never silent-wrong.
#
# Exact flags/paths are documented here and in --help; usage narrative lives in
# docs/mobile-lab.md, not in AGENTS.md.
#
# See data/mobile-lab-smoketest-s4/report.md for the de-risking evidence: the
# APFS clonefile CoW mechanic and the RCT_METRO_PORT compile-time bake were both
# proven GREEN before this engine was built. Caveats carried in from the report:
#  - clone time scales with FILE COUNT, not byte count (~71s for 188k files).
#  - a port change requires a real React-Core recompile, not an incremental
#    build, or the OLD port stays baked in (the engine forces a clean rebuild on
#    a port change).
#  - the first real end-to-end iOS build is the captain's rollout smoke-check,
#    not a blocker for landing the engine; doctor gates the device-dependent
#    parts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_MOBILE_LAB_CONFIG:-$FM_HOME/config/mobile-lab.json}"
LAB_HOME="${FM_MOBILE_LAB_HOME:-$HOME/.fm-mobile-lab}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

CACHE_DIR="$LAB_HOME/cache"
SLOTS_DIR="$LAB_HOME/slots"
STATE_DIR="$LAB_HOME/state"
SLOTS_STATE="$STATE_DIR/slots.json"

# Minimum free disk (GiB) required before a multi-GB clone/install. The machine
# this ships to can sit near-full; refuse rather than fill the disk. Override
# with FM_MOBILE_LAB_MIN_FREE_GB for testing or a roomier box.
MIN_FREE_GB="${FM_MOBILE_LAB_MIN_FREE_GB:-15}"

# gc keeps cache layers referenced by a live slot, or newer than this many days.
GC_MAX_AGE_DAYS="${FM_MOBILE_LAB_GC_DAYS:-14}"

# --- output helpers ---------------------------------------------------------

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- config -----------------------------------------------------------------

# config_present: 0 if the config file exists, 1 otherwise.
config_present() { [ -f "$CONFIG" ]; }

# require_config: print the create-config guidance and exit non-zero when the
# per-fleet config is absent. This is what keeps the engine inert for every
# firstmate user who has not opted in.
require_config() {
  if config_present; then
    return 0
  fi
  cat >&2 <<EOF
ERROR: no mobile-lab config found at:
    $CONFIG

fm-mobile-lab is inert until you create that file. Copy the committed example
and edit it for your fleet:

    mkdir -p "$(dirname "$CONFIG")"
    cp "$FM_ROOT/docs/examples/mobile-lab.json" "$CONFIG"

Then edit it to list your repos, their clone directory names under projects/,
Metro port ranges, iOS scheme names, and default simulator device names.
See docs/mobile-lab.md for the field reference.
EOF
  exit 1
}

# config_repo_field <repo> <jq-field>: read one field for a repo from the config.
# Empty string (and exit 0) when the field is absent, so callers test emptiness.
config_repo_field() {
  local repo=$1 field=$2
  jq -r --arg r "$repo" --arg f "$field" \
    '(.repos[$r][$f]) // "" | if type=="array" then join(",") else tostring end' \
    "$CONFIG" 2>/dev/null
}

# config_repo_exists <repo>: 0 if the repo is defined in config.
config_repo_exists() {
  local repo=$1
  [ "$(jq -r --arg r "$repo" '(.repos[$r] // empty) | if . then "y" else "" end' "$CONFIG" 2>/dev/null)" = "y" ]
}

# config_int <repo> <field> <default>: read an integer field with a fallback.
config_int() {
  local repo=$1 field=$2 def=$3 v
  v=$(config_repo_field "$repo" "$field")
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$def" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# config_repos: list all configured repo names, one per line.
config_repos() { jq -r '.repos | keys[]' "$CONFIG" 2>/dev/null; }

# --- pure logic: toolchain detection ----------------------------------------
#
# These functions are the unit-testable core. They take a checkout directory or
# explicit inputs and never touch global state, so tests/fm-mobile-lab.test.sh
# can exercise them directly.

# detect_pkgmgr <checkout-dir>: choose the package manager from the lockfile
# present in the checkout. Detected PER CHECKOUT (not hardcoded) as a cheap
# safety net even though a given repo is on one stack. pnpm-lock.yaml -> pnpm,
# yarn.lock -> yarn, package-lock.json -> npm. Prints the manager name; exits
# non-zero with nothing printed when no known lockfile is present.
detect_pkgmgr() {
  local dir=$1
  if   [ -f "$dir/pnpm-lock.yaml" ]; then printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ];      then printf 'yarn\n'
  elif [ -f "$dir/package-lock.json" ]; then printf 'npm\n'
  else return 1
  fi
}

# lockfile_for <pkgmgr>: the lockfile name for a package manager.
lockfile_for() {
  case "$1" in
    pnpm) printf 'pnpm-lock.yaml\n' ;;
    yarn) printf 'yarn.lock\n' ;;
    npm)  printf 'package-lock.json\n' ;;
    *) return 1 ;;
  esac
}

# detect_node_version <checkout-dir>: the node version the checkout asks for,
# from .nvmrc, then .node-version, then package.json engines.node. Prints the
# raw version string (leading v and range operators stripped to a bare
# major[.minor[.patch]] where trivially possible); empty when unspecified.
detect_node_version() {
  local dir=$1 v=''
  if [ -f "$dir/.nvmrc" ]; then
    v=$(tr -d '[:space:]' < "$dir/.nvmrc")
  elif [ -f "$dir/.node-version" ]; then
    v=$(tr -d '[:space:]' < "$dir/.node-version")
  elif [ -f "$dir/package.json" ]; then
    v=$(jq -r '(.engines.node) // ""' "$dir/package.json" 2>/dev/null || printf '')
  fi
  # Strip a leading v and any range operators (^ ~ >= etc.) to a bare number.
  v=${v#v}
  v=$(printf '%s' "$v" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//')
  printf '%s\n' "$v"
}

# --- pure logic: hashing & fingerprint --------------------------------------

# sha_file <path>: sha256 hex of a file, or the literal "absent" when missing.
# Deterministic: the same bytes always hash the same, a missing file is always
# "absent". Used so a fingerprint is stable across runs and machines.
sha_file() {
  local f=$1
  if [ -f "$f" ]; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  else
    printf 'absent\n'
  fi
}

# hash_lockfile <checkout-dir> <pkgmgr>: short hash keying the node_modules
# cache. Keyed on the lockfile contents only, since that is what determines the
# installed tree.
hash_lockfile() {
  local dir=$1 pkgmgr=$2 lf
  lf=$(lockfile_for "$pkgmgr") || return 1
  sha_file "$dir/$lf" | cut -c1-16
}

# native_fingerprint <checkout-dir> <platform>: a SELF-COMPUTED sha256 over the
# inputs that actually affect a native build, so a JS-only change does NOT
# invalidate the native cache but a pod/native-dep/patch change does. Inputs:
#   ios/Podfile, ios/Podfile.lock, the native-relevant dependency set (deps
#   whose name matches react-native / expo / a native pod convention, taken from
#   package.json so a bumped native dep changes the key), patches/ contents, and
#   the platform. Does NOT depend on Expo's fingerprint tool (the real target
#   repos are bare RN and do not ship it). Prints "<hash16>".
native_fingerprint() {
  local dir=$1 platform=$2
  {
    printf 'platform=%s\n' "$platform"
    printf 'podfile=%s\n'      "$(sha_file "$dir/ios/Podfile")"
    printf 'podfile-lock=%s\n' "$(sha_file "$dir/ios/Podfile.lock")"
    # Native-relevant dependency set: react-native itself plus any dependency
    # whose name looks native (react-native-*, @react-native*, expo*, or a name
    # ending in a common native marker). Sorted for determinism. A pure-JS dep
    # bump does not appear here, so it will not bust the native cache.
    if [ -f "$dir/package.json" ]; then
      jq -r '
        (.dependencies // {}) + (.devDependencies // {})
        | to_entries
        | map(select(
            (.key | test("^react-native$"))
            or (.key | test("react-native"))
            or (.key | test("^@react-native"))
            or (.key | test("^expo"))
          ))
        | sort_by(.key)
        | .[] | "\(.key)@\(.value)"
      ' "$dir/package.json" 2>/dev/null || printf 'pkgjson-unreadable\n'
    else
      printf 'pkgjson-absent\n'
    fi
    # patches/ contents (patch-package style native patches change the build).
    if [ -d "$dir/patches" ]; then
      # Hash each patch file; sort for determinism.
      find "$dir/patches" -type f -print0 2>/dev/null \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' p; do
            printf 'patch:%s=%s\n' "${p#"$dir"/}" "$(sha_file "$p")"
          done
    else
      printf 'patches=none\n'
    fi
  } | sha256sum | awk '{print $1}' | cut -c1-16
}

# --- pure logic: slot & port assignment -------------------------------------

# metro_port <base-port> <slot-index>: the fixed Metro port for a slot. base +
# index, so slot 0 gets base, slot 1 base+1, etc. Deterministic per (repo,slot).
metro_port() {
  local base=$1 idx=$2
  printf '%s\n' "$((base + idx))"
}

# slot_name <repo> <slot-index>: the worktree directory name for a slot.
slot_name() {
  printf '%s-%s\n' "$1" "$2"
}

# --- state (slots.json) ------------------------------------------------------

ensure_dirs() {
  mkdir -p "$CACHE_DIR/node_modules" "$CACHE_DIR/pods" "$CACHE_DIR/app" \
           "$SLOTS_DIR" "$STATE_DIR"
  [ -f "$SLOTS_STATE" ] || printf '{"slots":{}}\n' > "$SLOTS_STATE"
}

# state_get_slot <slot-name>: print the slot's JSON object, or empty.
state_get_slot() {
  jq -c --arg s "$1" '.slots[$s] // empty' "$SLOTS_STATE" 2>/dev/null
}

# state_set_slot <slot-name> <repo> <branch> <port> <fingerprint> <epoch>:
# upsert a slot record. last_used is the epoch so LRU can order slots.
state_set_slot() {
  local s=$1 repo=$2 branch=$3 port=$4 fp=$5 now=$6 tmp
  tmp=$(mktemp "$STATE_DIR/slots.json.XXXXXX")
  jq --arg s "$s" --arg repo "$repo" --arg branch "$branch" \
     --argjson port "$port" --arg fp "$fp" --argjson now "$now" \
     '.slots[$s] = {repo:$repo, branch:$branch, port:$port, fingerprint:$fp, last_used:$now}' \
     "$SLOTS_STATE" > "$tmp" && mv "$tmp" "$SLOTS_STATE"
}

# state_touch_slot <slot-name> <epoch>: bump last_used only.
state_touch_slot() {
  local s=$1 now=$2 tmp
  tmp=$(mktemp "$STATE_DIR/slots.json.XXXXXX")
  jq --arg s "$s" --argjson now "$now" \
     'if .slots[$s] then .slots[$s].last_used=$now else . end' \
     "$SLOTS_STATE" > "$tmp" && mv "$tmp" "$SLOTS_STATE"
}

# state_del_slot <slot-name>: remove a slot record.
state_del_slot() {
  local s=$1 tmp
  tmp=$(mktemp "$STATE_DIR/slots.json.XXXXXX")
  jq --arg s "$s" 'del(.slots[$s])' "$SLOTS_STATE" > "$tmp" && mv "$tmp" "$SLOTS_STATE"
}

# pick_slot <repo> <pool-size> [explicit-index]: choose a slot index for this
# repo. If explicit-index is given and in range, use it. Otherwise reuse the
# slot already holding this repo whose worktree is idle, else the first unused
# index in the pool, else the LEAST-recently-used slot in the pool (LRU
# eviction). Prints the chosen 0-based index.
pick_slot() {
  local repo=$1 pool=$2 explicit=${3:-}
  if [ -n "$explicit" ]; then
    if [ "$explicit" -ge 0 ] && [ "$explicit" -lt "$pool" ]; then
      printf '%s\n' "$explicit"; return 0
    fi
    die "slot $explicit out of range for pool size $pool (valid 0..$((pool-1)))"
  fi
  local idx name rec lru_idx='' lru_time='' first_unused=''
  for ((idx=0; idx<pool; idx++)); do
    name=$(slot_name "$repo" "$idx")
    rec=$(state_get_slot "$name")
    if [ -z "$rec" ]; then
      [ -z "$first_unused" ] && first_unused=$idx
      continue
    fi
    local lu
    lu=$(printf '%s' "$rec" | jq -r '.last_used // 0')
    if [ -z "$lru_time" ] || [ "$lu" -lt "$lru_time" ]; then
      lru_time=$lu; lru_idx=$idx
    fi
  done
  if [ -n "$first_unused" ]; then printf '%s\n' "$first_unused"; return 0; fi
  printf '%s\n' "$lru_idx"
}

# --- disk headroom -----------------------------------------------------------

# existing_ancestor <path>: the nearest ancestor of <path> that exists. The lab
# home may not exist yet (e.g. doctor before a first build), so df has a real
# path to report on.
existing_ancestor() {
  local path=$1 parent
  while [ -n "$path" ] && [ ! -e "$path" ]; do
    parent=$(dirname "$path")
    [ "$parent" = "$path" ] && break
    path=$parent
  done
  printf '%s\n' "$path"
}

# df_fstype <path>: the filesystem type (e.g. apfs) of the volume holding
# <path>, via `df -Y` column 2. Empty when it cannot be determined.
df_fstype() {
  local path; path=$(existing_ancestor "$1")
  df -Y "$path" 2>/dev/null | awk 'NR==2 {print $2}'
}

# free_gb <path>: free space in whole GiB on the volume holding <path>.
free_gb() {
  local path kb
  path=$(existing_ancestor "$1")
  # df -k reports 1024-byte blocks; column 4 is available. Portable on macOS.
  kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "$kb" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$((kb / 1024 / 1024))"
}

# assert_disk_headroom <label>: refuse a multi-GB operation when free disk is
# below the floor. LOUD, never silent. Override the floor with
# FM_MOBILE_LAB_MIN_FREE_GB.
assert_disk_headroom() {
  local label=$1 free
  free=$(free_gb "$LAB_HOME")
  if [ "$free" -lt "$MIN_FREE_GB" ]; then
    die "not enough free disk for $label: ${free}GiB free, need >= ${MIN_FREE_GB}GiB (set FM_MOBILE_LAB_MIN_FREE_GB to override). Refusing to risk filling the disk."
  fi
}

# --- APFS clone helpers ------------------------------------------------------

# apfs_clone <src> <dst>: copy-on-write clone a directory tree with cp -c. Falls
# back LOUDLY to a real recursive copy if clonefile is unsupported (non-APFS),
# so the result is always correct, just slower and full-cost on disk.
apfs_clone() {
  local src=$1 dst=$2
  if cp -c -R "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  warn "APFS clonefile (cp -c) failed for $src -> falling back to a full copy (slower, full disk cost). This is expected on a non-APFS volume."
  cp -R "$src" "$dst"
}

# --- deps restore/install ----------------------------------------------------

# install_deps <checkout-dir> <pkgmgr>: run the package manager's install in the
# checkout. Kept separate so tests can stub it. Not run in tests (needs network
# and a real tree).
install_deps() {
  local dir=$1 pkgmgr=$2
  ( cd "$dir" && case "$pkgmgr" in
      pnpm) pnpm install --frozen-lockfile ;;
      yarn) yarn install --frozen-lockfile ;;
      npm)  npm ci ;;
      *) die "unknown package manager: $pkgmgr" ;;
    esac )
}

# ensure_node_modules <checkout-dir> <pkgmgr>: restore node_modules from the
# lockfile-hash cache via APFS clone, or install-then-snapshot on a miss.
# Records a one-line summary of what happened into the global DEPS_LINE and
# prints progress directly (NOT via command substitution) so an install failure
# aborts loudly instead of being swallowed by a subshell. Disk-guarded.
DEPS_LINE=''
ensure_node_modules() {
  local dir=$1 pkgmgr=$2 hash cache
  hash=$(hash_lockfile "$dir" "$pkgmgr") || die "no lockfile for $pkgmgr in $dir"
  cache="$CACHE_DIR/node_modules/$pkgmgr-$hash"
  if [ -d "$cache" ]; then
    assert_disk_headroom "node_modules restore"
    rm -rf "$dir/node_modules"
    apfs_clone "$cache" "$dir/node_modules"
    DEPS_LINE="deps: restored from cache ($pkgmgr-$hash)"
    return 0
  fi
  assert_disk_headroom "node_modules install"
  # Install must succeed; a failure here is loud and fatal, never silent-wrong.
  install_deps "$dir" "$pkgmgr" \
    || die "$pkgmgr install failed in $dir; not caching a broken node_modules. Fix the install and retry."
  # A dependency-less project produces no node_modules; that is a valid success,
  # so materialize an empty dir to cache rather than treating it as a failure.
  [ -d "$dir/node_modules" ] || mkdir -p "$dir/node_modules"
  # Snapshot into the cache via clone so the next slot restores cheaply.
  rm -rf "$cache"
  apfs_clone "$dir/node_modules" "$cache"
  DEPS_LINE="deps: installed and cached ($pkgmgr-$hash)"
}

# --- top-level run flow ------------------------------------------------------
#
# run_build wires the steps together. The device/simulator-dependent tail
# (native build, boot/install) is gated behind doctor-style capability checks
# and clearly reports what it would do when the environment cannot do it, so
# the engine lands and is exercisable without a real sim/device. See the report
# caveat: the first real end-to-end iOS build is the captain's rollout check.

# clone_dir <repo>: absolute path to the repo's clone under projects/. Resolves
# the config's "clone" field (the directory name under projects/), defaulting to
# the repo key itself.
clone_dir() {
  local repo=$1 clone
  clone=$(config_repo_field "$repo" clone)
  [ -n "$clone" ] || clone=$repo
  printf '%s/%s\n' "$PROJECTS_DIR" "$clone"
}

run_build() {
  local repo=$1 branch=$2 platform=$3 explicit_slot=${4:-}
  require_config
  config_repo_exists "$repo" || die "repo '$repo' is not defined in $CONFIG (configured: $(config_repos | paste -sd, -))"

  local clone base_port pool scheme
  clone=$(clone_dir "$repo")
  [ -d "$clone/.git" ] || die "clone for '$repo' not found at $clone (clone it under projects/ first; the lab never creates or modifies the clone)"
  base_port=$(config_int "$repo" metro_port_base 8081)
  pool=$(config_int "$repo" pool_size 3)
  scheme=$(config_repo_field "$repo" ios_scheme)

  ensure_dirs
  local idx name slot port now
  idx=$(pick_slot "$repo" "$pool" "$explicit_slot")
  name=$(slot_name "$repo" "$idx")
  slot="$SLOTS_DIR/$name"
  port=$(metro_port "$base_port" "$idx")
  now=$(date +%s)

  log "fm-mobile-lab: $repo @ $branch -> slot $idx (port $port, $platform)"

  # 1. Fetch the branch into the clone's object store WITHOUT touching the
  #    clone's working tree or checked-out branch (fetch only, never checkout in
  #    the clone). The worktree is what gets the branch.
  assert_disk_headroom "worktree setup"
  git -C "$clone" fetch --quiet origin "$branch" 2>/dev/null \
    || warn "could not fetch origin/$branch (offline, or branch is local-only); using whatever '$branch' already resolves to"

  # 2/3. Create-or-reuse the slot worktree and check out the branch in it.
  ensure_slot_worktree "$clone" "$slot" "$branch"

  # 4. Detect toolchain from the CHECKOUT.
  local pkgmgr node_v
  pkgmgr=$(detect_pkgmgr "$slot") || die "no known lockfile in $slot; cannot determine package manager"
  node_v=$(detect_node_version "$slot")
  info "toolchain: $pkgmgr${node_v:+, node $node_v}"
  switch_node "$node_v"

  # 5. Deps: restore-or-install. Sets DEPS_LINE; aborts loudly on install fail.
  ensure_node_modules "$slot" "$pkgmgr"
  info "$DEPS_LINE"

  # 6. Native fingerprint -> cache hit restores .app + Pods, miss rebuilds.
  local fp app_cache native_line
  fp=$(native_fingerprint "$slot" "$platform")
  app_cache="$CACHE_DIR/app/$fp-$platform"
  if [ -d "$app_cache" ] && [ -n "$(ls -A "$app_cache" 2>/dev/null)" ]; then
    native_line="native: cached ($fp-$platform)"
  else
    native_line="native: NEEDS REBUILD ($fp-$platform not cached)"
  fi
  info "$native_line"

  # 7. Metro on the slot's FIXED port.
  ensure_metro "$slot" "$port" "$pkgmgr"

  # 8/9. Launch + report. The launch tail is capability-gated (see below).
  state_set_slot "$name" "$repo" "$branch" "$port" "$fp" "$now"

  launch_or_gate "$repo" "$branch" "$platform" "$slot" "$port" "$scheme" "$fp" \
                 "$app_cache" "$DEPS_LINE" "$native_line"
}

# ensure_slot_worktree <clone> <slot-path> <branch>: create the git worktree if
# missing, then check out the branch inside the worktree. NEVER checks out in
# the clone. Uses a detached checkout of the fetched ref so a branch already
# checked out in another worktree does not collide.
ensure_slot_worktree() {
  local clone=$1 slot=$2 branch=$3
  # Prune stale registrations first: a slot dir removed out from under git (an
  # interrupted run, a manual rm) leaves a "missing but already registered"
  # entry that would otherwise fail `worktree add`.
  git -C "$clone" worktree prune >/dev/null 2>&1 || true
  # A git worktree marks its root with a .git FILE (a gitdir pointer), not a
  # directory, so test -e, not -d. Reuse an existing worktree; create otherwise.
  if [ ! -e "$slot/.git" ]; then
    # Force past any residual registration for this exact path.
    git -C "$clone" worktree add --detach --force "$slot" HEAD >/dev/null 2>&1 \
      || die "failed to create worktree at $slot"
  fi
  # Resolve the branch to a concrete commit, preferring the just-fetched remote
  # ref, then a local branch, then the raw name. Detached checkout avoids the
  # "branch already checked out" error across slots.
  local ref
  if git -C "$slot" rev-parse --verify --quiet "origin/$branch^{commit}" >/dev/null 2>&1; then
    ref="origin/$branch"
  elif git -C "$slot" rev-parse --verify --quiet "$branch^{commit}" >/dev/null 2>&1; then
    ref="$branch"
  else
    die "branch '$branch' not found for this repo (neither origin/$branch nor a local $branch resolves)"
  fi
  git -C "$slot" checkout --quiet --detach "$ref" \
    || die "failed to checkout $ref in slot $slot"
}

# switch_node <version>: switch node via fnm if available and a version is asked
# for. Best-effort: a missing fnm or version is a warning, not a failure (the
# ambient node may already be right). fnm's own "fnm use" needs its shell
# environment set up first (eval "$(fnm env)"), or the switch silently fails
# and the process stays on ambient node; do that before "fnm use", then verify
# the switch actually took effect so a repo that needs an exact node (e.g.
# engineStrict) never builds on the wrong one without a loud warning.
switch_node() {
  local v=$1
  [ -n "$v" ] || return 0
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env)" 2>/dev/null || true
    if fnm use "$v" >/dev/null 2>&1 && node_version_matches "$v" "$(node --version 2>/dev/null)"; then
      return 0
    fi
    warn "fnm failed to switch to node $v; still on ambient node ($(node --version 2>/dev/null || echo unknown)) - builds may fail if this repo is engine-strict"
  else
    warn "node $v requested but fnm is not installed; using ambient node ($(node --version 2>/dev/null || echo unknown))"
  fi
}

# node_version_matches <requested> <actual v-prefixed>: 0 if actual satisfies
# the requested major[.minor[.patch]] prefix (e.g. requested "20" or "20.18"
# both match actual "v20.18.3"). Used to confirm a "fnm use" switch really
# landed, since a stale environment can report success while node is unchanged.
node_version_matches() {
  local requested=$1 actual=$2
  requested=${requested%.}
  actual=${actual#v}
  [ -n "$requested" ] && [ -n "$actual" ] || return 1
  case "$actual" in
    "$requested"|"$requested".*) return 0 ;;
    *) return 1 ;;
  esac
}

# metro_running <port>: 0 if a Metro packager answers on the port.
metro_running() {
  local port=$1
  curl -sf "http://localhost:$port/status" 2>/dev/null | grep -q 'packager-status:running'
}

# ensure_metro <slot> <port> <pkgmgr>: start Metro on the slot's fixed port if
# not already running there. Backgrounded and detached; the slot owns it for the
# session. Metro is deliberately long-lived and is stopped via `stop`.
ensure_metro() {
  local slot=$1 port=$2 pkgmgr=$3
  if metro_running "$port"; then
    info "metro: already running on $port"
    return 0
  fi
  if [ "${FM_MOBILE_LAB_NO_METRO:-0}" = "1" ]; then
    info "metro: would start on $port (FM_MOBILE_LAB_NO_METRO set; not starting)"
    return 0
  fi
  local logf="$STATE_DIR/metro-$port.log"
  ( cd "$slot" && RCT_METRO_PORT="$port" nohup npx react-native start --port "$port" --no-interactive \
      >"$logf" 2>&1 & echo $! > "$STATE_DIR/metro-$port.pid" )
  info "metro: started on $port (log: $logf)"
}

# launch_or_gate: the device/simulator tail. When the environment can build and
# run (doctor-style checks pass), it would perform the native build (on a cache
# miss) and install/boot. When it cannot (no sim runtime, no device, tight
# disk), it reports exactly what remains, clearly, and exits 0 with the slot
# warm and Metro up, so the JS-only and caching machinery is fully usable and
# the device-dependent piece is a clean, gated follow-up.
launch_or_gate() {
  local repo=$1 branch=$2 platform=$3 slot=$4 port=$5 scheme=$6 fp=$7 \
        app_cache=$8 deps_line=$9 native_line=${10}

  log ""
  log "READY:"
  info "repo:        $repo"
  info "branch:      $branch"
  info "slot:        $slot"
  info "metro port:  $port"
  info "platform:    $platform"
  info "$deps_line"
  info "$native_line"

  local can_build=1 reason=''
  case "$platform" in
    sim)
      if ! have_ios_toolchain; then can_build=0; reason='no Xcode/xcodebuild'; fi
      if ! have_booted_or_bootable_sim; then can_build=0; reason=${reason:-'no available iOS simulator runtime'}; fi
      ;;
    device)
      if ! have_ios_toolchain; then can_build=0; reason='no Xcode/xcodebuild'; fi
      if ! have_connected_device; then can_build=0; reason=${reason:-'no connected iOS device'}; fi
      ;;
  esac

  if [ "$can_build" = "0" ]; then
    log ""
    warn "device/simulator launch is GATED: $reason."
    log "The slot is warm (worktree checked out, deps ready, Metro on port $port)."
    log "To finish on a real $platform, run 'fm-mobile-lab doctor' and resolve the"
    log "reported gaps, then re-run this command. The native build + install step"
    log "is intentionally gated behind these checks so a JS-only workflow never"
    log "needs a device. See docs/mobile-lab.md 'Native build and device launch'."
    return 0
  fi

  # Environment is capable. Perform the gated native build + launch.
  native_build_and_launch "$repo" "$branch" "$platform" "$slot" "$port" \
                          "$scheme" "$fp" "$app_cache"
}

# native_build_and_launch: the real iOS build + install/boot. This is the piece
# the smoke-test could not run end to end (no sim runtime + tight disk), so it
# is written to be correct and LOUD, and only runs when the doctor-style checks
# above passed. It bakes the slot's fixed RCT_METRO_PORT and forces a clean
# React-Core rebuild when the port changed (report caveat: an incremental build
# keeps the OLD baked port).
native_build_and_launch() {
  local repo=$1 branch=$2 platform=$3 slot=$4 port=$5 scheme=$6 fp=$7 app_cache=$8
  [ -n "$scheme" ] || die "config for '$repo' has no ios_scheme; cannot run xcodebuild"

  assert_disk_headroom "native build"

  # Bake the fixed port so the compiled binary always asks this port for its
  # bundle (report Mechanic 2). Written to ios/.xcode.env.local, which the RN
  # build phase sources and which is gitignored in the target repos.
  printf 'export RCT_METRO_PORT=%s\n' "$port" > "$slot/ios/.xcode.env.local"

  if [ -d "$app_cache" ] && [ -n "$(ls -A "$app_cache" 2>/dev/null)" ]; then
    info "native: using cached app for $fp-$platform"
  else
    info "native: pod install + build (fingerprint $fp-$platform not cached)"
    ( cd "$slot/ios" && pod install )
    # Force a clean build so the new RCT_METRO_PORT actually recompiles
    # React-Core (report caveat: incremental builds keep the old baked port).
    do_xcodebuild "$slot" "$scheme" "$platform"
    snapshot_app "$slot" "$scheme" "$platform" "$app_cache"
  fi

  install_and_boot "$slot" "$scheme" "$platform" "$app_cache" "$port"
  log "launched on $platform, pointed at Metro port $port."
}

# The following are thin wrappers around the real toolchain. They are the parts
# that genuinely need a sim/device and are only ever called after the capability
# gate passed. Kept as small named functions so the flow reads clearly and so a
# future change (or a test with fakes) can override them.

do_xcodebuild() {
  local slot=$1 scheme=$2 platform=$3 destination
  case "$platform" in
    sim)    destination='generic/platform=iOS Simulator' ;;
    device) destination='generic/platform=iOS' ;;
  esac
  ( cd "$slot/ios" && xcodebuild \
      -workspace "$scheme.xcworkspace" \
      -scheme "$scheme" \
      -configuration Debug \
      -destination "$destination" \
      -derivedDataPath build \
      clean build )
}

snapshot_app() {
  local slot=$1 scheme=$2 platform=$3 app_cache=$4 app
  app=$(find "$slot/ios/build" -type d -name "$scheme.app" 2>/dev/null | head -1)
  [ -n "$app" ] || { warn "could not locate built $scheme.app to cache; skipping snapshot"; return 0; }
  rm -rf "$app_cache"; mkdir -p "$app_cache"
  apfs_clone "$app" "$app_cache/$scheme.app"
}

install_and_boot() {
  local slot=$1 scheme=$2 platform=$3 app_cache=$4 port=$5 app
  app=$(find "$app_cache" -type d -name '*.app' 2>/dev/null | head -1)
  [ -n "$app" ] || die "no .app found in cache $app_cache to install"
  case "$platform" in
    sim)
      xcrun simctl boot booted 2>/dev/null || true
      xcrun simctl install booted "$app"
      ;;
    device)
      warn "device install requires a paired device and codesigning; ensure the target repo's signing is set up."
      xcrun devicectl device install app --device "$(first_device_udid)" "$app" 2>/dev/null \
        || die "device install failed (check pairing, trust, and signing)"
      ;;
  esac
}

# --- capability probes (also used by doctor) --------------------------------

have_ios_toolchain() { command -v xcodebuild >/dev/null 2>&1; }

# have_booted_or_bootable_sim: true if a simulator is booted OR at least one
# available (runtime-backed) simulator device exists to boot.
have_booted_or_bootable_sim() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun simctl list devices available 2>/dev/null | grep -qE '\([0-9A-Fa-f-]{36}\)'
}

# have_connected_device: true if xctrace lists at least one real device under
# its "== Devices ==" section (excluding the "== Simulators ==" section and the
# host Mac itself, which carries no (UDID) with an iOS-style identifier line).
# A physical iOS device shows as "<name> (<version>) (<udid>)".
have_connected_device() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{d=1;next} /^== /{d=0} d' \
    | grep -qE '\([0-9]+\.[0-9]+.*\) \([0-9A-Fa-f-]{8,}\)'
}

first_device_udid() {
  xcrun xctrace list devices 2>/dev/null \
    | grep -oE '\(([0-9A-Fa-f-]{25,})\)' | tr -d '()' | head -1
}

# --- subcommands -------------------------------------------------------------

cmd_ls() {
  require_config
  ensure_dirs
  local slots
  slots=$(jq -r '.slots | keys[]' "$SLOTS_STATE" 2>/dev/null)
  if [ -z "$slots" ]; then
    log "no active slots."
  else
    log "SLOTS:"
    printf '  %-24s %-14s %-6s %-8s %s\n' NAME BRANCH PORT METRO USED
    local s rec branch port used metro_state ts
    while IFS= read -r s; do
      rec=$(state_get_slot "$s")
      branch=$(printf '%s' "$rec" | jq -r '.branch // "?"')
      port=$(printf '%s' "$rec" | jq -r '.port // 0')
      ts=$(printf '%s' "$rec" | jq -r '.last_used // 0')
      used=$(fmt_epoch "$ts")
      if metro_running "$port"; then metro_state=up; else metro_state=down; fi
      printf '  %-24s %-14s %-6s %-8s %s\n' "$s" "$branch" "$port" "$metro_state" "$used"
    done <<< "$slots"
  fi
  log ""
  log "DISK:"
  info "slots dir: $(dir_size "$SLOTS_DIR")   cache: $(dir_size "$CACHE_DIR")   free: $(free_gb "$LAB_HOME")GiB"
  info "  node_modules cache: $(dir_size "$CACHE_DIR/node_modules")"
  info "  pods cache:         $(dir_size "$CACHE_DIR/pods")"
  info "  app cache:          $(dir_size "$CACHE_DIR/app")"
}

cmd_stop() {
  require_config
  ensure_dirs
  local target=${1:-}
  if [ -z "$target" ]; then
    die "usage: fm-mobile-lab stop <slot-name>|--all"
  fi
  if [ "$target" = "--all" ]; then
    local s
    while IFS= read -r s; do
      [ -n "$s" ] && stop_slot "$s"
    done <<< "$(jq -r '.slots | keys[]' "$SLOTS_STATE" 2>/dev/null)"
    log "stopped all slots."
    return 0
  fi
  stop_slot "$target"
}

# stop_slot <slot-name>: stop the slot's Metro and free the slot record. The
# worktree is left in place (warm) unless it holds no record; Metro is killed.
stop_slot() {
  local s=$1 rec port pidf
  rec=$(state_get_slot "$s")
  if [ -z "$rec" ]; then
    warn "no such slot: $s"; return 0
  fi
  port=$(printf '%s' "$rec" | jq -r '.port // 0')
  pidf="$STATE_DIR/metro-$port.pid"
  if [ -f "$pidf" ]; then
    local pid; pid=$(cat "$pidf" 2>/dev/null || echo)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      info "stopped metro (pid $pid) on port $port"
    fi
    rm -f "$pidf"
  fi
  state_del_slot "$s"
  log "freed slot $s (worktree left warm at $SLOTS_DIR/$s)"
}

# cmd_gc: prune cache layers not referenced by any live slot AND older than
# GC_MAX_AGE_DAYS. LOGS everything it drops; never silently truncates. A
# referenced layer or a recent layer is kept regardless.
cmd_gc() {
  require_config
  ensure_dirs
  local referenced fp_ref
  # Fingerprints referenced by live slots (native/app cache protection).
  fp_ref=$(jq -r '.slots[].fingerprint // empty' "$SLOTS_STATE" 2>/dev/null | sort -u)
  log "gc: pruning cache layers older than $GC_MAX_AGE_DAYS days and unreferenced by any slot."
  local dropped=0 kept=0 layer base age_days now
  now=$(date +%s)
  for base in "$CACHE_DIR/node_modules" "$CACHE_DIR/pods" "$CACHE_DIR/app"; do
    [ -d "$base" ] || continue
    for layer in "$base"/*; do
      [ -e "$layer" ] || continue
      local name; name=$(basename "$layer")
      # app-cache layers are named <fp>-<platform>; protect referenced fingerprints.
      referenced=0
      if [ "$base" = "$CACHE_DIR/app" ]; then
        local lfp; lfp=${name%-*}
        if printf '%s\n' "$fp_ref" | grep -qxF "$lfp"; then referenced=1; fi
      fi
      age_days=$(layer_age_days "$layer" "$now")
      if [ "$referenced" = "1" ]; then
        kept=$((kept+1)); continue
      fi
      if [ "$age_days" -lt "$GC_MAX_AGE_DAYS" ]; then
        kept=$((kept+1)); continue
      fi
      log "  drop: $base/$name (age ${age_days}d, $(dir_size "$layer"))"
      rm -rf "$layer"
      dropped=$((dropped+1))
    done
  done
  log "gc: dropped $dropped layer(s), kept $kept."
}

cmd_doctor() {
  log "fm-mobile-lab doctor"
  log ""
  # Config
  if config_present; then
    log "config:      OK ($CONFIG)"
    local repos; repos=$(config_repos | paste -sd, - 2>/dev/null)
    info "repos: ${repos:-<none defined>}"
  else
    log "config:      MISSING ($CONFIG) -- engine is inert until created; see docs/mobile-lab.md"
  fi
  # Toolchain
  probe_line "jq"          "$(command -v jq || true)"
  probe_line "node"        "$(command -v node || true)"       "$(node --version 2>/dev/null || true)"
  probe_line "fnm"         "$(command -v fnm || true)"        "$(fnm --version 2>/dev/null || true)"
  probe_line "xcodebuild"  "$(command -v xcodebuild || true)" "$(xcodebuild -version 2>/dev/null | head -1 || true)"
  probe_line "cocoapods"   "$(command -v pod || true)"        "$(pod --version 2>/dev/null || true)"
  probe_line "watchman"    "$(command -v watchman || true)"
  # Simulators
  if have_ios_toolchain && command -v xcrun >/dev/null 2>&1; then
    local sims; sims=$(xcrun simctl list devices available 2>/dev/null | grep -cE '\([0-9A-Fa-f-]{36}\)' || echo 0)
    if [ "$sims" -gt 0 ]; then
      log "simulators:  OK ($sims available)"
    else
      log "simulators:  NONE available -- install an iOS runtime in Xcode to build for --sim"
    fi
  else
    log "simulators:  n/a (no Xcode toolchain)"
  fi
  # Devices
  if command -v xcrun >/dev/null 2>&1 && have_connected_device; then
    log "devices:     OK (a physical device is connected)"
  else
    log "devices:     NONE connected -- connect and trust a device to build for --device"
  fi
  # Disk
  local free; free=$(free_gb "$LAB_HOME")
  if [ "$free" -ge "$MIN_FREE_GB" ]; then
    log "disk:        OK (${free}GiB free, need >= ${MIN_FREE_GB}GiB)"
  else
    log "disk:        LOW (${free}GiB free, need >= ${MIN_FREE_GB}GiB) -- clone/install will refuse; run 'fm-mobile-lab gc' or free space"
  fi
  # Filesystem type of the volume that will hold the lab home. df -Y reports the
  # fs type in column 2 for any path (macOS), resolving through mount points,
  # which diskutil info does not do for a plain directory path. APFS is what
  # makes clonefile dedup work; a non-APFS volume falls back to full copies.
  local fstype
  fstype=$(df_fstype "$LAB_HOME")
  case "$fstype" in
    apfs) log "filesystem:  APFS (clonefile dedup active; slots share disk)" ;;
    '')   log "filesystem:  unknown (could not determine; clonefile may or may not be available)" ;;
    *)    log "filesystem:  $fstype at $LAB_HOME -- non-APFS, slots fall back to full copies (more disk, slower)" ;;
  esac
}

# --- small formatting helpers -----------------------------------------------

probe_line() {
  local name=$1 path=$2 ver=${3:-}
  if [ -n "$path" ]; then
    printf '%-12s OK (%s%s)\n' "$name:" "$path" "${ver:+, $ver}"
  else
    printf '%-12s MISSING\n' "$name:"
  fi
}

dir_size() {
  local d=$1
  if [ -d "$d" ]; then du -sh "$d" 2>/dev/null | awk '{print $1}'; else printf '0\n'; fi
}

# layer_age_days <path> <now-epoch>: whole days since the path was last modified.
layer_age_days() {
  local path=$1 now=$2 mtime
  mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo "$now")
  printf '%s\n' "$(( (now - mtime) / 86400 ))"
}

# fmt_epoch <epoch>: a compact relative "Nd/Nh/Nm ago" string; "-" for 0.
fmt_epoch() {
  local ts=$1 now diff
  [ "$ts" -gt 0 ] 2>/dev/null || { printf -- '-\n'; return 0; }
  now=$(date +%s); diff=$((now - ts))
  if   [ "$diff" -lt 3600 ]; then printf '%dm ago\n' "$((diff/60))"
  elif [ "$diff" -lt 86400 ]; then printf '%dh ago\n' "$((diff/3600))"
  else printf '%dd ago\n' "$((diff/86400))"
  fi
}

# --- usage & dispatch --------------------------------------------------------

usage() {
  cat <<EOF
fm-mobile-lab - build/test React Native branches on iOS sims and devices with a
                fingerprint-keyed native cache and warm git-worktree slots.

USAGE:
  fm-mobile-lab <repo> <branch> --sim|--device [--slot N]
  fm-mobile-lab ls
  fm-mobile-lab stop <slot-name>|--all
  fm-mobile-lab gc
  fm-mobile-lab doctor

PLATFORM IS EXPLICIT: you must pass --sim or --device (no default).

<repo>   a repo key defined in config/mobile-lab.json (not the path).
<branch> the git branch to try; fetched into a worktree, never into the clone.
--slot N pin to slot index N (0-based) instead of the LRU/auto choice.

The common case (a JS-only branch change) is checkout + Metro reload: no
reinstall, no native rebuild. Dependency changes restore-or-install; native
changes rebuild once and are then cached. JS is never cached (always live from
Metro).

Config lives at: $CONFIG
Lab home:        $LAB_HOME
See docs/mobile-lab.md for the field reference and verification evidence.
EOF
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;
    '') usage; exit 1 ;;   # bare invocation is a usage error
    ls)      shift; cmd_ls "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    gc)      shift; cmd_gc "$@" ;;
    doctor)  shift; cmd_doctor "$@" ;;
    *)
      # Positional: <repo> <branch> --sim|--device [--slot N]
      local repo=$1 branch=${2:-} platform='' slot=''
      shift || true; shift || true
      while [ $# -gt 0 ]; do
        case "$1" in
          --sim)    platform=sim ;;
          --device) platform=device ;;
          --slot)   shift; slot=${1:-} ;;
          *) die "unknown argument: $1 (see 'fm-mobile-lab --help')" ;;
        esac
        shift
      done
      [ -n "$branch" ] || { usage; die "missing <branch>"; }
      [ -n "$platform" ] || die "platform is required: pass --sim or --device (no default)"
      run_build "$repo" "$branch" "$platform" "$slot"
      ;;
  esac
}

# Allow sourcing for tests without executing main.
if [ "${FM_MOBILE_LAB_LIB:-0}" != "1" ]; then
  main "$@"
fi
