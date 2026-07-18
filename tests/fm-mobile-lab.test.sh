#!/usr/bin/env bash
# Behavior tests for fm-mobile-lab's logic without a real build: toolchain
# detection, lockfile hashing, per-slot port assignment, LRU slot picking,
# config parsing (including run_command), run-command assembly, the framework-
# slice compatibility gate (with stubbed lipo/vtool over a fixture), build-status
# file emission (the console contract), and the per-slot build lock. The wrapped
# native build and device launch are exercised on real hardware via `doctor` plus
# a live dry-run (see docs/mobile-lab.md); they cannot run in CI.
set -u
# shellcheck disable=SC1091

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENGINE="$ROOT/bin/fm-mobile-lab.sh"
TMP_ROOT=$(fm_test_tmproot fm-mobile-lab-tests)
mkdir -p "$TMP_ROOT"

# Source the engine as a library so we can call its functions directly.
# FM_MOBILE_LAB_LIB=1 suppresses main(). Point config/lab home at scratch.
export FM_MOBILE_LAB_LIB=1
export FM_MOBILE_LAB_HOME="$TMP_ROOT/lab"
export FM_MOBILE_LAB_CONFIG="$TMP_ROOT/config/mobile-lab.json"
# shellcheck source=/dev/null
. "$ENGINE"
# The engine runs `set -euo pipefail` at top level, which leaks into this test
# shell when sourced. Tests deliberately capture non-zero exits (out=$(cmd); rc=$?),
# so restore the test harness's own errexit-off posture; keep nounset.
set +e +o pipefail

# --- toolchain detection ----------------------------------------------------

test_detect_pkgmgr() {
  local d="$TMP_ROOT/pm"
  mkdir -p "$d/pnpm" "$d/npm" "$d/yarn" "$d/none"
  : > "$d/pnpm/pnpm-lock.yaml"
  : > "$d/npm/package-lock.json"
  : > "$d/yarn/yarn.lock"
  [ "$(detect_pkgmgr "$d/pnpm")" = pnpm ] || fail "pnpm-lock.yaml -> pnpm"
  [ "$(detect_pkgmgr "$d/npm")"  = npm ]  || fail "package-lock.json -> npm"
  [ "$(detect_pkgmgr "$d/yarn")" = yarn ] || fail "yarn.lock -> yarn"
  if detect_pkgmgr "$d/none" >/dev/null 2>&1; then fail "no lockfile should fail"; fi
  pass "detect_pkgmgr reads the lockfile per checkout"
}

test_pnpm_wins_over_npm() {
  local d="$TMP_ROOT/pm-both"; mkdir -p "$d"
  : > "$d/pnpm-lock.yaml"; : > "$d/package-lock.json"
  [ "$(detect_pkgmgr "$d")" = pnpm ] || fail "pnpm should win over npm when both present"
  pass "detect_pkgmgr precedence pnpm > npm"
}

test_detect_node_version() {
  local d="$TMP_ROOT/nv"; mkdir -p "$d/nvmrc" "$d/nodev" "$d/engines" "$d/none"
  printf 'v20.11.1\n' > "$d/nvmrc/.nvmrc"
  printf '18.19.0\n'  > "$d/nodev/.node-version"
  printf '{"engines":{"node":">=22.0.0"}}\n' > "$d/engines/package.json"
  printf '{}\n' > "$d/none/package.json"
  [ "$(detect_node_version "$d/nvmrc")"   = "20.11.1" ] || fail ".nvmrc strips leading v"
  [ "$(detect_node_version "$d/nodev")"   = "18.19.0" ] || fail ".node-version read"
  [ "$(detect_node_version "$d/engines")" = "22.0.0" ]  || fail "engines range operator stripped"
  [ -z "$(detect_node_version "$d/none")" ]             || fail "unspecified node version -> empty"
  pass "detect_node_version reads nvmrc/.node-version/engines and normalizes"
}

# --- node switching (switch_node / node_version_matches) --------------------
#
# A fake fnm + node pair on PATH, driven by a marker file, stands in for the
# real toolchain so this is hermetic. The fake node reports v24.16.0 UNTIL the
# fake fnm's "env" subcommand has run in this shell (FM_TEST_FAKE_FNM_ENV=1):
# only then does "fnm use <v>" flip the marker file the fake node reads from.
# This reproduces the real bug: fnm use without fnm env first must be a no-op on
# node --version.

fm_fake_fnm_node() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/fnm" <<'SH'
#!/usr/bin/env bash
case "$1" in
  env)
    printf 'export FM_TEST_FAKE_FNM_ENV=1\n'
    ;;
  use)
    if [ "${FM_TEST_FAKE_FNM_ENV:-0}" != 1 ]; then
      echo "fnm: environment not set up, run fnm env first" >&2
      exit 1
    fi
    v=${2%.}
    case "$v" in
      99.*) echo "fnm: no installation found for $v" >&2; exit 1 ;;
    esac
    printf '%s\n' "$v" > "$FM_TEST_FAKE_NODE_STATE"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/fnm"
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  if [ -s "$FM_TEST_FAKE_NODE_STATE" ]; then
    printf 'v%s\n' "$(cat "$FM_TEST_FAKE_NODE_STATE")"
  else
    printf 'v24.16.0\n'
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/node"
  printf '%s\n' "$fakebin"
}

test_node_version_matches() {
  node_version_matches 20 v20.18.3 || fail "bare major should match"
  node_version_matches 20.18 v20.18.3 || fail "major.minor should match"
  node_version_matches 20.18.3 v20.18.3 || fail "exact should match"
  node_version_matches "20.18." v20.18.3 || fail "trailing-dot form should match"
  node_version_matches 21 v20.18.3 && fail "different major must not match"
  node_version_matches 20.19 v20.18.3 && fail "different minor must not match"
  pass "node_version_matches accepts a requested prefix of the actual version"
}

# fm_fake_fnm_downgrade <dir>: a fake fnm+node modelling THE SMM BUG. `fnm env`
# switches the shell to fnm's DEFAULT node (v20.18.3) by exporting a marker; the
# fake node reports v20.18.3 once that marker is set, else the ambient v24.16.0.
# `fnm use <v>` ALWAYS fails (fnm has no node installed here), exactly like a
# machine where node 24 was installed via nvm, not fnm. So the ONLY way to keep
# node at the ambient v24.16.0 is to never eval fnm env - which is precisely what
# switch_node must do when the ambient node already satisfies the request.
fm_fake_fnm_downgrade() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/fnm" <<'SH'
#!/usr/bin/env bash
case "$1" in
  env) printf 'export FM_TEST_FNM_DOWNGRADED=1\n' ;;   # env drops us to fnm default
  use) echo "error: Requested version is not currently installed" >&2; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/fnm"
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  if [ "${FM_TEST_FNM_DOWNGRADED:-0}" = 1 ]; then printf 'v20.18.3\n'; else printf 'v24.16.0\n'; fi
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/node"
  printf '%s\n' "$fakebin"
}

test_switch_node_keeps_ambient_node_when_it_already_satisfies() {
  # THE SMM DEPS FIX: when the ambient node already satisfies the requested
  # version, switch_node must NOT touch fnm at all - because `fnm env` would drop
  # the shell to fnm's default (older) node and break an engine-strict package
  # manager (pnpm needs node >= 22.13). Here the ambient node is v24.16.0, the
  # request is node 24, and fnm has no node 24: the only correct behavior is to
  # keep v24.16.0.
  local d="$TMP_ROOT/switch-keep-ambient" out
  mkdir -p "$d"
  unset FM_TEST_FNM_DOWNGRADED
  PATH="$(fm_fake_fnm_downgrade "$d"):$PATH"
  out=$(switch_node "24.16.0" 2>&1)
  [ "$(node --version)" = "v24.16.0" ] || fail "switch_node must keep the ambient node 24 (not downgrade to fnm's default 20)"
  assert_not_contains "$out" "WARNING" "keeping an already-satisfying ambient node must not warn"
  pass "switch_node keeps the ambient node when it already satisfies the request (the SMM deps fix: no fnm-env downgrade)"
}

test_switch_node_restores_ambient_when_fnm_cannot_provide() {
  # When the ambient node does NOT satisfy the request AND fnm cannot provide the
  # version, switch_node must fall back to the ambient node, never leave the shell
  # on fnm's (worse) default. Ambient here is v24.16.0; request node 25 (fnm
  # lacks it). Result: still on v24.16.0, with a loud warning.
  local d="$TMP_ROOT/switch-restore-ambient" out
  mkdir -p "$d"
  unset FM_TEST_FNM_DOWNGRADED
  PATH="$(fm_fake_fnm_downgrade "$d"):$PATH"
  out=$(switch_node "25.0.0" 2>&1)
  [ "$(node --version)" = "v24.16.0" ] || fail "a failed fnm switch must restore the ambient node, not leave fnm's default 20"
  assert_contains "$out" "WARNING" "a version fnm cannot provide must warn"
  assert_contains "$out" "25" "the warning should name the requested version"
  pass "switch_node restores the ambient node (not fnm's default) when fnm cannot provide the requested version"
}

test_switch_node_evals_fnm_env_before_use() {
  local d="$TMP_ROOT/switch-ok" out
  mkdir -p "$d"
  export FM_TEST_FAKE_NODE_STATE="$d/node-version"
  PATH="$(fm_fake_fnm_node "$d"):$PATH"
  unset FM_TEST_FAKE_FNM_ENV
  out=$(switch_node "20.18." 2>&1)
  [ "$(cat "$d/node-version")" = "20.18" ] || fail "fake fnm use never ran (fnm env was not eval'd first)"
  [ "$(node --version)" = "v20.18" ] || fail "node --version should reflect the switched version"
  assert_not_contains "$out" "WARNING" "a successful switch must not warn"
  pass "switch_node evaluates fnm env before fnm use, so the switch actually takes"
}

