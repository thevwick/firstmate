#!/usr/bin/env bash
# fm-mobile-lab.sh - a thin, transparent build/test lab for React Native repos.
#
# Purpose: let the captain quickly try a code branch on an iOS simulator or a
# physical device. The lab is a THIN WRAPPER around each repo's own configured
# run command (react-native run-ios today, `npx expo run:ios` after the Expo
# migration, with ZERO lab code change). It does NOT reimplement xcodebuild: the
# RN/Expo CLI owns build + pods + install + launch, which it gets right for free
# (workspace-vs-scheme, deterministic destination, install/launch). The lab owns
# only the genuinely lab-specific parts: warm git-worktree slots, per-slot Metro
# ports, a node_modules deps cache, a pre-flight framework-slice compatibility
# gate, streaming progress + a build logfile, a machine-readable build-status
# file, and a per-slot build lock.
#
# See data/mobile-lab-audit-a7/report.md for why the previous xcodebuild
# reimplementation was rebuilt into this wrapper, and
# data/mobile-lab-status-contract.md for the build-status file contract this
# script emits (a separate console reader renders it).
#
# Design (approved): a GENERIC, repo-agnostic ENGINE (this script, shared and
# committed to every firstmate home) plus a per-fleet gitignored CONFIG
# (config/mobile-lab.json). The engine is INERT without config: with no config
# it prints a "create config" message and exits non-zero, so a firstmate user
# who never sets it up sees no behavior change. A committed example config lives
# at docs/examples/mobile-lab.json; usage and verification evidence live in
# docs/mobile-lab.md.
#
# Core model: a small pool of WARM git-worktree slots + a node_modules deps
# cache, all under ~/.fm-mobile-lab (or $FM_MOBILE_LAB_HOME):
#   cache/node_modules/<pkgmgr>-<lockfile-hash>/   built once per lockfile, APFS-clone source
#   slots/<repo>-<N>/                              git worktree of the projects/ clone (warm)
#   state/slots.json                               slot -> repo+branch, Metro port, last-used
#   state/build-<slot>.log                         full streamed build output (tee'd)
#   state/lab-build-<slot>.json                    machine-readable build status (the contract)
#   state/<slot>.build.lock/                       per-slot build lock (mkdir-based)
#
# There is NO app/native-artifact cache. The audit proved a fingerprint-keyed
# `.app` cache can serve a wrong-arch binary (it cached an x86_64 sim build and
# later tried to install it on an arm64 sim). The RN/Expo CLI does its own
# incremental build; the deps cache stays because it is cheap and correct.
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

# Heartbeat cadence (seconds) for a long build phase: how often the lab prints a
# "still <phase> (Nm elapsed)" line and re-writes the status file during a phase
# with no transition. The contract asks for at least every 10s.
BUILD_HEARTBEAT_SECS="${FM_MOBILE_LAB_HEARTBEAT_SECS:-10}"

# --- output helpers ---------------------------------------------------------

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# banner <phase> <index> <total> <message>: a phase start banner with timing.
banner() {
  local phase=$1 idx=$2 total=$3 msg=$4
  printf '\n=== [%s/%s] %s: %s ===\n' "$idx" "$total" "$phase" "$msg"
}

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
Metro port ranges, and per-repo run_command (e.g. react-native run-ios).
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

# --- pure logic: hashing ----------------------------------------------------

# sha_file <path>: sha256 hex of a file, or the literal "absent" when missing.
# Deterministic: the same bytes always hash the same, a missing file is always
# "absent". Used so a deps-cache key is stable across runs and machines.
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

# --- pure logic: run-command assembly ---------------------------------------
#
# The lab wraps the repo's configured run_command, appending the concrete
# target/port flags it resolved. build_run_command keeps this assembly pure and
# testable: given a base command and resolved (platform, target-flag, port), it
# prints the exact command string the lab will execute. The lab does NOT
# hard-bake `react-native run-ios`; it comes entirely from config, so the Expo
# switch (`npx expo run:ios`) is a config edit with no code change.

# shell_quote <str>: single-quote a string safely for the printed/executed
# command. A literal single quote inside a single-quoted string is written as
# the POSIX idiom '\'' (close-quote, escaped-quote, reopen-quote). Using a
# single-quoted replacement literal keeps the backslash handling unambiguous.
shell_quote() {
  local s=$1 q
  # q is the 4-character POSIX escape sequence  '\''  built with printf so the
  # literal stays unambiguous to both bash and shellcheck.
  q=$(printf "%s" "'\\''")
  printf "'%s'" "${s//\'/$q}"
}

# build_run_command <base-cmd> <target-flag> <target-value> <port>: append the
# resolved concrete target and Metro port to the repo's base run_command.
# <target-flag> is one of --udid / --simulator / --device (RN 0.80 run-ios
# supports all three; Expo run:ios accepts --device and a udid via --device).
# An empty target-flag appends nothing for the target (target already implied).
# Prints the full command string. Deterministic and pure: no environment reads.
build_run_command() {
  local base=$1 target_flag=$2 target_value=$3 port=$4
  local out=$base
  if [ -n "$target_flag" ]; then
    out="$out $target_flag $(shell_quote "$target_value")"
  fi
  if [ -n "$port" ]; then
    out="$out --port $port"
  fi
  printf '%s\n' "$out"
}

