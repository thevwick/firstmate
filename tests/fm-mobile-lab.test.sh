#!/usr/bin/env bash
# Behavior tests for fm-mobile-lab's pure logic: toolchain detection, lockfile
# and native-fingerprint hashing determinism, per-slot port assignment, LRU slot
# picking, config parsing, and the "no config -> clear message, non-zero" path.
# Everything here is unit-testable without a simulator or device; the native
# build and device launch are gated behind doctor checks and verified on real
# hardware (see docs/mobile-lab.md).
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
  # A checkout with both lockfiles: pnpm takes precedence (matches the doc order).
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

test_native_fingerprint_determinism_and_js_invariance() {
  local base="$TMP_ROOT/fp"
  local d1="$base/d1" d2="$base/d2" djs="$base/djs" dnat="$base/dnat"
  for d in "$d1" "$d2" "$djs" "$dnat"; do
    mkdir -p "$d/ios"
    printf 'PODFILE-CONTENT\n' > "$d/ios/Podfile"
    printf 'PODFILE-LOCK-CONTENT\n' > "$d/ios/Podfile.lock"
    cat > "$d/package.json" <<'JSON'
{
  "dependencies": {
    "react-native": "0.81.0",
    "react-native-reanimated": "3.6.0",
    "lodash": "4.17.21"
  }
}
JSON
  done
  # djs: change a PURE-JS dependency version only (lodash). Must NOT change fp.
  cat > "$djs/package.json" <<'JSON'
{
  "dependencies": {
    "react-native": "0.81.0",
    "react-native-reanimated": "3.6.0",
    "lodash": "9.9.9"
  }
}
JSON
  # dnat: bump a NATIVE dependency (react-native-reanimated). MUST change fp.
  cat > "$dnat/package.json" <<'JSON'
{
  "dependencies": {
    "react-native": "0.81.0",
    "react-native-reanimated": "4.0.0",
    "lodash": "4.17.21"
  }
}
JSON
  local f1 f2 fjs fnat
  f1=$(native_fingerprint "$d1" sim)
  f2=$(native_fingerprint "$d2" sim)
  fjs=$(native_fingerprint "$djs" sim)
  fnat=$(native_fingerprint "$dnat" sim)
  [ -n "$f1" ] || fail "fingerprint should be non-empty"
  [ "$f1" = "$f2" ] || fail "identical native inputs must fingerprint the same ($f1 vs $f2)"
  [ "$f1" = "$fjs" ] || fail "a pure-JS dep change must NOT bust the native fingerprint ($f1 vs $fjs)"
  [ "$f1" != "$fnat" ] || fail "a native dep bump MUST change the fingerprint"
  pass "native_fingerprint is deterministic, JS-invariant, native-sensitive"
}

test_native_fingerprint_platform_and_podfile_sensitive() {
  local d="$TMP_ROOT/fp2"; mkdir -p "$d/ios"
  printf 'PF\n' > "$d/ios/Podfile"; printf 'PFL\n' > "$d/ios/Podfile.lock"
  printf '{"dependencies":{"react-native":"0.81.0"}}\n' > "$d/package.json"
  local sim dev
  sim=$(native_fingerprint "$d" sim); dev=$(native_fingerprint "$d" device)
  [ "$sim" != "$dev" ] || fail "platform must be part of the fingerprint"
  local before after
  before=$(native_fingerprint "$d" sim)
  printf 'PODFILE-LOCK-CHANGED\n' > "$d/ios/Podfile.lock"
  after=$(native_fingerprint "$d" sim)
  [ "$before" != "$after" ] || fail "a Podfile.lock change must change the fingerprint"
  pass "native_fingerprint is platform- and Podfile.lock-sensitive"
}