test_switch_node_warns_loudly_on_failed_switch() {
  local d="$TMP_ROOT/switch-fail" out
  mkdir -p "$d"
  export FM_TEST_FAKE_NODE_STATE="$d/node-version"
  PATH="$(fm_fake_fnm_node "$d"):$PATH"
  unset FM_TEST_FAKE_FNM_ENV
  out=$(switch_node "99.0.0" 2>&1)
  assert_contains "$out" "WARNING" "a version fnm cannot resolve must warn"
  assert_contains "$out" "99.0.0" "warning should name the requested version"
  assert_contains "$out" "v24.16.0" "warning should name the ambient (unswitched) version"
  pass "switch_node warns loudly when a present fnm fails to switch"
}

test_switch_node_noop_without_fnm() {
  local d="$TMP_ROOT/switch-nofnm" out fakebin
  mkdir -p "$d"
  fakebin=$(fm_fakebin "$d")
  out=$(PATH="$fakebin:/usr/bin:/bin" switch_node "20" 2>&1)
  assert_contains "$out" "fnm is not installed" "missing fnm should warn, not fail"
  pass "switch_node is a no-op warning when fnm is absent"
}

test_switch_node_noop_without_version() {
  local out rc
  out=$(switch_node "" 2>&1); rc=$?
  [ -z "$out" ] || fail "no version requested should produce no output"
  expect_code 0 "$rc" "no version requested should return success"
  pass "switch_node returns early when no version is requested"
}

# --- hashing determinism ----------------------------------------------------

test_lockfile_hash_determinism() {
  local a="$TMP_ROOT/h/a" b="$TMP_ROOT/h/b" c="$TMP_ROOT/h/c"
  mkdir -p "$a" "$b" "$c"
  printf 'lockfile-contents-XYZ\n' > "$a/pnpm-lock.yaml"
  printf 'lockfile-contents-XYZ\n' > "$b/pnpm-lock.yaml"   # identical
  printf 'lockfile-contents-DIFFERENT\n' > "$c/pnpm-lock.yaml"
  local ha hb hc
  ha=$(hash_lockfile "$a" pnpm); hb=$(hash_lockfile "$b" pnpm); hc=$(hash_lockfile "$c" pnpm)
  [ -n "$ha" ] || fail "hash should be non-empty"
  [ "$ha" = "$hb" ] || fail "identical lockfiles must hash the same ($ha vs $hb)"
  [ "$ha" != "$hc" ] || fail "different lockfiles must hash differently"
  pass "hash_lockfile is deterministic and content-sensitive"
}

# --- port assignment --------------------------------------------------------

test_metro_port() {
  [ "$(metro_port 8101 0)" = 8101 ] || fail "slot 0 -> base"
  [ "$(metro_port 8101 2)" = 8103 ] || fail "slot 2 -> base+2"
  [ "$(metro_port 8111 1)" = 8112 ] || fail "different base"
  pass "metro_port is base + slot index (fixed, deterministic)"
}

test_slot_name() {
  [ "$(slot_name sitemate-mobile 1)" = "sitemate-mobile-1" ] || fail "slot_name format"
  pass "slot_name composes repo and index"
}

# --- run-command assembly ---------------------------------------------------

test_build_run_command_assembly() {
  # A react-native run-ios base with a scheme carrying a space, plus a resolved
  # --udid target and a slot port, must assemble to the exact expected string.
  local base="react-native run-ios --scheme 'Dashpivot Dev'"
  local got exp
  got=$(build_run_command "$base" --udid "00008110-000231D414D8401E" 8111)
  exp="react-native run-ios --scheme 'Dashpivot Dev' --udid '00008110-000231D414D8401E' --port 8111"
  [ "$got" = "$exp" ] || fail "assembled command mismatch:\n  got: $got\n  exp: $exp"
  pass "build_run_command appends --udid <target> and --port <N> exactly"
}

test_build_run_command_expo_form() {
  # The Expo form (npx expo run:ios) must wrap with ZERO special-casing: the lab
  # still just appends the target flag and port.
  local got exp
  got=$(build_run_command "npx expo run:ios" --udid ABC123 8081)
  exp="npx expo run:ios --udid 'ABC123' --port 8081"
  [ "$got" = "$exp" ] || fail "expo-form assembly mismatch:\n  got: $got\n  exp: $exp"
  pass "build_run_command wraps npx expo run:ios with no special-casing"
}

test_build_run_command_quotes_single_quotes() {
  # A target value with an embedded single quote must be shell-safe.
  local got
  got=$(build_run_command "run-ios" --simulator "Thev's iPhone" 8100)
  # 'Thev'\''s iPhone' is the correct single-quote-escaped form.
  assert_contains "$got" "'Thev'\\''s iPhone'" "single quotes in a target must be escaped"
  pass "build_run_command shell-escapes single quotes in the target value"
}

test_build_run_command_no_target_flag() {
  # An empty target flag appends only the port (target already implied).
  local got
  got=$(build_run_command "react-native run-ios" "" "" 8090)
  [ "$got" = "react-native run-ios --port 8090" ] || fail "empty target flag should append only the port: $got"
  pass "build_run_command appends only the port when no target flag is given"
}

# --- framework-slice compatibility gate -------------------------------------
#
# lipo/vtool are macOS-only, so CI stubs them via fakebin over a fixture. Each
# fixture "binary" is a plain file whose FIRST line is a lipo -archs answer
# ("x86_64 arm64") and whose remaining lines are "vtool:<arch>:<PLATFORM>"
# records. The fake lipo/vtool read those records, exactly mirroring the real
# tools' output shape, so slice_gate's real logic is exercised end to end.

# fm_slice_fakebin <dir>: install fake lipo + vtool that read the fixture format
# and echo that fakebin dir.
fm_slice_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/lipo" <<'SH'
#!/usr/bin/env bash
# fake lipo: supports `lipo -archs <file>` and `lipo -info <file>`.
mode=$1; file=$2
[ -f "$file" ] || { echo "lipo: can't open: $file" >&2; exit 1; }
archs=$(head -1 "$file")
case "$mode" in
  -archs) printf '%s\n' "$archs" ;;
  -info)  printf 'Architectures in the fat file: %s are: %s\n' "$file" "$archs" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/lipo"
  cat > "$fakebin/vtool" <<'SH'
#!/usr/bin/env bash
# fake vtool: `vtool -arch <arch> -show-build <file>` prints "platform <TOKEN>"
# from the fixture's "vtool:<arch>:<TOKEN>" records. Exits non-zero when the
# requested arch has no record (mirroring vtool failing on a missing slice).
arch=''; file=''
while [ $# -gt 0 ]; do
  case "$1" in
    -arch) shift; arch=$1 ;;
    -show-build) shift; file=$1 ;;
    *) : ;;
  esac
  shift
done
[ -f "$file" ] || exit 1
tok=$(grep "^vtool:$arch:" "$file" | head -1 | cut -d: -f3)
[ -n "$tok" ] || exit 1
printf '%s (architecture %s):\n platform %s\n' "$file" "$arch" "$tok"
SH
  chmod +x "$fakebin/vtool"
  printf '%s\n' "$fakebin"
}

# fm_make_fixture_fw <checkout> <framework-name> <archs-line> <vtool-records...>:
# create ios/<name>.framework/<name> with the fixture format.
fm_make_fixture_fw() {
  local checkout=$1 name=$2 archs=$3; shift 3
  local fw="$checkout/ios/$name.framework"
  mkdir -p "$fw"
  { printf '%s\n' "$archs"; for r in "$@"; do printf '%s\n' "$r"; done; } > "$fw/$name"
}

test_slice_gate_blocks_ffmpeg_on_sim() {
  # The dashpivot FFmpeg case: libavcodec has x86_64 (IOSSIMULATOR) + arm64
  # (IOS device), NO arm64-simulator slice. An arm64 --sim build must fail fast.
  local d="$TMP_ROOT/gate-ffmpeg"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libavcodec "x86_64 arm64" \
    "vtool:x86_64:IOSSIMULATOR" "vtool:arm64:IOS"
  local out rc
  out=$(PATH="$(fm_slice_fakebin "$d"):$PATH" slice_gate "$d" sim arm64); rc=$?
  expect_code 1 "$rc" "arm64 sim build of an FFmpeg app must be gated"
  assert_contains "$out" "libavcodec" "the blocking framework must be named"
  assert_contains "$out" "arm64-simulator" "the missing slice must be named"
  assert_contains "$out" "--device" "the viable alternative (--device) must be steered to"
  pass "slice_gate fails fast for arm64-sim on an FFmpeg app, naming the framework and steering to --device"
}

test_slice_gate_allows_ffmpeg_on_device() {
  # The SAME framework on --device (arm64/IOS) has a matching slice: must pass.
  local d="$TMP_ROOT/gate-ffmpeg-dev"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libavcodec "x86_64 arm64" \
    "vtool:x86_64:IOSSIMULATOR" "vtool:arm64:IOS"
  local out rc
  out=$(PATH="$(fm_slice_fakebin "$d"):$PATH" slice_gate "$d" device arm64); rc=$?
  expect_code 0 "$rc" "arm64 device build of an FFmpeg app must pass"
  [ -z "$out" ] || fail "a passing gate should print nothing, got: $out"
  pass "slice_gate passes for arm64-device on an FFmpeg app (a matching slice exists)"
}