# --- pure logic: framework-slice compatibility gate -------------------------
#
# The one genuinely lab-specific safety check. Before a build, enumerate the
# app's vendored *.framework/<binary> and *.a static libraries under ios/, and
# confirm at least one carries a slice for the concrete target platform+arch.
# The FFmpeg case (dashpivot's libavcodec has only x86_64-IOSSIMULATOR +
# arm64-IOS(device) slices, no arm64-simulator) makes an arm64-sim build
# impossible; this gate turns a 10-minute link-time death into a one-line
# pre-flight error steering to --device.

# target_platform_token <platform>: the Mach-O build platform token vtool prints
# for a given lab platform. sim -> IOSSIMULATOR, device -> IOS.
target_platform_token() {
  case "$1" in
    sim)    printf 'IOSSIMULATOR\n' ;;
    device) printf 'IOS\n' ;;
    *)      return 1 ;;
  esac
}

# A vendored binary can be packaged two ways, and they need different checks:
#
#  1. A modern *.xcframework is a self-describing multi-platform container: its
#     Info.plist AvailableLibraries lists every slice by platform, variant
#     (simulator vs device), and arch. Apple's CORRECT packaging. It must be
#     checked as a UNIT against that manifest; its inner per-slice *.framework
#     dirs are legitimately single-platform and must NOT be inspected on their
#     own (an ios-*-simulator inner dir having no device slice is expected, not a
#     block). Distinguishing this from case 2 is what keeps the gate from
#     false-blocking a well-packaged xcframework.
#  2. A plain *.framework or *.a NOT inside any xcframework is a single fat/thin
#     Mach-O. This is the FFmpeg case: one fat binary with an x86_64-SIMULATOR
#     slice and an arm64-DEVICE slice but no arm64-SIMULATOR slice. Checked with
#     lipo (arch presence) + vtool (that arch's build platform).

# xcframework_supports <xcframework-dir> <platform> <arch>: 0 if the xcframework's
# Info.plist declares a slice for the target platform (ios) with the requested
# variant (simulator for sim, device/none for device) that includes <arch>. Uses
# plutil to read the plist; when plutil is unavailable or the plist is
# unreadable, returns 0 (cannot check this container -> do not block).
xcframework_supports() {
  local xc=$1 platform=$2 arch=$3 want_variant plist libs
  case "$platform" in
    sim)    want_variant='simulator' ;;
    device) want_variant='device' ;;
    *) return 0 ;;
  esac
  plist="$xc/Info.plist"
  [ -f "$plist" ] || return 0
  command -v plutil >/dev/null 2>&1 || return 0
  libs=$(plutil -extract AvailableLibraries json -o - "$plist" 2>/dev/null) || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # A device slice has no SupportedPlatformVariant key (null); a simulator slice
  # has variant "simulator". Match platform ios, the right variant, and arch.
  local n
  n=$(printf '%s' "$libs" | jq -r --arg v "$want_variant" --arg a "$arch" '
        [ .[]
          | select(.SupportedPlatform == "ios")
          | select( ($v == "device" and (has("SupportedPlatformVariant") | not))
                    or (.SupportedPlatformVariant == $v) )
          | select( .SupportedArchitectures | index($a) ) ] | length' 2>/dev/null)
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null
}

# plain_binary_has_slice <binary> <arch> <platform-token>: 0 if the fat/thin
# Mach-O <binary> carries a slice for <arch> whose build platform is
# <platform-token>. lipo confirms the arch is present; vtool confirms that arch's
# slice targets the right platform. A binary lipo cannot read is treated as "no
# matching slice", never a hard error.
plain_binary_has_slice() {
  local bin=$1 arch=$2 want_platform=$3 archs
  command -v lipo >/dev/null 2>&1 || return 0   # no lipo: cannot gate, allow.
  archs=$(lipo -archs "$bin" 2>/dev/null) || return 1
  case " $archs " in
    *" $arch "*) : ;;
    *) return 1 ;;   # arch not present at all.
  esac
  if command -v vtool >/dev/null 2>&1; then
    vtool -arch "$arch" -show-build "$bin" 2>/dev/null \
      | grep -qiE "platform[[:space:]]+$want_platform([[:space:]]|\$)" && return 0
    return 1
  fi
  return 0   # no vtool: arch-presence only (weaker, never a false block).
}

