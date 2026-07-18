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

# --- build-status file emission (the console contract) ----------------------

test_status_file_is_contract_shaped() {
  local labhome="$TMP_ROOT/lab-status"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  # Set the status globals as run_build would, then emit a phase. These are
  # consumed by the sourced engine's status_write, not visibly in this file.
  # shellcheck disable=SC2034
  {
    ST_SLOT="dashpivot-mobile-0" ST_REPO="dashpivot-mobile" ST_BRANCH="release/26.9"
    ST_PLATFORM="device" ST_TARGET="Thev's iPhone (iOS 26.5)"
    ST_RUN_COMMAND="react-native run-ios --scheme 'Dashpivot Dev'"
    ST_PORT=8111 ST_STATUS="running" ST_ERROR="null" ST_STARTED=1784300000
    ST_PERCENT="null" ST_LOGFILE="state/build-dashpivot-mobile-0.log" ST_PHASE_TOTAL=7
  }
  status_phase compile 5 "Compiling React-Core"

  local f; f="$STATE_DIR/lab-build-dashpivot-mobile-0.json"
  [ -f "$f" ] || fail "status file was not written to $f"
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
  [ "$(jq -r '.logfile' "$f")" = "state/build-dashpivot-mobile-0.log" ] || fail "logfile"
  [ "$(jq -r '.started_epoch' "$f")" = "1784300000" ] || fail "started_epoch"
  [ "$(jq -r '.updated_epoch | type' "$f")" = "number" ] || fail "updated_epoch is a number"
  [ "$(jq -r '.phase_started_epoch | type' "$f")" = "number" ] || fail "phase_started_epoch is a number"
  pass "status_write emits a contract-shaped JSON with correct types and a real null percent"
}

test_status_fail_sets_error_string() {
  local labhome="$TMP_ROOT/lab-status-fail"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
  # shellcheck disable=SC2034
  {
    ST_SLOT="s0" ST_REPO="r" ST_BRANCH="b" ST_PLATFORM="sim" ST_TARGET="t"
    ST_RUN_COMMAND="c" ST_PORT=8100 ST_STATUS="running" ST_ERROR="null"
    ST_STARTED=1 ST_PERCENT="null" ST_LOGFILE="state/build-s0.log" ST_PHASE_TOTAL=7
    ST_PHASE="preflight" ST_PHASE_INDEX=1
  }
  status_fail "libavcodec has no arm64-simulator slice; use --device"
  local f; f="$STATE_DIR/lab-build-s0.json"
  [ "$(jq -r '.status' "$f")" = "failed" ] || fail "status must be failed"
  [ "$(jq -r '.error' "$f")" = "libavcodec has no arm64-simulator slice; use --device" ] || fail "error string must be the specific reason"
  pass "status_fail records failed status with a specific error string"
}

test_status_message_refines_compile_percent() {
  local labhome="$TMP_ROOT/lab-status-pct"
  STATE_DIR="$labhome/state"; mkdir -p "$STATE_DIR"
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
  local f; f="$STATE_DIR/lab-build-s0.json"
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

# --- run all ----------------------------------------------------------------

test_detect_pkgmgr
test_pnpm_wins_over_npm
test_detect_node_version
test_node_version_matches
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
test_status_file_is_contract_shaped
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

pass "all fm-mobile-lab tests passed"