test_slice_gate_allows_universal_sim() {
  # A framework with a proper arm64-simulator slice must pass on --sim.
  local d="$TMP_ROOT/gate-universal"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libgood "x86_64 arm64" \
    "vtool:x86_64:IOSSIMULATOR" "vtool:arm64:IOSSIMULATOR"
  local rc
  PATH="$(fm_slice_fakebin "$d"):$PATH" slice_gate "$d" sim arm64 >/dev/null; rc=$?
  expect_code 0 "$rc" "a framework with an arm64-simulator slice must pass on --sim"
  pass "slice_gate passes when a vendored framework carries the target slice"
}

test_slice_gate_no_frameworks_passes() {
  # A checkout with no vendored frameworks has nothing to block: pass.
  local d="$TMP_ROOT/gate-empty"
  mkdir -p "$d/ios"
  local rc
  PATH="$(fm_slice_fakebin "$d"):$PATH" slice_gate "$d" sim arm64 >/dev/null; rc=$?
  expect_code 0 "$rc" "no vendored frameworks -> nothing to gate -> pass"
  pass "slice_gate passes when there are no vendored frameworks to check"
}

test_slice_gate_allows_when_lipo_absent() {
  # With no lipo on PATH, the gate cannot check and must allow (never a false
  # block on a machine without the Mach-O tools).
  local d="$TMP_ROOT/gate-nolipo" fakebin
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libavcodec "x86_64 arm64" "vtool:arm64:IOS"
  fakebin=$(fm_fakebin "$d")   # empty fakebin: no lipo, no vtool
  local rc
  PATH="$fakebin:/usr/bin:/bin" slice_gate "$d" sim arm64 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "no lipo -> cannot gate -> allow (no false block)"
  pass "slice_gate allows (cannot gate) when lipo is unavailable"
}

test_target_platform_token() {
  [ "$(target_platform_token sim)" = "IOSSIMULATOR" ] || fail "sim -> IOSSIMULATOR"
  [ "$(target_platform_token device)" = "IOS" ] || fail "device -> IOS"
  pass "target_platform_token maps platforms to Mach-O build tokens"
}

# --- simulator arch resolution: native arm64 vs x86_64+Rosetta --------------
#
# resolve_sim_arch decides the --sim build arch from the app's slices plus
# Rosetta availability. These tests pin the host to arm64 (the Apple-Silicon
# case the fix targets) by overriding host_arch, and stub Rosetta with
# FM_MOBILE_LAB_FORCE_ROSETTA, so they are deterministic on any CI host.

# with_arm64_host: run a command with host_arch forced to arm64 (restored after).
# host_arch is invoked indirectly by the command run through "$@" (resolve_sim_arch
# reads it), which shellcheck cannot see, hence the SC2329 suppression.
with_arm64_host() {
  local saved; saved=$(declare -f host_arch)
  # shellcheck disable=SC2329  # invoked indirectly by "$@" (resolve_sim_arch calls it)
  host_arch() { printf 'arm64\n'; }
  "$@"; local rc=$?
  eval "$saved"
  return $rc
}

test_resolve_sim_arch_native_arm64() {
  # A framework WITH an arm64-simulator slice -> native arm64 sim build, no
  # Rosetta needed. arch field is arm64.
  local d="$TMP_ROOT/simarch-native"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libgood "x86_64 arm64" \
    "vtool:x86_64:IOSSIMULATOR" "vtool:arm64:IOSSIMULATOR"
  local out rc arch
  out=$(PATH="$(fm_slice_fakebin "$d"):$PATH" FM_MOBILE_LAB_FORCE_ROSETTA=1 \
        with_arm64_host resolve_sim_arch "$d"); rc=$?
  expect_code 0 "$rc" "an arm64-simulator-capable app resolves a viable sim arch"
  arch=${out%%$'\t'*}
  [ "$arch" = "arm64" ] || fail "native arm64-sim app must resolve arch arm64, got: $arch"
  assert_contains "$out" "native" "the reason should note the native path"
  pass "resolve_sim_arch picks native arm64 when an arm64-simulator slice exists"
}

test_resolve_sim_arch_x86_rosetta() {
  # The FFmpeg case: x86_64-sim + arm64-device slices, NO arm64-sim. With Rosetta
  # available, resolve_sim_arch must choose x86_64 (the Rosetta path), NOT block.
  local d="$TMP_ROOT/simarch-rosetta"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libavcodec "x86_64 arm64" \
    "vtool:x86_64:IOSSIMULATOR" "vtool:arm64:IOS"
  local out rc arch
  out=$(PATH="$(fm_slice_fakebin "$d"):$PATH" FM_MOBILE_LAB_FORCE_ROSETTA=1 \
        with_arm64_host resolve_sim_arch "$d"); rc=$?
  expect_code 0 "$rc" "an x86_64-sim FFmpeg app with Rosetta must be viable on --sim"
  arch=${out%%$'\t'*}
  [ "$arch" = "x86_64" ] || fail "FFmpeg sim app with Rosetta must resolve arch x86_64, got: $arch"
  assert_contains "$out" "Rosetta" "the reason should note the Rosetta path"
  pass "resolve_sim_arch picks x86_64 via Rosetta for an FFmpeg app (no arm64-sim slice) when Rosetta is available"
}