# is_gateable_path <path>: 1 (false) if a framework/xcframework path is one the
# gate must ignore, 0 (true) if it should be inspected. Ignored paths:
#  - anything inside an *.xcframework (its inner per-slice frameworks are handled
#    via the container's manifest, not on their own);
#  - build/derivedData output trees (ios/build, DerivedData, a pod's own build),
#    which hold single-platform BUILD PRODUCTS, not vendored source inputs;
#  - non-iOS platform slice directories (macosx/tvos/watchos/xros/maccatalyst),
#    which are never linked into the iOS app and would false-block otherwise.
is_gateable_path() {
  case "$1" in
    *.xcframework/*) return 1 ;;
    */build/*|*/DerivedData/*|*/.build/*) return 1 ;;
    */macos/*|*/macosx/*|*/tvos/*|*/watchos/*|*/xros/*|*/maccatalyst/*) return 1 ;;
    *-maccatalyst/*|*-maccatalyst.framework/*) return 1 ;;
  esac
  return 0
}

# enumerate_plain_binaries <checkout-dir>: print every PLAIN vendored Mach-O
# under ios/ that is NOT inside an *.xcframework and NOT a build product: each
# gateable top-level *.framework's own dylib and every gateable *.a. This is the
# FFmpeg surface (plain fat frameworks vendored directly under ios/).
enumerate_plain_binaries() {
  local dir=$1 fw
  [ -d "$dir/ios" ] || return 0
  while IFS= read -r -d '' fw; do
    is_gateable_path "$fw" || continue
    local base bin
    base=$(basename "$fw" .framework)
    bin="$fw/$base"
    [ -f "$bin" ] && printf '%s\n' "$bin"
  done < <(find "$dir/ios" -type d -name '*.framework' -print0 2>/dev/null)
  while IFS= read -r -d '' a; do
    is_gateable_path "$a" || continue
    printf '%s\n' "$a"
  done < <(find "$dir/ios" -type f -name '*.a' -print0 2>/dev/null)
}

# enumerate_xcframeworks <checkout-dir>: print every gateable *.xcframework
# directory under ios/ (not nested in another xcframework, not under a build
# tree), one per line.
enumerate_xcframeworks() {
  local dir=$1 xc
  [ -d "$dir/ios" ] || return 0
  while IFS= read -r -d '' xc; do
    case "${xc%/*}" in *.xcframework) continue ;; esac   # skip nested (rare).
    case "$xc" in */build/*|*/DerivedData/*|*/.build/*) continue ;; esac
    printf '%s\n' "$xc"
  done < <(find "$dir/ios" -type d -name '*.xcframework' -print0 2>/dev/null)
}

# slice_gate <checkout-dir> <platform> <arch>: the pre-flight compatibility gate.
# Checks each xcframework against its Info.plist manifest and each plain
# framework/static-lib against its Mach-O slices. Returns 0 (compatible) when
# every vendored binary that matters supports the target platform+arch. Returns 1
# (incompatible) and prints a single specific one-line reason naming the
# framework, the missing slice, and the viable alternative, on the first blocker.
# When lipo is unavailable it cannot inspect plain binaries and returns 0 (allow)
# with nothing printed, so a machine without the Mach-O tools never false-blocks.
slice_gate() {
  local dir=$1 platform=$2 arch=$3 token first_block=''
  token=$(target_platform_token "$platform") || return 0
  command -v lipo >/dev/null 2>&1 || return 0

  # 1. xcframeworks (checked against their manifest).
  local xc base
  while IFS= read -r xc; do
    [ -n "$xc" ] || continue
    if xcframework_supports "$xc" "$platform" "$arch"; then
      continue
    fi
    base=$(basename "$xc")
    if [ "$platform" = "sim" ]; then
      first_block="$base has no $arch-simulator slice; this app can only run on a physical device: re-run with --device"
    else
      first_block="$base has no $arch-device slice; this app cannot build for a physical $arch device"
    fi
    break
  done < <(enumerate_xcframeworks "$dir")

  # 2. plain frameworks/static libs (the FFmpeg case), only if nothing blocked yet.
  local bin archs
  if [ -z "$first_block" ]; then
    while IFS= read -r bin; do
      [ -n "$bin" ] || continue
      archs=$(lipo -archs "$bin" 2>/dev/null) || continue
      if plain_binary_has_slice "$bin" "$arch" "$token"; then
        continue
      fi
      base=$(basename "$bin")
      local archs_1line; archs_1line=$(printf '%s' "$archs" | tr '\n' ' ' | sed -E 's/ +/ /g; s/ *$//')
      case " $archs " in
        *" $arch "*)
          if [ "$platform" = "sim" ]; then
            first_block="$base has no $arch-simulator slice (present: $archs_1line, built for device); this app can only run on a physical device: re-run with --device"
          else
            first_block="$base has no $arch-device slice (present: $archs_1line); this app cannot build for a physical $arch device"
          fi
          ;;
        *)
          first_block="$base has no $arch slice at all (present: $archs_1line); this app cannot build for $arch on $platform"
          ;;
      esac
      break
    done < <(enumerate_plain_binaries "$dir")
  fi

  if [ -n "$first_block" ]; then
    printf '%s\n' "$first_block"
    return 1
  fi
  return 0
}

# --- state (slots.json) ------------------------------------------------------

ensure_dirs() {
  mkdir -p "$CACHE_DIR/node_modules" "$SLOTS_DIR" "$STATE_DIR"
  [ -f "$SLOTS_STATE" ] || printf '{"slots":{}}\n' > "$SLOTS_STATE"
}

# state_get_slot <slot-name>: print the slot's JSON object, or empty.
state_get_slot() {
  jq -c --arg s "$1" '.slots[$s] // empty' "$SLOTS_STATE" 2>/dev/null
}

# state_set_slot <slot-name> <repo> <branch> <port> <epoch>: upsert a slot
# record. last_used is the epoch so LRU can order slots.
state_set_slot() {
  local s=$1 repo=$2 branch=$3 port=$4 now=$5 tmp
  tmp=$(mktemp "$STATE_DIR/slots.json.XXXXXX")
  jq --arg s "$s" --arg repo "$repo" --arg branch "$branch" \
     --argjson port "$port" --argjson now "$now" \
     '.slots[$s] = {repo:$repo, branch:$branch, port:$port, last_used:$now}' \
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

# --- per-slot build lock -----------------------------------------------------
#
# An exclusive per-slot lock around the pods+build+install sequence so two
# builds into the same slot (same worktree, same derivedData) cannot collide
# (the audit's build-DB-lock failure). mkdir is atomic on macOS/HFS+/APFS and
# does not need flock (which macOS lacks). The lock dir records the holder PID so
# a stale lock left by a dead process is detected and cleared.

# build_lock_dir <slot-name>: the lock directory path for a slot.
build_lock_dir() {
  printf '%s/%s.build.lock\n' "$STATE_DIR" "$1"
}

# acquire_build_lock <slot-name>: take the exclusive lock. On contention, if the
# recorded holder PID is dead, clear the stale lock and take it; otherwise fail
# non-zero. On success, records our PID and prints nothing. FM_MOBILE_LAB_LOCK_WAIT
# (seconds, default 0) makes it retry rather than fail immediately.
acquire_build_lock() {
  local s=$1 dir waited=0 wait_max holder
  dir=$(build_lock_dir "$s")
  wait_max="${FM_MOBILE_LAB_LOCK_WAIT:-0}"
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$dir/pid"
      return 0
    fi
    holder=$(cat "$dir/pid" 2>/dev/null || echo)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # Stale lock: the recorded holder is dead. Clear and retry once.
      warn "clearing stale build lock for slot $s (dead holder pid $holder)"
      rm -rf "$dir"
      continue
    fi
    if [ "$waited" -ge "$wait_max" ]; then
      return 1
    fi
    sleep 1; waited=$((waited + 1))
  done
}

# release_build_lock <slot-name>: release the lock IF we hold it (our PID). Safe
# to call in a trap even if we never acquired it.
release_build_lock() {
  local s=$1 dir holder
  dir=$(build_lock_dir "$s")
  [ -d "$dir" ] || return 0
  holder=$(cat "$dir/pid" 2>/dev/null || echo)
  if [ "$holder" = "$$" ]; then
    rm -rf "$dir"
  fi
}

# --- build-status file (the console contract) -------------------------------
#
# state/lab-build-<slot>.json per data/mobile-lab-status-contract.md. Written
# atomically (temp + mv) on every phase transition and at least every
# BUILD_HEARTBEAT_SECS during a long phase. The console reads it; do not deviate
# from the contract shape.
#
# Status state is carried in globals so the heartbeat and phase-transition
# writers share one source of truth. percent is null unless a caller sets a
# concrete integer (NEVER a fake smooth bar).

ST_SLOT='' ST_REPO='' ST_BRANCH='' ST_PLATFORM='' ST_TARGET=''
ST_RUN_COMMAND='' ST_PORT=0 ST_PHASE='' ST_PHASE_INDEX=0 ST_PHASE_TOTAL=7
ST_PERCENT='null' ST_STATUS='running' ST_STARTED=0 ST_PHASE_STARTED=0
ST_MESSAGE='' ST_LOGFILE='' ST_ERROR='null'

# status_file_path <slot-name>: the status file path for a slot.
status_file_path() {
  printf '%s/lab-build-%s.json\n' "$STATE_DIR" "$1"
}

# status_write: write the current status globals to the slot's status file
# atomically. percent and error are emitted raw (already valid JSON: an integer
# or the literal null). Every string is JSON-encoded by jq so a quote/newline in
# a message can never corrupt the file.
status_write() {
  [ -n "$ST_SLOT" ] || return 0
  local out tmp now
  out=$(status_file_path "$ST_SLOT")
  now=$(date +%s)
  tmp=$(mktemp "$STATE_DIR/lab-build-$ST_SLOT.json.XXXXXX")
  if jq -n \
    --argjson schema 1 \
    --arg slot "$ST_SLOT" \
    --arg repo "$ST_REPO" \
    --arg branch "$ST_BRANCH" \
    --arg platform "$ST_PLATFORM" \
    --arg target "$ST_TARGET" \
    --arg run_command "$ST_RUN_COMMAND" \
    --argjson port "${ST_PORT:-0}" \
    --arg phase "$ST_PHASE" \
    --argjson phase_index "${ST_PHASE_INDEX:-0}" \
    --argjson phase_total "${ST_PHASE_TOTAL:-7}" \
    --argjson percent "${ST_PERCENT:-null}" \
    --arg status "$ST_STATUS" \
    --argjson started_epoch "${ST_STARTED:-0}" \
    --argjson updated_epoch "$now" \
    --argjson phase_started_epoch "${ST_PHASE_STARTED:-0}" \
    --arg message "$ST_MESSAGE" \
    --arg logfile "$ST_LOGFILE" \
    --argjson error "${ST_ERROR:-null}" \
    '{schema:$schema, slot:$slot, repo:$repo, branch:$branch, platform:$platform,
      target:$target, run_command:$run_command, port:$port, phase:$phase,
      phase_index:$phase_index, phase_total:$phase_total, percent:$percent,
      status:$status, started_epoch:$started_epoch, updated_epoch:$updated_epoch,
      phase_started_epoch:$phase_started_epoch, message:$message,
      logfile:$logfile, error:$error}' \
    > "$tmp" 2>/dev/null; then
    mv "$tmp" "$out"
  else
    rm -f "$tmp"; return 1
  fi
}

# status_phase <phase> <index> <message> [percent]: advance to a phase and write.
# percent defaults to null (honest: unknown). Sets phase_started to now.
status_phase() {
  ST_PHASE=$1; ST_PHASE_INDEX=$2; ST_MESSAGE=$3
  ST_PERCENT=${4:-null}
  ST_PHASE_STARTED=$(date +%s)
  banner "$ST_PHASE" "$ST_PHASE_INDEX" "$ST_PHASE_TOTAL" "$ST_MESSAGE"
  status_write
}

# status_message <message> [percent]: update the message (and optional percent)
# without changing phase, then write. Used for intra-phase progress.
status_message() {
  ST_MESSAGE=$1
  [ $# -ge 2 ] && ST_PERCENT=$2
  status_write
}

# status_fail <error>: terminal failed state with a specific error string.
status_fail() {
  ST_STATUS='failed'
  ST_ERROR=$(printf '%s' "$1" | jq -Rs .)
  status_write
}

# status_success: terminal success state.
status_success() {
  ST_STATUS='success'; ST_ERROR='null'; ST_PERCENT=100
  ST_MESSAGE='build complete'
  status_write
}

# --- disk headroom -----------------------------------------------------------

# existing_ancestor <path>: the nearest ancestor of <path> that exists.
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
  kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "$kb" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$((kb / 1024 / 1024))"
}

# assert_disk_headroom <label>: refuse a multi-GB operation when free disk is
# below the floor. LOUD, never silent.
assert_disk_headroom() {
  local label=$1 free
  free=$(free_gb "$LAB_HOME")
  if [ "$free" -lt "$MIN_FREE_GB" ]; then
    die "not enough free disk for $label: ${free}GiB free, need >= ${MIN_FREE_GB}GiB (set FM_MOBILE_LAB_MIN_FREE_GB to override). Refusing to risk filling the disk."
  fi
}

# --- APFS clone helpers ------------------------------------------------------

# apfs_clone <src> <dst>: copy-on-write clone a directory tree with cp -c. Falls
# back LOUDLY to a real recursive copy if clonefile is unsupported (non-APFS).
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
# checkout. Kept separate so tests can stub it.
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
# Records a one-line summary into DEPS_LINE and returns 0 on a cache HIT, 1 on a
# miss-then-install (so the caller can distinguish a skipped vs run deps phase).
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
  install_deps "$dir" "$pkgmgr" \
    || die "$pkgmgr install failed in $dir; not caching a broken node_modules. Fix the install and retry."
  [ -d "$dir/node_modules" ] || mkdir -p "$dir/node_modules"
  rm -rf "$cache"
  apfs_clone "$dir/node_modules" "$cache"
  DEPS_LINE="deps: installed and cached ($pkgmgr-$hash)"
  return 1
}

# --- target resolution -------------------------------------------------------
#
# The lab resolves a CONCRETE target (a specific booted sim udid or a specific
# connected device), never a vague generic destination. The resolved target
# feeds both the slice gate (which arch/platform to check) and the run_command
# (--udid/--device). host_arch is the deterministic target arch on this host.

# host_arch: the target CPU arch for this host. Apple Silicon builds arm64;
# an Intel host builds x86_64. This is the arch a sim/device build must match.
host_arch() { uname -m 2>/dev/null || printf 'arm64\n'; }

# booted_sim_udid: the udid of a currently-booted simulator, or empty. Prefers
# the first Booted device simctl reports.
booted_sim_udid() {
  command -v xcrun >/dev/null 2>&1 || return 0
  xcrun simctl list devices booted 2>/dev/null \
    | grep -oE '\([0-9A-Fa-f-]{36}\) \(Booted\)' \
    | grep -oE '[0-9A-Fa-f-]{36}' | head -1
}

# booted_sim_name_os: a human "name (iOS X.Y)" label for the booted sim, or empty.
booted_sim_name_os() {
  command -v xcrun >/dev/null 2>&1 || return 0
  xcrun simctl list devices booted 2>/dev/null \
    | awk '/-- iOS /{os=$0; sub(/^-- iOS /,"",os); sub(/ --.*/,"",os)}
           /\(Booted\)/{name=$0; sub(/^[[:space:]]+/,"",name); sub(/ \([0-9A-Fa-f-]{36}\).*/,"",name);
                        printf "%s (iOS %s)\n", name, os; exit}'
}