test_patches_change_fingerprint() {
  local d="$TMP_ROOT/fp3"; mkdir -p "$d/ios" "$d/patches"
  printf 'PF\n' > "$d/ios/Podfile"; printf 'PFL\n' > "$d/ios/Podfile.lock"
  printf '{"dependencies":{"react-native":"0.81.0"}}\n' > "$d/package.json"
  local before after
  before=$(native_fingerprint "$d" sim)
  printf 'a native patch\n' > "$d/patches/react-native+0.81.0.patch"
  after=$(native_fingerprint "$d" sim)
  [ "$before" != "$after" ] || fail "adding a patch must change the fingerprint"
  pass "native_fingerprint includes patches/ contents"
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

# --- config parsing ---------------------------------------------------------

write_config() {
  mkdir -p "$(dirname "$FM_MOBILE_LAB_CONFIG")"
  cp "$ROOT/docs/examples/mobile-lab.json" "$FM_MOBILE_LAB_CONFIG"
}

test_example_config_is_valid_json() {
  jq -e . "$ROOT/docs/examples/mobile-lab.json" >/dev/null \
    || fail "docs/examples/mobile-lab.json must be valid JSON"
  pass "example config is jq-parseable"
}

test_config_parsing() {
  write_config
  config_present || fail "config_present should be true after write"
  config_repo_exists sitemate-mobile || fail "sitemate-mobile should exist in config"
  config_repo_exists nonesuch && fail "nonesuch should not exist in config"
  [ "$(config_repo_field sitemate-mobile ios_scheme)" = "Sitemate" ] || fail "ios_scheme read"
  [ "$(config_repo_field sitemate-mobile clone)" = "sitemate-mobile" ] || fail "clone read"
  [ "$(config_int sitemate-mobile metro_port_base 8081)" = "8101" ] || fail "metro_port_base int read"
  [ "$(config_int dashpivot-mobile metro_port_base 8081)" = "8111" ] || fail "dashpivot base read"
  [ "$(config_int sitemate-mobile pool_size 3)" = "3" ] || fail "pool_size int read"
  # A missing field falls back to the default.
  [ "$(config_int sitemate-mobile no_such_field 42)" = "42" ] || fail "missing int -> default"
  [ -z "$(config_repo_field sitemate-mobile no_such_field)" ] || fail "missing field -> empty"
  pass "config parsing reads fields, ints, and existence correctly"
}

# --- LRU slot picking (uses state on scratch lab home) ----------------------

test_pick_slot_lru() {
  # Fresh lab home for this test's state. These globals are consumed by the
  # sourced engine's state functions (ensure_dirs, state_*), so reassign them.
  export FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-lru"
  # These globals are consumed by the sourced engine's state functions
  # (ensure_dirs, state_*), so reassign them for this test's fresh lab home.
  # shellcheck disable=SC2034
  CACHE_DIR="$FM_MOBILE_LAB_HOME/cache"
  # shellcheck disable=SC2034
  SLOTS_DIR="$FM_MOBILE_LAB_HOME/slots"
  STATE_DIR="$FM_MOBILE_LAB_HOME/state"
  # shellcheck disable=SC2034
  SLOTS_STATE="$STATE_DIR/slots.json"
  ensure_dirs
  # First pick with an empty pool -> first unused index 0.
  [ "$(pick_slot demo 3)" = 0 ] || fail "empty pool picks 0"
  # Occupy slots 0,1,2 with increasing last_used (0 oldest).
  state_set_slot demo-0 demo main 8101 fpA 100
  state_set_slot demo-1 demo dev  8102 fpB 200
  state_set_slot demo-2 demo qa   8103 fpC 300
  # Full pool -> evict the least-recently-used, which is slot 0 (last_used 100).
  [ "$(pick_slot demo 3)" = 0 ] || fail "full pool should evict LRU (slot 0)"
  # Bump slot 0 to newest; now slot 1 is LRU.
  state_touch_slot demo-0 400
  [ "$(pick_slot demo 3)" = 1 ] || fail "after touching slot 0, LRU is slot 1"
  # An explicit in-range slot is honored.
  [ "$(pick_slot demo 3 2)" = 2 ] || fail "explicit slot honored"
  pass "pick_slot uses first-unused then LRU, and honors an explicit slot"
}

# --- no-config path (run the real binary, not the sourced lib) --------------

test_no_config_guidance_and_nonzero() {
  local out rc cfg="$TMP_ROOT/absent/mobile-lab.json"
  out=$(FM_MOBILE_LAB_LIB=0 FM_MOBILE_LAB_CONFIG="$cfg" FM_MOBILE_LAB_HOME="$TMP_ROOT/lab-nc" \
        "$ENGINE" doctor 2>&1) || true
  # doctor is allowed to run with no config and reports it.
  assert_contains "$out" "config:      MISSING" "doctor reports missing config"
  # A build command with no config prints the create-config guidance and exits non-zero.
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

# --- run all ----------------------------------------------------------------

test_detect_pkgmgr
test_pnpm_wins_over_npm
test_detect_node_version
test_lockfile_hash_determinism
test_native_fingerprint_determinism_and_js_invariance
test_native_fingerprint_platform_and_podfile_sensitive
test_patches_change_fingerprint
test_metro_port
test_slot_name
test_example_config_is_valid_json
test_config_parsing
test_pick_slot_lru
test_no_config_guidance_and_nonzero
test_platform_required
test_unknown_repo_errors

pass "all fm-mobile-lab tests passed"