test_resolve_sim_arch_x86_no_rosetta_fails() {
  # SAME FFmpeg app, but Rosetta NOT available: no viable sim arch -> return 1,
  # empty arch field, and a reason that names Rosetta and steers to --device.
  local d="$TMP_ROOT/simarch-norosetta"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libavcodec "x86_64 arm64" \
    "vtool:x86_64:IOSSIMULATOR" "vtool:arm64:IOS"
  local out rc arch reason
  out=$(PATH="$(fm_slice_fakebin "$d"):$PATH" FM_MOBILE_LAB_FORCE_ROSETTA=0 \
        with_arm64_host resolve_sim_arch "$d"); rc=$?
  expect_code 1 "$rc" "an x86_64-only sim app with no Rosetta has no viable sim arch"
  arch=${out%%$'\t'*}
  [ -z "$arch" ] || fail "a non-viable sim resolution must leave the arch field empty, got: $arch"
  reason=${out#*$'\t'}
  assert_contains "$reason" "Rosetta" "the reason must explain Rosetta is unavailable"
  assert_contains "$reason" "--device" "the reason must steer to --device"
  pass "resolve_sim_arch fails (no viable arch) for an x86_64-only sim app when Rosetta is unavailable, steering to --device"
}

test_resolve_sim_arch_no_sim_slice_fails() {
  # An app whose only slice is arm64-device (no sim slice at all) has no viable
  # sim arch regardless of Rosetta.
  local d="$TMP_ROOT/simarch-nosim"
  mkdir -p "$d/ios"
  fm_make_fixture_fw "$d" libonlydev "arm64" "vtool:arm64:IOS"
  local out rc arch
  out=$(PATH="$(fm_slice_fakebin "$d"):$PATH" FM_MOBILE_LAB_FORCE_ROSETTA=1 \
        with_arm64_host resolve_sim_arch "$d"); rc=$?
  expect_code 1 "$rc" "a device-only app has no viable sim arch even with Rosetta"
  arch=${out%%$'\t'*}
  [ -z "$arch" ] || fail "no-sim-slice app must leave the arch field empty, got: $arch"
  pass "resolve_sim_arch fails for an app with no simulator slice at all"
}

test_sim_arch_extra_args() {
  # x86_64 forces ARCHS=x86_64 via --extra-params; arm64 (native) forces nothing.
  local x86 arm
  x86=$(sim_arch_extra_args x86_64)
  assert_contains "$x86" "--extra-params" "x86_64 must pass extra-params to xcodebuild"
  assert_contains "$x86" "ARCHS=x86_64" "x86_64 must force ARCHS=x86_64"
  assert_contains "$x86" "ONLY_ACTIVE_ARCH=NO" "x86_64 must disable ONLY_ACTIVE_ARCH so pods build x86_64 too"
  arm=$(sim_arch_extra_args arm64)
  [ -z "$arm" ] || fail "a native arm64 sim build must add no arch-forcing args, got: $arm"
  pass "sim_arch_extra_args forces ARCHS=x86_64 for the Rosetta path and nothing for native arm64"
}

test_build_run_command_appends_extra_args() {
  # The Rosetta path's extra args must be appended verbatim after the port, so
  # the produced command forces x86_64 while staying command-agnostic.
  local got exp
  got=$(build_run_command "react-native run-ios --scheme 'Dashpivot Dev'" \
        --udid ABC123 8113 "--extra-params 'ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO'")
  exp="react-native run-ios --scheme 'Dashpivot Dev' --udid 'ABC123' --port 8113 --extra-params 'ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO'"
  [ "$got" = "$exp" ] || fail "extra-args must be appended after the port:\n  got: $got\n  exp: $exp"
  # And the whole x86_64 assembly straight from sim_arch_extra_args must round-trip.
  local got2
  got2=$(build_run_command "react-native run-ios" --udid U 8113 "$(sim_arch_extra_args x86_64)")
  assert_contains "$got2" "ARCHS=x86_64" "the x86_64 sim command must carry ARCHS=x86_64"
  pass "build_run_command appends the arch-forcing extra args for the Rosetta sim path"
}

test_sim_runtime_runs_x86() {
  # iOS <= 18 runs x86_64 under Rosetta; iOS 26+ does not (Apple dropped it).
  sim_runtime_runs_x86 "18.5" || fail "iOS 18.5 must be x86-capable"
  sim_runtime_runs_x86 "16.0" || fail "iOS 16.0 must be x86-capable"
  sim_runtime_runs_x86 "18" || fail "bare major 18 must be x86-capable"
  sim_runtime_runs_x86 "26.4" && fail "iOS 26.4 must NOT be x86-capable"
  sim_runtime_runs_x86 "26.5" && fail "iOS 26.5 must NOT be x86-capable"
  sim_runtime_runs_x86 "" && fail "an empty/garbage version must not be treated as x86-capable"
  pass "sim_runtime_runs_x86 treats iOS <= 18 as x86-capable and iOS 26+ (and blanks) as not"
}

test_rosetta_available_override() {
  # The test override must be honoured so the probe is deterministic in CI.
  FM_MOBILE_LAB_FORCE_ROSETTA=1 rosetta_available || fail "FORCE_ROSETTA=1 must report available"
  FM_MOBILE_LAB_FORCE_ROSETTA=0 rosetta_available && fail "FORCE_ROSETTA=0 must report unavailable"
  pass "rosetta_available honours the FM_MOBILE_LAB_FORCE_ROSETTA test override"
}

# --- build-status file emission (the console contract) ----------------------

test_status_file_is_contract_shaped() {
  local labhome="$TMP_ROOT/lab-status" fmhome="$TMP_ROOT/fm-home-status"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  # Set the status globals as run_build would, then emit a phase. These are
  # consumed by the sourced engine's status_write, not visibly in this file.
  # shellcheck disable=SC2034
  {
    ST_SLOT="dashpivot-mobile-0" ST_REPO="dashpivot-mobile" ST_BRANCH="release/26.9"
    ST_PLATFORM="device" ST_TARGET="Thev's iPhone (iOS 26.5)"
    ST_RUN_COMMAND="react-native run-ios --scheme 'Dashpivot Dev'"
    ST_PORT=8111 ST_STATUS="running" ST_ERROR="null" ST_STARTED=1784300000
    ST_PERCENT="null" ST_LOGFILE="$STATE_DIR/build-dashpivot-mobile-0.log" ST_PHASE_TOTAL=7
  }
  status_phase compile 5 "Compiling React-Core"

  local f; f="$FM_STATE_DIR/lab-build-dashpivot-mobile-0.json"
  [ -f "$f" ] || fail "status file was not written to firstmate's state dir ($f)"
  [ ! -f "$STATE_DIR/lab-build-dashpivot-mobile-0.json" ] \
    || fail "status file must NOT be written to the lab's private STATE_DIR (the console cannot see it there)"
  jq -e . "$f" >/dev/null || fail "status file must be valid JSON"
  # Every contract field must be present and correctly typed.
  [ "$(jq -r '.schema' "$f")" = "1" ] || fail "schema must be 1"
  [ "$(jq -r '.slot' "$f")" = "dashpivot-mobile-0" ] || fail "slot"
  [ "$(jq -r '.repo' "$f")" = "dashpivot-mobile" ] || fail "repo"
  [ "$(jq -r '.platform' "$f")" = "device" ] || fail "platform"
  [ "$(jq -r '.target' "$f")" = "Thev's iPhone (iOS 26.5)" ] || fail "target preserved verbatim"
  [ "$(jq -r '.run_command' "$f")" = "react-native run-ios --scheme 'Dashpivot Dev'" ] || fail "run_command preserved"
  [ "$(jq -r '.port' "$f")" = "8111" ] || fail "port is a number"
  [ "$(jq -r '.phase' "$f")" = "compile" ] || fail "phase"
  [ "$(jq -r '.phase_index' "$f")" = "5" ] || fail "phase_index"
  [ "$(jq -r '.phase_total' "$f")" = "7" ] || fail "phase_total"
  [ "$(jq -r '.status' "$f")" = "running" ] || fail "status"
  # percent must be a REAL null (honest unknown), not the string "null".
  [ "$(jq -r '.percent | type' "$f")" = "null" ] || fail "percent must be JSON null when unknown, never a fake bar"
  [ "$(jq -r '.error | type' "$f")" = "null" ] || fail "error must be JSON null while running"
  [ "$(jq -r '.logfile' "$f")" = "$STATE_DIR/build-dashpivot-mobile-0.log" ] || fail "logfile must be an absolute path the console/captain can actually open"
  [ "$(jq -r '.started_epoch' "$f")" = "1784300000" ] || fail "started_epoch"
  [ "$(jq -r '.updated_epoch | type' "$f")" = "number" ] || fail "updated_epoch is a number"
  [ "$(jq -r '.phase_started_epoch | type' "$f")" = "number" ] || fail "phase_started_epoch is a number"
  # metro_running is a real JSON boolean (this port is not bound in the test, so false).
  [ "$(jq -r '.metro_running | type' "$f")" = "boolean" ] || fail "metro_running must be a JSON boolean"
  pass "status_write emits a contract-shaped JSON with correct types, a real null percent, a boolean metro_running, and lands under firstmate's state dir with an absolute logfile"
}

test_status_file_path_uses_fm_state_dir_not_lab_home() {
  # The console (bin/fm-console/src/io.js readLabBuildStatuses) scans FM_HOME's
  # own state/ dir, never LAB_HOME. status_file_path must resolve there.
  local labhome="$TMP_ROOT/lab-path" fmhome="$TMP_ROOT/fm-home-path"
  STATE_DIR="$labhome/state"
  FM_STATE_DIR="$fmhome/state"
  local got; got=$(status_file_path "dashpivot-mobile-0")
  [ "$got" = "$FM_STATE_DIR/lab-build-dashpivot-mobile-0.json" ] \
    || fail "status_file_path should resolve under FM_STATE_DIR, got: $got"
  case "$got" in
    "$LAB_HOME"/*) fail "status_file_path must never resolve under LAB_HOME ($LAB_HOME): got $got" ;;
  esac
  pass "status_file_path resolves the console-facing status file under firstmate's state dir, not LAB_HOME"
}

test_fm_state_dir_respects_fm_state_override() {
  # FM_STATE_DIR must resolve the same way every other bin/ script resolves
  # firstmate's state dir: FM_STATE_OVERRIDE wins, else FM_HOME/state.
  local out
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/custom-fm-state" FM_MOBILE_LAB_LIB=1 bash -c '
    . "'"$ENGINE"'"
    printf "%s\n" "$FM_STATE_DIR"
  ')
  [ "$out" = "$TMP_ROOT/custom-fm-state" ] || fail "FM_STATE_OVERRIDE should win, got: $out"
  pass "FM_STATE_DIR honors FM_STATE_OVERRIDE exactly like other bin/ scripts"
}

test_status_fail_sets_error_string() {
  local labhome="$TMP_ROOT/lab-status-fail" fmhome="$TMP_ROOT/fm-home-status-fail"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  # shellcheck disable=SC2034
  {
    ST_SLOT="s0" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="sim" ST_TARGET="t"
    ST_RUN_COMMAND="c" ST_PORT=8100 ST_STATUS="running" ST_ERROR="null"
    ST_STARTED=1 ST_PERCENT="null" ST_LOGFILE="$STATE_DIR/build-s0.log" ST_PHASE_TOTAL=7
    ST_PHASE="preflight" ST_PHASE_INDEX=1
  }
  status_fail "libavcodec has no arm64-simulator slice; use --device"
  local f; f="$FM_STATE_DIR/lab-build-s0.json"
  [ "$(jq -r '.status' "$f")" = "failed" ] || fail "status must be failed"
  [ "$(jq -r '.error' "$f")" = "libavcodec has no arm64-simulator slice; use --device" ] || fail "error string must be the specific reason"
  pass "status_fail records failed status with a specific error string under firstmate's state dir"
}

test_status_message_refines_compile_percent() {
  local labhome="$TMP_ROOT/lab-status-pct" fmhome="$TMP_ROOT/fm-home-status-pct"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  # shellcheck disable=SC2034
  {
    ST_SLOT="s0" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="sim" ST_TARGET="t"
    ST_RUN_COMMAND="c" ST_PORT=8100 ST_STATUS="running" ST_ERROR="null"
    ST_STARTED=1 ST_PERCENT="null" ST_LOGFILE="l" ST_PHASE_TOTAL=7
    ST_PHASE="compile" ST_PHASE_INDEX=5 ST_PHASE_STARTED=1
  }
  # parse_compile_count over a real CLI-ish line, then feed it as a percent.
  local pct; pct=$(parse_compile_count "Compiling React-Core (1050/2100)")
  [ "$pct" = "50" ] || fail "parse_compile_count should read 1050/2100 as 50, got: $pct"
  status_message "Compiling React-Core (1050/2100)" "$pct"
  local f; f="$FM_STATE_DIR/lab-build-s0.json"
  [ "$(jq -r '.percent' "$f")" = "50" ] || fail "a parsed compile count must set a real integer percent"
  pass "parse_compile_count + status_message set an honest integer percent from a real X/Y count"
}

test_no_fake_percent_without_count() {
  # A plain compile line with no X/Y count must leave percent null (no fake bar).
  local pct; pct=$(parse_compile_count "Compiling something with no count")
  [ -z "$pct" ] || fail "a line with no X/Y count must yield no percent, got: $pct"
  pass "parse_compile_count yields nothing (percent stays null) when there is no real count"
}

# --- phase inference --------------------------------------------------------

test_infer_phase_from_line() {
  [ "$(infer_phase_from_line "Installing CocoaPods dependencies")" = "pods" ] || fail "pods line"
  [ "$(infer_phase_from_line "Analyzing dependencies")" = "pods" ] || fail "analyzing -> pods"
  [ "$(infer_phase_from_line "CompileC /path/foo.o foo.m")" = "compile" ] || fail "compile line"
  [ "$(infer_phase_from_line "Ld /path/App normal")" = "link" ] || fail "link line"
  [ "$(infer_phase_from_line "Installing \"Dashpivot.app\" on \"Thev's iPhone\"")" = "install" ] || fail "install line"
  [ -z "$(infer_phase_from_line "some unrelated log noise")" ] || fail "noise -> no transition"
  pass "infer_phase_from_line maps CLI markers to the contract's phase vocabulary"
}

# --- per-slot build lock ----------------------------------------------------

test_build_lock_second_refuses() {
  local labhome="$TMP_ROOT/lab-lock"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  export FM_MOBILE_LAB_LOCK_WAIT=0
  acquire_build_lock "sitemate-mobile-0" || fail "first acquire must succeed"
  # The lock now records this test shell's PID ($$), which is alive. A second
  # acquire of the same slot must therefore see a live holder and refuse. Run it
  # in a subshell so its non-zero return does not exit the test.
  local rc
  ( acquire_build_lock "sitemate-mobile-0" ); rc=$?
  expect_code 1 "$rc" "a second build into a locked slot must refuse (exit 1)"
  release_build_lock "sitemate-mobile-0"
  pass "acquire_build_lock refuses a second build into a locked slot"
}

test_build_lock_clears_stale() {
  local labhome="$TMP_ROOT/lab-lock-stale"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  export FM_MOBILE_LAB_LOCK_WAIT=0
  local dir; dir=$(build_lock_dir "s-0")
  mkdir -p "$dir"
  # Record a dead holder PID: pick a PID that is not running. 999999 is almost
  # certainly free; guard by looping if it happens to be alive.
  local deadpid=999999
  while kill -0 "$deadpid" 2>/dev/null; do deadpid=$((deadpid - 1)); done
  printf '%s\n' "$deadpid" > "$dir/pid"
  local out rc
  out=$(acquire_build_lock "s-0" 2>&1); rc=$?
  expect_code 0 "$rc" "a stale lock (dead holder) must be cleared and re-acquired"
  assert_contains "$out" "stale build lock" "clearing a stale lock should be announced"
  [ "$(cat "$dir/pid")" = "$$" ] || fail "the lock should now record our PID"
  release_build_lock "s-0"
  pass "acquire_build_lock detects and clears a stale lock left by a dead holder"
}

test_build_lock_release_only_own() {
  local labhome="$TMP_ROOT/lab-lock-rel"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  local dir; dir=$(build_lock_dir "s-9")
  mkdir -p "$dir"
  printf '%s\n' "424242" > "$dir/pid"   # a PID that is not us
  release_build_lock "s-9"
  [ -d "$dir" ] || fail "release must NOT remove a lock held by another PID"
  # Now make it ours and release.
  printf '%s\n' "$$" > "$dir/pid"
  release_build_lock "s-9"
  [ ! -d "$dir" ] || fail "release must remove a lock we hold"
  pass "release_build_lock removes only a lock this process holds"
}

# --- config parsing (including run_command) ---------------------------------

write_config() {
  mkdir -p "$(dirname "$FM_MOBILE_LAB_CONFIG")"
  cp "$ROOT/docs/examples/mobile-lab.json" "$FM_MOBILE_LAB_CONFIG"
}

test_example_config_is_valid_json() {
  jq -e . "$ROOT/docs/examples/mobile-lab.json" >/dev/null \
    || fail "docs/examples/mobile-lab.json must be valid JSON"
  pass "example config is jq-parseable"
}

test_example_config_has_run_command() {
  # Every repo in the committed example must define run_command (required for a
  # build) so the Expo migration is a config-only edit.
  local repo missing=''
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if [ -z "$(jq -r --arg r "$repo" '.repos[$r].run_command // ""' "$ROOT/docs/examples/mobile-lab.json")" ]; then
      missing="$missing $repo"
    fi
  done <<< "$(jq -r '.repos | keys[]' "$ROOT/docs/examples/mobile-lab.json")"
  [ -z "$missing" ] || fail "example repos missing run_command:$missing"
  # And the dashpivot example must carry the space-bearing scheme so the audit's
  # workspace-vs-scheme bug cannot recur silently.
  [ "$(jq -r '.repos["dashpivot-mobile"].run_command' "$ROOT/docs/examples/mobile-lab.json")" \
    = "react-native run-ios --scheme 'Dashpivot Dev'" ] || fail "dashpivot run_command should carry the 'Dashpivot Dev' scheme"
  pass "example config defines run_command per repo (Expo migration is a config edit)"
}

test_config_parsing() {
  write_config
  config_present || fail "config_present should be true after write"
  config_repo_exists sitemate-mobile || fail "sitemate-mobile should exist in config"
  config_repo_exists nonesuch && fail "nonesuch should not exist in config"
  [ "$(config_repo_field sitemate-mobile run_command)" = "react-native run-ios --scheme Sitemate" ] || fail "run_command read"
  [ "$(config_repo_field dashpivot-mobile run_command)" = "react-native run-ios --scheme 'Dashpivot Dev'" ] || fail "dashpivot run_command read (space-bearing scheme)"
  [ "$(config_repo_field sitemate-mobile clone)" = "sitemate-mobile" ] || fail "clone read"
  [ "$(config_int sitemate-mobile metro_port_base 8081)" = "8101" ] || fail "metro_port_base int read"
  [ "$(config_int dashpivot-mobile metro_port_base 8081)" = "8111" ] || fail "dashpivot base read"
  [ "$(config_int sitemate-mobile pool_size 3)" = "3" ] || fail "pool_size int read"
  [ "$(config_int sitemate-mobile no_such_field 42)" = "42" ] || fail "missing int -> default"
  [ -z "$(config_repo_field sitemate-mobile no_such_field)" ] || fail "missing field -> empty"
  pass "config parsing reads run_command, fields, ints, and existence correctly"
}

# --- LRU slot picking (uses state on scratch lab home) ----------------------

test_pick_slot_lru() {
  export FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-lru"
  # shellcheck disable=SC2034
  CACHE_DIR="$FM_MOBILE_LAB_HOME/cache"
  # shellcheck disable=SC2034
  SLOTS_DIR="$FM_MOBILE_LAB_HOME/slots"
  STATE_DIR="$FM_MOBILE_LAB_HOME/state"
  # shellcheck disable=SC2034
  SLOTS_STATE="$STATE_DIR/slots.json"
  ensure_dirs
  [ "$(pick_slot demo 3)" = 0 ] || fail "empty pool picks 0"
  state_set_slot demo-0 demo main 8101 100
  state_set_slot demo-1 demo dev  8102 200
  state_set_slot demo-2 demo qa   8103 300
  [ "$(pick_slot demo 3)" = 0 ] || fail "full pool should evict LRU (slot 0)"
  state_touch_slot demo-0 400
  [ "$(pick_slot demo 3)" = 1 ] || fail "after touching slot 0, LRU is slot 1"
  [ "$(pick_slot demo 3 2)" = 2 ] || fail "explicit slot honored"
  pass "pick_slot uses first-unused then LRU, and honors an explicit slot"
}

# --- no-config and required-field paths (run the real binary) ---------------

test_no_config_guidance_and_nonzero() {
  local out rc cfg="$TMP_ROOT/absent/mobile-lab.json"
  out=$(FM_MOBILE_LAB_LIB=0 FM_MOBILE_LAB_CONFIG="$cfg" FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-nc" \
        "$ENGINE" doctor 2>&1) || true
  assert_contains "$out" "config:      MISSING" "doctor reports missing config"
  out=$(FM_MOBILE_LAB_LIB=0 FM_MOBILE_LAB_CONFIG="$cfg" FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-nc" \
        "$ENGINE" somerepo somebranch --sim 2>&1); rc=$?
  expect_code 1 "$rc" "no-config build must exit non-zero"
  assert_contains "$out" "no mobile-lab config found" "no-config prints the create-config guidance"
  assert_contains "$out" "docs/examples/mobile-lab.json" "guidance points at the example"
  pass "no config: clear guidance and non-zero exit; doctor still runs"
}

test_platform_required() {
  local out rc
  write_config
  out=$(FM_MOBILE_LAB_LIB=0 FM_MOBILE_LAB_CONFIG="$FM_MOBILE_LAB_CONFIG" \
        FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-pf" \
        "$ENGINE" sitemate-mobile main 2>&1); rc=$?
  expect_code 1 "$rc" "missing platform must exit non-zero"
  assert_contains "$out" "platform is required" "explicit platform enforced"
  pass "platform is explicit: neither --sim nor --device errors"
}

test_unknown_repo_errors() {
  local out rc
  write_config
  out=$(FM_MOBILE_LAB_LIB=0 FM_MOBILE_LAB_CONFIG="$FM_MOBILE_LAB_CONFIG" \
        FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-ur" \
        "$ENGINE" not-a-repo main --sim 2>&1); rc=$?
  expect_code 1 "$rc" "unknown repo must exit non-zero"
  assert_contains "$out" "not defined in" "unknown repo reported clearly"
  pass "unknown repo errors with the configured-repos list"
}

test_missing_run_command_errors() {
  # A repo with no run_command must fail with a clear message pointing at config.
  local out rc cfg="$TMP_ROOT/norc/mobile-lab.json"
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<'JSON'
{ "repos": { "norc": { "clone": "norc", "metro_port_base": 8200 } } }
JSON
  # Give it a real clone so we get past the clone check to the run_command check.
  local proj="$TMP_ROOT/norc-projects"
  mkdir -p "$proj/norc"; git -C "$proj/norc" init -q
  out=$(FM_MOBILE_LAB_LIB=0 FM_MOBILE_LAB_CONFIG="$cfg" FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-norc" \
        FM_PROJECTS_OVERRIDE="$proj" "$ENGINE" norc main --sim 2>&1); rc=$?
  expect_code 1 "$rc" "a repo without run_command must exit non-zero"
  assert_contains "$out" "run_command" "the error must name the missing run_command field"
  pass "a build for a repo without run_command errors clearly, pointing at config"
}

# --- wrapped run_command invocation resolves a repo-local CLI ---------------
#
# react-native (and, post-Expo, `npx expo`) lives at <slot>/node_modules/.bin,
# never on the global PATH. run_wrapped_build must resolve it generically (no
# per-CLI special-casing), which is what lets a config-only Expo switch keep
# working. Exercised by stubbing a fake CLI at node_modules/.bin and driving
# run_wrapped_build directly (no real xcodebuild/pods involved).

test_run_wrapped_build_resolves_repo_local_binary() {
  local labhome="$TMP_ROOT/lab-invoke" slot="$TMP_ROOT/invoke-slot"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  mkdir -p "$slot/node_modules/.bin"
  # A fake CLI that only a repo-local PATH lookup can find (NOT installed
  # anywhere else on PATH); it just proves it was invoked and exits 0.
  cat > "$slot/node_modules/.bin/react-native" <<'SH'
#!/usr/bin/env bash
echo "FAKE_REACT_NATIVE_RAN: $*"
SH
  chmod +x "$slot/node_modules/.bin/react-native"
  # shellcheck disable=SC2034
  {
    ST_SLOT="s0" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="device" ST_TARGET="t"
    ST_PHASE_TOTAL=7
  }
  local out rc
  # A PATH deliberately WITHOUT the fake CLI anywhere except via the slot's
  # own node_modules/.bin, so a bare `command not found` would surface here
  # exactly as it did in the real dashpivot-mobile build.
  out=$(PATH="/usr/bin:/bin" run_wrapped_build "s0" "$slot" "react-native run-ios --scheme 'Dashpivot Dev'" --udid ABC123 8111 2>&1); rc=$?
  expect_code 0 "$rc" "wrapped build should succeed once the repo-local binary resolves"
  assert_contains "$out" "FAKE_REACT_NATIVE_RAN" "the repo-local react-native binary must actually run"
  assert_not_contains "$out" "command not found" "must never hit the bare-PATH command-not-found failure"
  pass "run_wrapped_build resolves a repo-local CLI via node_modules/.bin, no bare PATH lookup"
}

test_run_wrapped_build_resolves_any_configured_cli_generically() {
  # Same proof, but for a DIFFERENT CLI name (standing in for `npx expo` after
  # the Expo migration), to confirm nothing here special-cases react-native.
  local labhome="$TMP_ROOT/lab-invoke-expo" slot="$TMP_ROOT/invoke-slot-expo"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  mkdir -p "$slot/node_modules/.bin"
  cat > "$slot/node_modules/.bin/some-other-cli" <<'SH'
#!/usr/bin/env bash
echo "FAKE_OTHER_CLI_RAN: $*"
SH
  chmod +x "$slot/node_modules/.bin/some-other-cli"
  # shellcheck disable=SC2034
  {
    ST_SLOT="s1" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="device" ST_TARGET="t"
    ST_PHASE_TOTAL=7
  }
  local out rc
  out=$(PATH="/usr/bin:/bin" run_wrapped_build "s1" "$slot" "some-other-cli run:ios" --udid XYZ 8112 2>&1); rc=$?
  expect_code 0 "$rc" "any configured run_command's repo-local CLI should resolve"
  assert_contains "$out" "FAKE_OTHER_CLI_RAN" "a non-react-native CLI must resolve the same generic way"
  pass "run_wrapped_build's repo-local resolution is command-agnostic (works for the coming Expo switch too)"
}

# --- pid field + stale-build self-cleanup -----------------------------------

test_status_file_carries_pid() {
  # The console contract now includes a pid field so a reader can tell a live
  # build from a zombie "running" file with kill -0 <pid>.
  local labhome="$TMP_ROOT/lab-pid" fmhome="$TMP_ROOT/fm-home-pid"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  # shellcheck disable=SC2034
  {
    ST_SLOT="s0" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="device" ST_TARGET="t"
    ST_RUN_COMMAND="c" ST_PORT=8100 ST_STATUS="running" ST_ERROR="null"
    ST_STARTED=1 ST_PERCENT="null" ST_LOGFILE="l" ST_PHASE_TOTAL=7
    ST_PHASE="compile" ST_PHASE_INDEX=5 ST_PID=4242
  }
  status_write
  local f; f="$FM_STATE_DIR/lab-build-s0.json"
  [ "$(jq -r '.pid' "$f")" = "4242" ] || fail "status file must carry the owning build pid"
  [ "$(jq -r '.pid | type' "$f")" = "number" ] || fail "pid must be a JSON number"
  pass "status_write records the owning build pid in the contract file"
}

test_status_file_emits_metro_running() {
  # The console contract includes a metro_running boolean, refreshed from a real
  # liveness probe of the slot's port on every write. A fake curl stands in for
  # Metro answering on the port so the probe is deterministic in CI.
  local labhome="$TMP_ROOT/lab-metro" fmhome="$TMP_ROOT/fm-home-metro" fakebin
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  fakebin=$(fm_fakebin "$labhome")
  # Fake curl: answers packager-status:running ONLY for port 8299, so the same
  # metro_running() logic is exercised for both the up and down cases by port.
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *localhost:8299/status*) echo "packager-status:running"; exit 0 ;; esac; done
exit 7
SH
  chmod +x "$fakebin/curl"
  # shellcheck disable=SC2034
  {
    ST_SLOT="m0" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="sim" ST_TARGET="t"
    ST_RUN_COMMAND="c" ST_STATUS="running" ST_ERROR="null"
    ST_STARTED=1 ST_PERCENT="null" ST_LOGFILE="l" ST_PHASE_TOTAL=7
    ST_PHASE="compile" ST_PHASE_INDEX=5 ST_PID=1
  }
  local f="$FM_STATE_DIR/lab-build-m0.json"
  # Metro UP: port 8299 answers -> metro_running true (a real JSON boolean).
  # ST_PORT is read by the sourced status_write (curl-probed), which shellcheck
  # cannot see, hence the SC2034 suppression on these assignments.
  # shellcheck disable=SC2034
  ST_PORT=8299
  PATH="$fakebin:$PATH" status_write
  [ "$(jq -r '.metro_running' "$f")" = "true" ] || fail "metro_running must be true when Metro answers on the port"
  [ "$(jq -r '.metro_running | type' "$f")" = "boolean" ] || fail "metro_running must be a JSON boolean, not a string"
  # Metro DOWN: a different port does not answer -> metro_running false.
  # shellcheck disable=SC2034
  ST_PORT=8300
  PATH="$fakebin:$PATH" status_write
  [ "$(jq -r '.metro_running' "$f")" = "false" ] || fail "metro_running must be false when nothing answers on the port"
  pass "status_write emits a real metro_running boolean refreshed from a live port probe"
}

test_stale_running_with_dead_pid_is_reaped() {
  # A non-terminal "running" file whose recorded pid is no longer alive is a
  # zombie: status_stale_if_running must rewrite it failed so a new build never
  # silently replaces a still-"running" file.
  local fmhome="$TMP_ROOT/fm-home-stale"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  local f="$FM_STATE_DIR/lab-build-z0.json"
  local dead=999999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead-1)); done
  jq -n --argjson p "$dead" \
    '{schema:1,slot:"z0",status:"running",pid:$p,error:null,message:"old"}' > "$f"
  status_stale_if_running "$f"
  [ "$(jq -r '.status' "$f")" = "failed" ] || fail "a running file with a dead pid must be marked failed"
  [ "$(jq -r '.error' "$f")" != "null" ] || fail "a reaped stale build must carry an error string"
  pass "status_stale_if_running reaps a zombie running file whose pid is dead"
}

test_stale_running_with_live_pid_is_left() {
  # A running file whose pid is still alive is a genuinely live build: leave it.
  local fmhome="$TMP_ROOT/fm-home-live"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  local f="$FM_STATE_DIR/lab-build-z1.json"
  jq -n --argjson p "$$" \
    '{schema:1,slot:"z1",status:"running",pid:$p,error:null,message:"live"}' > "$f"
  status_stale_if_running "$f"
  [ "$(jq -r '.status' "$f")" = "running" ] || fail "a running file with a LIVE pid must be left untouched"
  pass "status_stale_if_running leaves a running file whose pid is alive"
}

test_stale_terminal_file_is_left() {
  # A terminal file (success/failed) is never touched, even if its pid is dead.
  local fmhome="$TMP_ROOT/fm-home-term"
  FM_STATE_DIR="$fmhome/state"; mkdir -p "$FM_STATE_DIR"
  local f="$FM_STATE_DIR/lab-build-z2.json"
  jq -n '{schema:1,slot:"z2",status:"success",pid:0,error:null,message:"done"}' > "$f"
  status_stale_if_running "$f"
  [ "$(jq -r '.status' "$f")" = "success" ] || fail "a terminal (success) file must be left untouched"
  pass "status_stale_if_running never rewrites a terminal status file"
}

# --- pods gap (pod install when Pods/ or its xcconfig is missing) ------------

test_pods_present_detection() {
  local slot="$TMP_ROOT/pods-detect"
  mkdir -p "$slot/ios"
  # No Pods dir at all -> missing.
  if pods_present "$slot"; then fail "no ios/Pods -> pods must be reported missing"; fi
  # A Target Support Files dir with no Pods-*.xcconfig -> the broken state.
  mkdir -p "$slot/ios/Pods/Target Support Files/Pods-App"
  if pods_present "$slot"; then fail "Pods/ with Target Support Files but no xcconfig -> missing"; fi
  # Once the app xcconfig exists -> present.
  : > "$slot/ios/Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"
  pods_present "$slot" || fail "Pods/ with a Pods-*.xcconfig -> present"
  pass "pods_present detects a missing/broken pods install by the xcconfig the build needs"
}

test_ensure_pods_runs_pod_install_when_missing() {
  # With pods missing, ensure_pods must actually run pod install (the gap the
  # real build hit: deps-cache made the RN CLI skip pods, so Pods/ was absent).
  local slot="$TMP_ROOT/pods-install" fakebin
  mkdir -p "$slot/ios"
  fakebin=$(fm_fakebin "$slot")
  # A fake pod that records it ran and creates the xcconfig, exactly as a real
  # `pod install` would produce the Xcode-referenced base configuration file.
  cat > "$fakebin/pod" <<'SH'
#!/usr/bin/env bash
echo "FAKE_POD_INSTALL ran in $PWD"
mkdir -p "$PWD/Pods/Target Support Files/Pods-App"
: > "$PWD/Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"
SH
  chmod +x "$fakebin/pod"
  # shellcheck disable=SC2034
  { ST_SLOT="p0"; ST_STATUS="running"; STATE_DIR="$slot/st"; FM_STATE_DIR="$slot/st"; }
  mkdir -p "$STATE_DIR"
  local out rc
  out=$(PATH="$fakebin:$PATH" ensure_pods "$slot" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure_pods should succeed once pod install produces the xcconfig"
  assert_contains "$out" "FAKE_POD_INSTALL" "ensure_pods must actually run pod install when pods are missing"
  pods_present "$slot" || fail "after ensure_pods the slot must have a usable pods install"
  pass "ensure_pods runs pod install when Pods/ or its xcconfig is missing, closing the deps-cache pods gap"
}

test_ensure_pods_noop_when_present() {
  # When pods are already installed, ensure_pods must NOT run pod install again.
  local slot="$TMP_ROOT/pods-noop" fakebin
  mkdir -p "$slot/ios/Pods/Target Support Files/Pods-App"
  : > "$slot/ios/Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"
  fakebin=$(fm_fakebin "$slot")
  cat > "$fakebin/pod" <<'SH'
#!/usr/bin/env bash
echo "FAKE_POD_INSTALL should not run"; exit 1
SH
  chmod +x "$fakebin/pod"
  # shellcheck disable=SC2034
  { ST_SLOT="p1"; ST_STATUS="running"; STATE_DIR="$slot/st"; FM_STATE_DIR="$slot/st"; }
  mkdir -p "$STATE_DIR"
  local out rc
  out=$(PATH="$fakebin:$PATH" ensure_pods "$slot" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure_pods must succeed (no-op) when pods are already present"
  assert_not_contains "$out" "FAKE_POD_INSTALL" "ensure_pods must NOT re-run pod install when pods are present"
  pass "ensure_pods is a no-op when a usable pods install already exists"
}

test_ensure_pods_prefers_bundler_when_gemfile_present() {
  # A repo pinning CocoaPods via bundler must be installed with bundle exec.
  local slot="$TMP_ROOT/pods-bundler" fakebin
  mkdir -p "$slot/ios"; : > "$slot/Gemfile"
  fakebin=$(fm_fakebin "$slot")
  # A fake bundle that records its args; a plain `pod` that must NOT be used.
  cat > "$fakebin/bundle" <<'SH'
#!/usr/bin/env bash
echo "FAKE_BUNDLE $*"
mkdir -p "$PWD/Pods/Target Support Files/Pods-App"
: > "$PWD/Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"
SH
  chmod +x "$fakebin/bundle"
  cat > "$fakebin/pod" <<'SH'
#!/usr/bin/env bash
echo "FAKE_BARE_POD should not run"; exit 1
SH
  chmod +x "$fakebin/pod"
  # shellcheck disable=SC2034
  { ST_SLOT="p2"; ST_STATUS="running"; STATE_DIR="$slot/st"; FM_STATE_DIR="$slot/st"; }
  mkdir -p "$STATE_DIR"
  local out
  out=$(PATH="$fakebin:$PATH" ensure_pods "$slot" 2>&1)
  assert_contains "$out" "FAKE_BUNDLE exec pod install" "a Gemfile must drive pods via bundle exec pod install"
  assert_not_contains "$out" "FAKE_BARE_POD" "bare pod must not run when a Gemfile is present"
  pass "ensure_pods uses bundle exec pod install when a Gemfile pins CocoaPods"
}

# --- detached build handoff + terminal-status trap --------------------------
#
# The core robustness fix: the native build runs DETACHED so it outlives its
# caller, and it writes a terminal status on its own exit (even when killed) so
# no zombie "running" file is left behind. These are driven end to end with a
# stubbed CLI (no real xcodebuild) via the real binary, since the detach and the
# exit-trap behavior only exist across process boundaries.

# fm_lab_scratch_fleet <dir> <rn-script-file>: build a hermetic fleet (config, a
# git clone with the stubbed react-native at <rn-script-file>, fake pod/npm/xcrun)
# and export the env the real engine needs. Sets FMHOME_SF for the caller.
fm_lab_scratch_fleet() {
  local dir=$1 rn_file=$2
  local clone="$dir/projects/demo"
  mkdir -p "$clone/ios" "$clone/node_modules/.bin"
  git -C "$clone" init -q >/dev/null 2>&1
  echo '{"lockfileVersion":3}' > "$clone/package-lock.json"
  cp "$rn_file" "$clone/node_modules/.bin/react-native"
  chmod +x "$clone/node_modules/.bin/react-native"
  git -C "$clone" add -A >/dev/null 2>&1
  git -C "$clone" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  local cfg="$dir/config/mobile-lab.json"; mkdir -p "$(dirname "$cfg")"
  echo '{ "repos": { "demo": { "clone":"demo","metro_port_base":8300,"pool_size":4,"run_command":"react-native run-ios" } } }' > "$cfg"
  local fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/pod" <<'SH'
#!/usr/bin/env bash
mkdir -p "$PWD/Pods/Target Support Files/Pods-App"
: > "$PWD/Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/xcrun" <<'SH'
#!/usr/bin/env bash
[ "$1" = xctrace ] && printf '== Devices ==\nFake iPhone (18.0) (00008110000231D414D8401E)\n'
SH
  chmod +x "$fakebin/pod" "$fakebin/npm" "$fakebin/xcrun"
  FMHOME_SF="$dir/fmhome"; mkdir -p "$FMHOME_SF/state"
  export FM_MOBILE_LAB_CONFIG="$cfg" FM_MOBILE_LAB_HOME="$dir/lab"
  export FM_PROJECTS_OVERRIDE="$dir/projects" FM_STATE_OVERRIDE="$FMHOME_SF/state"
  export FM_MOBILE_LAB_NO_METRO=1 FM_MOBILE_LAB_MIN_FREE_GB=0
  export FM_LAB_SCRATCH_PATH="$fakebin:$PATH"
}

# fm_write_rn <path> <mode> [arg]: write a stubbed react-native script to <path>.
# mode=slow  emits <arg> "Compiling X/N" lines one per second (a long build to
#            catch mid-run); mode=quick emits a short 3-line compile then install;
#            mode=fail exits non-zero after a "boom" line (a failing build).
fm_write_rn() {
  local path=$1 mode=$2 arg=${3:-20}
  case "$mode" in
    slow)
      cat > "$path" <<SH
#!/usr/bin/env bash
echo "Analyzing dependencies"
for i in \$(seq 1 $arg); do echo "Compiling React-Core (\$i/$arg)"; sleep 1; done
echo "Installing App on device"
SH
      ;;
    quick)
      cat > "$path" <<'SH'
#!/usr/bin/env bash
echo "Analyzing dependencies"
for i in 1 2 3; do echo "Compiling React-Core ($i/3)"; sleep 1; done
echo "Installing App on device"
SH
      ;;
    fail)
      cat > "$path" <<'SH'
#!/usr/bin/env bash
echo "Analyzing dependencies"
echo "boom: build error"
exit 7
SH
      ;;
  esac
  chmod +x "$path"
}

# fm_lab_wait_status <status-file> <target...>: poll until the status file's
# status is one of the target words, or a timeout. Echoes the final status.
fm_lab_wait_status() {
  local f=$1; shift
  local i st
  for ((i=0; i<40; i++)); do
    st=$(jq -r '.status // ""' "$f" 2>/dev/null)
    for t in "$@"; do [ "$st" = "$t" ] && { printf '%s' "$st"; return 0; }; done
    sleep 1
  done
  printf '%s' "${st:-timeout}"
}

test_default_build_detaches_and_returns_fast() {
  # The default invocation must LAUNCH the build detached and RETURN quickly
  # (before the ~build duration), leaving the build running under its own pid.
  local d="$TMP_ROOT/detach-fast"; mkdir -p "$d"
  local FMHOME_SF rn="$d/rn.sh"
  fm_write_rn "$rn" slow 20
  fm_lab_scratch_fleet "$d" "$rn"
  local sf="$FMHOME_SF/state/lab-build-demo-0.json"
  local t0 t1 out rc
  t0=$(date +%s)
  out=$(FM_MOBILE_LAB_LIB=0 PATH="$FM_LAB_SCRATCH_PATH" "$ENGINE" demo main --device --slot 0 2>&1); rc=$?
  t1=$(date +%s)
  expect_code 0 "$rc" "the default detached launch must return 0 immediately"
  [ $((t1 - t0)) -lt 15 ] || fail "default launch must return well before the ~20s build finishes (took $((t1-t0))s)"
  assert_contains "$out" "build started" "the default launch must announce the detached build"
  # The build must still be running detached, under a live pid, after we returned.
  sleep 2
  [ -f "$sf" ] || fail "a status file must exist for the detached build"
  local pid; pid=$(jq -r '.pid' "$sf")
  [ "$pid" -gt 0 ] 2>/dev/null || fail "the status file must record the detached build pid"
  kill -0 "$pid" 2>/dev/null || fail "the detached build must still be running after the caller returned"
  # Let it finish, then confirm a clean terminal success and that pods ran.
  local final; final=$(fm_lab_wait_status "$sf" success failed)
  [ "$final" = "success" ] || fail "the detached build should reach success (got: $final)"
  # Clean up any strays (the build already finished; belt-and-braces).
  kill -TERM "$pid" 2>/dev/null || true
  pass "the default invocation launches the build detached and returns fast, and the build runs to a terminal status on its own"
}

test_killed_detached_build_writes_terminal_failed() {
  # The whole point: a killed build must NOT leave a zombie "running" file. Its
  # own exit trap must write a terminal 'failed' with a specific error.
  local d="$TMP_ROOT/detach-kill"; mkdir -p "$d"
  local FMHOME_SF rn="$d/rn.sh"
  fm_write_rn "$rn" slow 60
  fm_lab_scratch_fleet "$d" "$rn"
  local sf="$FMHOME_SF/state/lab-build-demo-0.json"
  FM_MOBILE_LAB_LIB=0 PATH="$FM_LAB_SCRATCH_PATH" "$ENGINE" demo main --device --slot 0 >/dev/null 2>&1
  # Wait until the build is genuinely mid-run under its own pid.
  sleep 4
  local pid; pid=$(jq -r '.pid' "$sf")
  kill -0 "$pid" 2>/dev/null || fail "precondition: the detached build should be running"
  # Kill it and confirm it self-marks failed (its exit trap), not stuck running.
  kill -TERM "$pid" 2>/dev/null
  local final; final=$(fm_lab_wait_status "$sf" failed success)
  [ "$final" = "failed" ] || fail "a killed build must write a terminal 'failed' status, not stay 'running' (got: $final)"
  local err; err=$(jq -r '.error' "$sf")
  [ "$err" != "null" ] && [ -n "$err" ] || fail "a killed build's terminal status must carry a specific error"
  # Ensure no build subtree leaked.
  pkill -f 'react-native run-ios' 2>/dev/null || true
  pass "a killed detached build writes a terminal 'failed' status via its own exit trap (no zombie 'running' file)"
}

test_wait_flag_blocks_until_build_finishes() {
  # --wait must preserve the old blocking behavior: block until done and return
  # the build's exit status (0 on success).
  local d="$TMP_ROOT/detach-wait"; mkdir -p "$d"
  local FMHOME_SF rn="$d/rn.sh"
  fm_write_rn "$rn" quick
  fm_lab_scratch_fleet "$d" "$rn"
  local sf="$FMHOME_SF/state/lab-build-demo-0.json"
  local t0 t1 rc
  t0=$(date +%s)
  FM_MOBILE_LAB_LIB=0 PATH="$FM_LAB_SCRATCH_PATH" "$ENGINE" demo main --device --slot 0 --wait >/dev/null 2>&1; rc=$?
  t1=$(date +%s)
  expect_code 0 "$rc" "--wait on a passing build must return 0"
  [ $((t1 - t0)) -ge 3 ] || fail "--wait must block until the ~3s build finishes (returned after $((t1-t0))s)"
  [ "$(jq -r '.status' "$sf")" = "success" ] || fail "--wait must leave a terminal success status"
  pass "--wait blocks until the build finishes and returns its (success) exit code"
}

test_wait_flag_propagates_build_failure() {
  # --wait must return non-zero when the build fails, and the status is failed.
  local d="$TMP_ROOT/detach-wait-fail"; mkdir -p "$d"
  local FMHOME_SF rn="$d/rn.sh"
  fm_write_rn "$rn" fail
  fm_lab_scratch_fleet "$d" "$rn"
  local sf="$FMHOME_SF/state/lab-build-demo-0.json"
  local rc
  FM_MOBILE_LAB_LIB=0 PATH="$FM_LAB_SCRATCH_PATH" "$ENGINE" demo main --device --slot 0 --wait >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "--wait must return non-zero when the wrapped build fails"
  [ "$(jq -r '.status' "$sf")" = "failed" ] || fail "a failing build must leave a terminal failed status"
  pass "--wait propagates a build failure as a non-zero exit and a terminal failed status"
}

test_new_build_reaps_stale_slot_file() {
  # A new build into a slot whose prior file is a dead-pid zombie must reap it
  # (mark failed) rather than silently overwrite a still-"running" file. Proven
  # by seeding a zombie, then confirming the new build takes over with a fresh
  # live pid distinct from the dead one.
  local d="$TMP_ROOT/detach-reap"; mkdir -p "$d"
  local FMHOME_SF rn="$d/rn.sh"
  fm_write_rn "$rn" quick
  fm_lab_scratch_fleet "$d" "$rn"
  local sf="$FMHOME_SF/state/lab-build-demo-0.json"
  local dead=999999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead-1)); done
  jq -n --argjson p "$dead" \
    '{schema:1,slot:"demo-0",repo:"demo",branch:"main",platform:"device",target:"x",run_command:"c",port:8300,phase:"compile",phase_index:5,phase_total:7,percent:null,status:"running",started_epoch:1,updated_epoch:1,phase_started_epoch:1,message:"zombie",logfile:"l",error:null,pid:$p}' > "$sf"
  FM_MOBILE_LAB_LIB=0 PATH="$FM_LAB_SCRATCH_PATH" "$ENGINE" demo main --device --slot 0 >/dev/null 2>&1
  sleep 1
  local newpid; newpid=$(jq -r '.pid' "$sf")
  [ "$newpid" != "$dead" ] || fail "the new build must replace the zombie's dead pid with its own live pid"
  local final; final=$(fm_lab_wait_status "$sf" success failed)
  [ "$final" = "success" ] || fail "the fresh build should run to success (got: $final)"
  kill -TERM "$newpid" 2>/dev/null || true
  pkill -f 'react-native run-ios' 2>/dev/null || true
  pass "a new build reaps a stale dead-pid zombie file and takes the slot over with a fresh build"
}

# --- run all ----------------------------------------------------------------

test_detect_pkgmgr
test_pnpm_wins_over_npm
test_detect_node_version
test_node_version_matches
test_switch_node_keeps_ambient_node_when_it_already_satisfies
test_switch_node_restores_ambient_when_fnm_cannot_provide
test_switch_node_evals_fnm_env_before_use
test_switch_node_warns_loudly_on_failed_switch
test_switch_node_noop_without_fnm
test_switch_node_noop_without_version
test_lockfile_hash_determinism
test_metro_port
test_slot_name
test_build_run_command_assembly
test_build_run_command_expo_form
test_build_run_command_quotes_single_quotes
test_build_run_command_no_target_flag
test_slice_gate_blocks_ffmpeg_on_sim
test_slice_gate_allows_ffmpeg_on_device
test_slice_gate_allows_universal_sim
test_slice_gate_no_frameworks_passes
test_slice_gate_allows_when_lipo_absent
test_target_platform_token
test_resolve_sim_arch_native_arm64
test_resolve_sim_arch_x86_rosetta
test_resolve_sim_arch_x86_no_rosetta_fails
test_resolve_sim_arch_no_sim_slice_fails
test_sim_arch_extra_args
test_build_run_command_appends_extra_args
test_sim_runtime_runs_x86
test_rosetta_available_override
test_status_file_is_contract_shaped
test_status_file_path_uses_fm_state_dir_not_lab_home
test_fm_state_dir_respects_fm_state_override
test_status_fail_sets_error_string
test_status_message_refines_compile_percent
test_no_fake_percent_without_count
test_infer_phase_from_line
test_build_lock_second_refuses
test_build_lock_clears_stale
test_build_lock_release_only_own
test_example_config_is_valid_json
test_example_config_has_run_command
test_config_parsing
test_pick_slot_lru
test_no_config_guidance_and_nonzero
test_platform_required
test_unknown_repo_errors
test_missing_run_command_errors
test_run_wrapped_build_resolves_repo_local_binary
test_run_wrapped_build_resolves_any_configured_cli_generically
test_status_file_carries_pid
test_status_file_emits_metro_running
test_stale_running_with_dead_pid_is_reaped
test_stale_running_with_live_pid_is_left
test_stale_terminal_file_is_left
test_pods_present_detection
test_ensure_pods_runs_pod_install_when_missing
test_ensure_pods_noop_when_present
test_ensure_pods_prefers_bundler_when_gemfile_present
test_default_build_detaches_and_returns_fast
test_killed_detached_build_writes_terminal_failed
test_wait_flag_blocks_until_build_finishes
test_wait_flag_propagates_build_failure
test_new_build_reaps_stale_slot_file

pass "all fm-mobile-lab tests passed"