# connected_device_udid: the udid of the first connected physical iOS device.
connected_device_udid() {
  command -v xcrun >/dev/null 2>&1 || return 0
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{d=1;next} /^== /{d=0} d' \
    | grep -E '\([0-9]+\.[0-9]+.*\) \([0-9A-Fa-f-]{8,}\)' \
    | grep -oE '\([0-9A-Fa-f-]{8,}\)$' | tr -d '()' | head -1
}

# connected_device_label: "<name> (<version>)" for the first connected device.
connected_device_label() {
  command -v xcrun >/dev/null 2>&1 || return 0
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{d=1;next} /^== /{d=0} d' \
    | grep -E '\([0-9]+\.[0-9]+.*\) \([0-9A-Fa-f-]{8,}\)' \
    | head -1 | sed -E 's/ \([0-9A-Fa-f-]{8,}\)[[:space:]]*$//' \
    | sed -E 's/[[:space:]]+$//'
}

# resolve_target <platform>: resolve the concrete target for a platform. On
# success prints three TAB-separated fields: <run-flag>\t<flag-value>\t<label>
# where run-flag is --udid (both platforms resolve a concrete udid) and label is
# a human string for the status file. Returns non-zero and prints a reason to
# stderr when no concrete target is available.
resolve_target() {
  local platform=$1 udid label
  case "$platform" in
    sim)
      udid=$(booted_sim_udid)
      [ -n "$udid" ] || { err "no booted iOS simulator; boot one (Simulator.app or 'xcrun simctl boot <udid>') then retry"; return 1; }
      label=$(booted_sim_name_os); [ -n "$label" ] || label="simulator $udid"
      printf '%s\t%s\t%s\n' '--udid' "$udid" "$label"
      ;;
    device)
      udid=$(connected_device_udid)
      [ -n "$udid" ] || { err "no connected iOS device; connect and trust one then retry"; return 1; }
      label=$(connected_device_label); [ -n "$label" ] || label="device $udid"
      printf '%s\t%s\t%s\n' '--udid' "$udid" "$label"
      ;;
    *) return 1 ;;
  esac
}

# --- top-level run flow ------------------------------------------------------

# clone_dir <repo>: absolute path to the repo's clone under projects/.
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

  local clone base_port pool run_cmd
  clone=$(clone_dir "$repo")
  [ -d "$clone/.git" ] || die "clone for '$repo' not found at $clone (clone it under projects/ first; the lab never creates or modifies the clone)"
  base_port=$(config_int "$repo" metro_port_base 8081)
  pool=$(config_int "$repo" pool_size 3)
  run_cmd=$(config_repo_field "$repo" run_command)
  [ -n "$run_cmd" ] || die "config for '$repo' has no run_command; add e.g. \"run_command\": \"react-native run-ios --scheme 'Your Scheme'\" (post-Expo: \"npx expo run:ios\"). See docs/mobile-lab.md."

  ensure_dirs
  local idx name slot port now
  idx=$(pick_slot "$repo" "$pool" "$explicit_slot")
  name=$(slot_name "$repo" "$idx")
  slot="$SLOTS_DIR/$name"
  port=$(metro_port "$base_port" "$idx")
  now=$(date +%s)

  log "fm-mobile-lab: $repo @ $branch -> slot $idx (port $port, $platform)"
  log "  run_command: $run_cmd"

  # Initialize build-status globals up front so even an early failure emits a
  # contract-shaped status file the console can render.
  ST_SLOT=$name ST_REPO=$repo ST_BRANCH=$branch ST_PLATFORM=$platform
  ST_RUN_COMMAND=$run_cmd ST_PORT=$port ST_STATUS='running' ST_ERROR='null'
  ST_STARTED=$now ST_PERCENT='null' ST_TARGET='(resolving)'
  ST_LOGFILE="state/build-$name.log"
  ST_PHASE_TOTAL=7

  # Take the per-slot build lock around the whole pods+build+install sequence.
  # Metro and the worktree are shared-safe; the native build + install into the
  # slot's derivedData is what must be serialized.
  if ! acquire_build_lock "$name"; then
    ST_PHASE='preflight' ST_PHASE_INDEX=1
    status_fail "another build is already running for slot $name (held by pid $(cat "$(build_lock_dir "$name")/pid" 2>/dev/null || echo '?')); wait for it or run a different slot with --slot"
    die "slot $name is locked by another build; wait for it or pick a different --slot"
  fi
  # Release the lock however we exit from here on.
  # shellcheck disable=SC2064
  trap "release_build_lock '$name'" EXIT

  # PHASE 1: preflight - resolve the concrete target and run the slice gate.
  status_phase preflight 1 "resolving target and checking framework slices"
  local target_flag target_value target_label arch
  arch=$(host_arch)
  local resolved
  if ! resolved=$(resolve_target "$platform"); then
    status_fail "could not resolve a concrete $platform target (see terminal output)"
    die "target resolution failed for --$platform"
  fi
  IFS=$'\t' read -r target_flag target_value target_label <<< "$resolved"
  ST_TARGET=$target_label
  info "target: $target_label ($arch)"
  status_message "resolved target: $target_label ($arch)"
  # The slice gate needs the checked-out ios/ tree, so it runs AFTER the worktree
  # phase below (the frameworks live in the slot's checkout, not before it).

  # PHASE 2: worktree - fetch and check out the branch in the slot worktree.
  status_phase worktree 2 "checking out $branch"
  assert_disk_headroom "worktree setup"
  git -C "$clone" fetch --quiet origin "$branch" 2>/dev/null \
    || warn "could not fetch origin/$branch (offline, or branch is local-only); using whatever '$branch' already resolves to"
  ensure_slot_worktree "$clone" "$slot" "$branch"

  # Now the slot is populated: run the slice gate against the real ios/ tree.
  status_message "checking framework slices for $arch/$platform"
  local gate_reason
  if ! gate_reason=$(slice_gate "$slot" "$platform" "$arch"); then
    status_fail "$gate_reason"
    err "$gate_reason"
    die "pre-flight slice check failed: $gate_reason"
  fi
  info "slice check: OK (a $arch/$platform slice is available for every vendored framework)"

  # Detect toolchain from the CHECKOUT and switch node.
  local pkgmgr node_v
  pkgmgr=$(detect_pkgmgr "$slot") || die "no known lockfile in $slot; cannot determine package manager"
  node_v=$(detect_node_version "$slot")
  info "toolchain: $pkgmgr${node_v:+, node $node_v}"
  switch_node "$node_v"

  # PHASE 3: deps - restore-or-install node_modules. A cache hit is still shown
  # as the deps phase (a near-instant one), so the console's phase tracker stays
  # aligned with the canonical 7-phase vocabulary.
  status_phase deps 3 "restoring node_modules"
  ensure_node_modules "$slot" "$pkgmgr" || true
  info "$DEPS_LINE"
  status_message "$DEPS_LINE"

  # Metro on the slot's fixed port (long-lived; NOT part of the build lock).
  ensure_metro "$slot" "$port" "$pkgmgr"

  state_set_slot "$name" "$repo" "$branch" "$port" "$now"

  # PHASES 4-7: pods, compile, link, install - all owned by the wrapped
  # run_command. The lab streams+tees its output, infers phase transitions from
  # the CLI's own markers, and emits the status file throughout.
  run_wrapped_build "$name" "$slot" "$run_cmd" "$target_flag" "$target_value" "$port"

  status_success
  log ""
  log "READY: $repo @ $branch on $target_label"
  info "slot:       $slot"
  info "metro port: $port"
  info "$DEPS_LINE"
  info "log:        $ST_LOGFILE"
}

# ensure_slot_worktree <clone> <slot-path> <branch>: create the git worktree if
# missing, then check out the branch inside the worktree (detached).
ensure_slot_worktree() {
  local clone=$1 slot=$2 branch=$3
  git -C "$clone" worktree prune >/dev/null 2>&1 || true
  if [ ! -e "$slot/.git" ]; then
    git -C "$clone" worktree add --detach --force "$slot" HEAD >/dev/null 2>&1 \
      || die "failed to create worktree at $slot"
  fi
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
# for. Best-effort; a missing fnm/version is a warning, not a failure.
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
# the requested major[.minor[.patch]] prefix.
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
# not already running there. Backgrounded and detached; the slot owns it.
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

# --- wrapped-build execution -------------------------------------------------
#
# The heart of the wrapper. Runs the repo's configured run_command (with the
# resolved target + port appended), streaming its output to the terminal AND
# tee'ing the full output to state/build-<slot>.log, while a background monitor
# infers phase transitions from the CLI's own markers, emits the status file on
# every transition and at least every BUILD_HEARTBEAT_SECS, and prints a
# heartbeat on long phases. Best-effort but honest: percent is null unless a
# "Compiling X/Y" count is parsed.

# infer_phase_from_line <line>: map a line of RN/Expo CLI output to a phase name
# from the contract vocabulary, or empty if the line is not a transition marker.
# Best-effort pattern match against the CLI's actual output.
infer_phase_from_line() {
  local line=$1
  case "$line" in
    *"Installing "*" on "*|*"Installing app"*|*"Launching"*|*"Successfully launched"*|*"Installing and launching"*)
      printf 'install\n' ;;
    *"pod install"*|*"Installing CocoaPods"*|*"Analyzing dependencies"*|*"Installing "*" pod"*)
      printf 'pods\n' ;;
    *"Compiling"*|*"CompileC"*|*"CompileSwift"*|*"Building"*)
      printf 'compile\n' ;;
    *"Ld "*|*"Linking"*)
      printf 'link\n' ;;
    *) printf '' ;;
  esac
}

# parse_compile_count <line>: if the line carries a "Compiling X/Y"-style count,
# print an integer percent (0-100); otherwise print nothing. Only used to refine
# the compile phase; never fakes progress.
parse_compile_count() {
  local line=$1 x y
  if [[ $line =~ \(([0-9]+)/([0-9]+)\) ]]; then
    x=${BASH_REMATCH[1]}; y=${BASH_REMATCH[2]}
    [ "$y" -gt 0 ] 2>/dev/null || return 0
    printf '%s\n' "$(( x * 100 / y ))"
  fi
}

# stream_build_output <logfile>: read the wrapped build's combined output on
# stdin, echo each line to the terminal, append it to <logfile>, and drive
# phase/status transitions and heartbeats. Kept as its own function (not an
# inline subshell) so `local` is valid and the loop is unit-testable in
# isolation. Reads BUILD_HEARTBEAT_SECS and the ST_* status globals; writes the
# status file via status_phase/status_message. The initial phase is `pods`
# (index 4), the first of the wrapped CLI's phases.
stream_build_output() {
  local logfile=$1
  local line last_beat now phase cur_phase='pods' cur_idx=4 pct el
  last_beat=$(date +%s)
  while IFS= read -r line; do
    printf '%s\n' "$line"                 # terminal
    printf '%s\n' "$line" >> "$logfile"   # logfile
    phase=$(infer_phase_from_line "$line")
    if [ -n "$phase" ] && [ "$phase" != "$cur_phase" ]; then
      case "$phase" in
        pods) cur_idx=4 ;;
        compile) cur_idx=5 ;;
        link) cur_idx=6 ;;
        install) cur_idx=7 ;;
      esac
      cur_phase=$phase
      status_phase "$cur_phase" "$cur_idx" "$line"
      last_beat=$(date +%s)
    else
      pct=$(parse_compile_count "$line")
      now=$(date +%s)
      if [ -n "$pct" ] || [ $((now - last_beat)) -ge "$BUILD_HEARTBEAT_SECS" ]; then
        if [ -n "$pct" ] && [ "$cur_phase" = "compile" ]; then
          status_message "$line" "$pct"
        else
          el=$((now - ST_PHASE_STARTED))
          printf '  ... still %s (%ss elapsed)\n' "$cur_phase" "$el"
          status_message "$line"
        fi
        last_beat=$now
      fi
    fi
  done
}

# run_wrapped_build <slot-name> <slot-dir> <base-cmd> <target-flag> <target-value> <port>:
# assemble and run the wrapped run_command, streaming + tee'ing through
# stream_build_output, inferring phase transitions, and emitting the status
# file. Fails (non-zero, terminal status) with a specific error when the CLI
# exits non-zero. The build's PIPESTATUS[0] is the authoritative exit code (tee
# via the reader must not mask a non-zero build).
run_wrapped_build() {
  local name=$1 slot=$2 base=$3 tflag=$4 tval=$5 port=$6
  local full logfile rc=0
  full=$(build_run_command "$base" "$tflag" "$tval" "$port")
  logfile="$STATE_DIR/build-$name.log"
  : > "$logfile"

  status_phase pods 4 "starting wrapped build: $full"
  info "running: $full"
  info "log: state/build-$name.log"

  # Pipe the wrapped command's combined stdout+stderr through the reader. The
  # fixed Metro port is baked into the environment (RCT_METRO_PORT) so the built
  # binary asks this slot's port for its bundle. PIPESTATUS[0] captures the
  # build's own exit code independent of the reader.
  ( cd "$slot" && RCT_METRO_PORT="$port" exec bash -c "$full" ) 2>&1 \
    | stream_build_output "$logfile"
  rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ]; then
    status_fail "wrapped run_command failed (exit $rc): $full - see log at state/build-$name.log"
    err "build failed (exit $rc). Full log: $logfile"
    die "wrapped run_command exited $rc; see $logfile"
  fi
  # The reader ran in the pipe subshell, so its phase transitions did not
  # propagate here. A completed wrapped build always ends at the install phase;
  # reflect that in the parent so the terminal status_success write is accurate.
  ST_PHASE='install' ST_PHASE_INDEX=7
}

# --- capability probes (also used by doctor) --------------------------------

have_ios_toolchain() { command -v xcodebuild >/dev/null 2>&1; }

have_booted_or_bootable_sim() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun simctl list devices available 2>/dev/null | grep -qE '\([0-9A-Fa-f-]{36}\)'
}

have_connected_device() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{d=1;next} /^== /{d=0} d' \
    | grep -qE '\([0-9]+\.[0-9]+.*\) \([0-9A-Fa-f-]{8,}\)'
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
# worktree is left in place (warm); Metro is killed.
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

# cmd_gc: prune node_modules cache layers older than GC_MAX_AGE_DAYS. There is
# no app cache to prune anymore. LOGS everything it drops.
cmd_gc() {
  require_config
  ensure_dirs
  log "gc: pruning node_modules cache layers older than $GC_MAX_AGE_DAYS days."
  local dropped=0 kept=0 layer base age_days now name
  now=$(date +%s)
  base="$CACHE_DIR/node_modules"
  if [ -d "$base" ]; then
    for layer in "$base"/*; do
      [ -e "$layer" ] || continue
      name=$(basename "$layer")
      age_days=$(layer_age_days "$layer" "$now")
      if [ "$age_days" -lt "$GC_MAX_AGE_DAYS" ]; then
        kept=$((kept+1)); continue
      fi
      log "  drop: $base/$name (age ${age_days}d, $(dir_size "$layer"))"
      rm -rf "$layer"
      dropped=$((dropped+1))
    done
  fi
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
  probe_line "lipo"        "$(command -v lipo || true)"
  probe_line "vtool"       "$(command -v vtool || true)"
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
  # Per-repo platform viability: run the slice gate against each repo's slot
  # worktree (if warm) or clone, so doctor reports which platforms are actually
  # buildable per repo (the FFmpeg case surfaces here, not mid-build).
  if config_present; then
    log ""
    log "per-repo platform viability (framework-slice check):"
    doctor_repo_viability
  fi
  # Disk
  local free; free=$(free_gb "$LAB_HOME")
  if [ "$free" -ge "$MIN_FREE_GB" ]; then
    log "disk:        OK (${free}GiB free, need >= ${MIN_FREE_GB}GiB)"
  else
    log "disk:        LOW (${free}GiB free, need >= ${MIN_FREE_GB}GiB) -- clone/install will refuse; run 'fm-mobile-lab gc' or free space"
  fi
  # Filesystem type of the volume that will hold the lab home.
  local fstype
  fstype=$(df_fstype "$LAB_HOME")
  case "$fstype" in
    apfs) log "filesystem:  APFS (clonefile dedup active; slots share disk)" ;;
    '')   log "filesystem:  unknown (could not determine; clonefile may or may not be available)" ;;
    *)    log "filesystem:  $fstype at $LAB_HOME -- non-APFS, slots fall back to full copies (more disk, slower)" ;;
  esac
}

# doctor_repo_viability: for each configured repo, find an ios/ tree to inspect
# (a warm slot worktree first, else the clone) and run the slice gate for both
# platforms with the host arch, reporting which are viable. Reports "no ios/
# tree found" when neither a slot nor the clone has one.
doctor_repo_viability() {
  local repo arch; arch=$(host_arch)
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    local dir='' clone slot0
    clone=$(clone_dir "$repo")
    slot0="$SLOTS_DIR/$(slot_name "$repo" 0)"
    if [ -d "$slot0/ios" ]; then dir=$slot0
    elif [ -d "$clone/ios" ]; then dir=$clone
    fi
    if [ -z "$dir" ]; then
      info "$repo: no ios/ tree found (warm a slot or clone first to check slices)"
      continue
    fi
    local sim_r dev_r sim_ok dev_ok
    if sim_r=$(slice_gate "$dir" sim "$arch"); then sim_ok="viable"; else sim_ok="NO ($sim_r)"; fi
    if dev_r=$(slice_gate "$dir" device "$arch"); then dev_ok="viable"; else dev_ok="NO ($dev_r)"; fi
    info "$repo ($arch): --sim: $sim_ok"
    info "$repo ($arch): --device: $dev_ok"
  done <<< "$(config_repos)"
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
fm-mobile-lab - build/test React Native branches on iOS sims and devices by
                wrapping each repo's own run command, with warm git-worktree
                slots, per-slot Metro ports, a node_modules cache, a
                framework-slice pre-flight gate, and streaming progress.

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

The lab wraps the repo's configured run_command (e.g. react-native run-ios;
post-Expo, npx expo run:ios), appending the resolved concrete target (--udid)
and this slot's Metro port. It does NOT reimplement xcodebuild. A pre-flight
framework-slice check fails fast when the app cannot build for the target (e.g.
an FFmpeg framework with no arm64-simulator slice -> "use --device"). Build
progress streams to the terminal and to state/build-<slot>.log, and a
machine-readable status file lands at state/lab-build-<slot>.json.

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
