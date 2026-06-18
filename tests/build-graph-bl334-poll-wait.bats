#!/usr/bin/env bats
# BL-334 (TD-OTP-A): Test Specification — otp-graph-builder freshness-check race
#                     poll-and-wait before verify
#
# ROOT CAUSE (Blake T1, 2026-06-18):
#   trigger_railway_redeploy() and verify_otp_router_graph_freshness() ran in the
#   SAME SECOND (04:31:35 UTC).  verify... queried otp-router BEFORE it finished
#   reloading the new ~2.2 GB graph → saw OLD graph end=2026-06-15 → reported
#   STALE → non-zero exit under set -euo pipefail → Railway showed CRASHED.
#   The build ITSELF SUCCEEDED: graph.obj built at 04:28:58, uploaded to GCS at
#   04:31:33. Recurs every Mon/Thu (the scheduled rebuild cadence) → alert-fatigue
#   risk masking genuine failures.
#
# FIX (Blake TD-2 will implement):
#   Insert a bounded, configurable poll-and-wait loop between
#   trigger_railway_redeploy() and verify_otp_router_graph_freshness().
#   Poll otp-router serviceTimeRange (~30s interval) until it advances past the
#   pre-redeploy serviceTimeRange.end (proves the new graph loaded) OR a
#   configurable timeout (OTP_RELOAD_POLL_TIMEOUT, default ~15 min / 30 retries)
#   elapses. Only THEN run the existing freshness verify.
#   Reuses the builder's existing "Still waiting for OTP... (Xs elapsed)" poll
#   pattern.
#
# Env var names (Quinn TD-0 decision, 2026-06-18):
#   OTP_RELOAD_POLL_TIMEOUT  — total poll timeout in seconds (default: 900 = 15 min)
#   OTP_RELOAD_POLL_INTERVAL — per-poll sleep interval in seconds (default: 30)
#
# Test framework:
#   bats-core >= 1.10.0; same BATS_SOURCE_ONLY=true harness as BL-127/BL-333.
#   Run: bats tests/build-graph-bl334-poll-wait.bats
#
# Existing tests (DO NOT MODIFY — Test Lock Rule):
#   build-graph-railway-redeploy.bats — BL-127 / TD-OTP-007 contract
#   build-graph-bl333-defects.bats    — BL-333 Boolean! mutation + validate-graph
#
# Epoch values used in these tests:
#   All at 12:00:00 UTC (noon) to be timezone-unambiguous on any host.
#   PRE_RELOAD end:  1781438400 = 2026-06-14 12:00 UTC  (the OLD graph, before redeploy)
#   POST_RELOAD end: 1798761600 = 2027-01-01 12:00 UTC  (the NEW graph, after redeploy)
#   TODAY_DATE: 2026-06-18 (matches the 2026-06-18 CRASHED incident)
#   TODAY epoch for today-is-stale boundary: 1781870400 = 2026-06-19 12:00 UTC (end < today)

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------
setup() {
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../build-graph.sh"

  # Default curl stub — success; individual tests override STUB_CURL_RESPONSE /
  # STUB_CURL_EXIT to drive their scenario.
  curl() {
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  # sleep stub — make poll loops instant so tests run fast.
  # Blake's implementation will call `sleep ${OTP_RELOAD_POLL_INTERVAL}` inside
  # the poll loop; we replace sleep with a no-op so tests don't hang.
  sleep() {
    : # no-op — poll loop is instant in tests
  }
  export -f sleep

  # Fixed "today" — 2026-06-18 matches the CRASHED incident date.
  TODAY_DATE="${STUB_TODAY:-2026-06-18}"
  export TODAY_DATE

  # Default env vars
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export RAILWAY_API_TOKEN="test-token-bl334"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-otp-router"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-production"

  # Initialise poll-call counter for multi-response simulations
  POLL_CALL_COUNT=0
  export POLL_CALL_COUNT

  # Pre-redeploy serviceTimeRange.end (epoch for 2026-06-14 12:00 UTC).
  # Blake's implementation must capture this BEFORE calling trigger_railway_redeploy(),
  # then poll until the live end advances past it.
  PRE_REDEPLOY_END_EPOCH=1781438400
  export PRE_REDEPLOY_END_EPOCH
}

teardown() {
  unset BATS_SOURCE_ONLY
  unset RAILWAY_API_TOKEN
  unset RAILWAY_OTP_ROUTER_SERVICE_ID
  unset RAILWAY_OTP_ROUTER_ENVIRONMENT_ID
  unset RAILWAY_REDEPLOY_OPTIONAL
  unset OTP_ROUTER_SERVERINFO_URL
  unset STUB_CURL_RESPONSE
  unset STUB_CURL_EXIT
  unset STUB_TODAY
  unset TODAY_DATE
  unset OTP_RELOAD_POLL_TIMEOUT
  unset OTP_RELOAD_POLL_INTERVAL
  unset PRE_REDEPLOY_END_EPOCH
  unset POLL_CALL_COUNT
}

# ===========================================================================
# AC-1 + AC-2: wait_for_otp_router_reload() — poll loop exits FRESH once
#              mocked serviceTimeRange advances past pre-redeploy end
#
# AC-1: After triggering the otp-router redeploy, build-graph.sh polls
#        serviceTimeRange until it advances past the pre-redeploy
#        serviceTimeRange.end OR OTP_RELOAD_POLL_TIMEOUT is reached.
# AC-2: A successful build with a genuinely fresh graph reports FRESH (not a
#        false STALE) and the deployment does NOT crash on a timing artefact.
#
# These tests assert the NEW function wait_for_otp_router_reload() (which Blake
# must add).  That function does not exist yet → all tests in this group are RED.
# ===========================================================================

@test "AC-1: wait_for_otp_router_reload function is declared in build-graph.sh" {
  # AC-1: The new function must be extractable under BATS_SOURCE_ONLY=true.
  # CURRENTLY FAILS: function does not exist.
  declare -f wait_for_otp_router_reload > /dev/null
}

@test "AC-1+AC-2: wait_for_otp_router_reload exits 0 immediately when first poll already shows end advanced past pre-redeploy" {
  # AC-1+AC-2: If otp-router reloads fast enough that the very first poll
  # already returns end > PRE_REDEPLOY_END_EPOCH, the loop exits without
  # waiting.  This is the ideal no-delay path.
  #
  # PRE_REDEPLOY_END_EPOCH = 1781438400 (2026-06-14 12:00 UTC — old graph)
  # Mocked response end    = 1798761600 (2027-01-01 12:00 UTC — new graph)
  # 1798761600 > 1781438400 → loop should exit on poll 1 with status 0.
  #
  # CURRENTLY FAILS: function does not exist.
  export OTP_RELOAD_POLL_TIMEOUT=60
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  [ "$status" -eq 0 ]
}

@test "AC-1+AC-2: wait_for_otp_router_reload polls through stale responses and exits 0 once end advances (N-stale then fresh)" {
  # AC-1+AC-2: The core race scenario:
  #   Polls 1-3: end == PRE_REDEPLOY_END_EPOCH (otp-router still loading, old graph)
  #   Poll 4:    end  > PRE_REDEPLOY_END_EPOCH (new graph loaded)
  # The loop MUST wait through polls 1-3 and return 0 on poll 4.
  #
  # Implementation technique — stateful curl stub using a counter file:
  #   Each call to curl increments a counter; first 3 calls return the stale
  #   epoch; 4th call returns the fresh epoch.
  #
  # CURRENTLY FAILS: function does not exist.
  export OTP_RELOAD_POLL_TIMEOUT=300
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400

  # Stale response: end == PRE_REDEPLOY_END_EPOCH (not yet advanced)
  local STALE_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  # Fresh response: end > PRE_REDEPLOY_END_EPOCH (new graph loaded)
  local FRESH_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'

  # Use a temp file as a cross-process counter (shell functions run in subshells)
  local counter_file
  counter_file=$(mktemp)
  echo "0" > "${counter_file}"

  curl() {
    local count
    count=$(cat "${counter_file}")
    count=$((count + 1))
    echo "${count}" > "${counter_file}"
    if [ "${count}" -le 3 ]; then
      echo "${STALE_RESPONSE}"
    else
      echo "${FRESH_RESPONSE}"
    fi
    return 0
  }
  export -f curl

  run wait_for_otp_router_reload
  rm -f "${counter_file}"

  # Must exit 0: the loop found the fresh response on poll 4
  [ "$status" -eq 0 ]
}

@test "AC-1+AC-2: after wait_for_otp_router_reload succeeds, verify_otp_router_graph_freshness also exits 0 (no false STALE)" {
  # AC-2: Full sequence — poll wait succeeds then freshness verify also passes.
  # This is the exact race scenario that was CRASHING the deployment:
  #   Without the poll wait: verify ran immediately → saw old graph → CRASHED.
  #   With the poll wait: verify runs after graph is confirmed loaded → FRESH.
  #
  # Stub: all curl calls return the fresh (post-reload) response.
  # CURRENTLY FAILS: wait_for_otp_router_reload does not exist.
  export OTP_RELOAD_POLL_TIMEOUT=60
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  # end=1798761600 = 2027-01-01 12:00 UTC — well past today (2026-06-18) and
  # well past pre-redeploy end (2026-06-14 12:00 UTC)
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  # Step 1: poll wait must succeed
  run wait_for_otp_router_reload
  [ "$status" -eq 0 ]

  # Step 2: freshness verify must also succeed (no false STALE)
  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  # Must log FRESH verdict — not STALE
  [[ "$output" != *"STALE"* ]]
  [[ "$output" != *"stale"* ]]
}

@test "AC-1: wait_for_otp_router_reload logs polling progress (elapsed time or attempt count)" {
  # AC-1: The function must log progress so Railway build logs are diagnosable
  # (mirrors the existing "Still waiting for OTP... (Xs elapsed)" pattern in
  # the builder).  At minimum one log line referencing the poll/wait should
  # appear in output.
  #
  # This test uses 2 stale polls then a fresh poll so there IS a wait to log.
  # CURRENTLY FAILS: function does not exist.
  export OTP_RELOAD_POLL_TIMEOUT=300
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400

  local STALE_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  local FRESH_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'

  local counter_file
  counter_file=$(mktemp)
  echo "0" > "${counter_file}"

  curl() {
    local count
    count=$(cat "${counter_file}")
    count=$((count + 1))
    echo "${count}" > "${counter_file}"
    if [ "${count}" -le 2 ]; then
      echo "${STALE_RESPONSE}"
    else
      echo "${FRESH_RESPONSE}"
    fi
    return 0
  }
  export -f curl

  run wait_for_otp_router_reload
  rm -f "${counter_file}"

  [ "$status" -eq 0 ]
  # Must produce some progress logging — "waiting", "polling", "elapsed", or attempt count
  [[ "$output" == *"wait"* ]] || \
  [[ "$output" == *"poll"* ]] || \
  [[ "$output" == *"elapsed"* ]] || \
  [[ "$output" == *"attempt"* ]] || \
  [[ "$output" == *"reload"* ]]
}

# ===========================================================================
# AC-3: Genuine-staleness fail-closed — poll loop times out and script still
#        reports STALE / exits non-zero when window NEVER advances
#
# AC-3: A genuinely stale graph (window still behind today after the poll
#        completes / times out) still reports STALE and fails closed — the
#        BL-127 / TD-OTP-007 gate behaviour is preserved, not weakened.
# ===========================================================================

@test "AC-3: wait_for_otp_router_reload exits non-zero when serviceTimeRange end never advances past pre-redeploy end (genuine staleness)" {
  # AC-3: The loop must NOT wait forever — it must time out when the graph never
  # reloads.  When timed out, it must exit non-zero so the fail-closed gate fires.
  #
  # Stub: every curl call returns end == PRE_REDEPLOY_END_EPOCH (never advances).
  # OTP_RELOAD_POLL_TIMEOUT=1 (1 second) + OTP_RELOAD_POLL_INTERVAL=0 → times out
  # quickly.  The sleep stub in setup() makes the loop instant.
  #
  # CURRENTLY FAILS: function does not exist.
  # Precondition: function must exist for this test to be meaningful
  declare -f wait_for_otp_router_reload > /dev/null

  export OTP_RELOAD_POLL_TIMEOUT=1
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  # Stub always returns end == PRE_REDEPLOY_END_EPOCH (old graph never replaced)
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  # Must exit non-zero — the poll timed out without the graph advancing
  [ "$status" -ne 0 ]
  # Must log a clear timeout/staleness message
  [[ "$output" == *"timeout"* ]] || \
  [[ "$output" == *"TIMEOUT"* ]] || \
  [[ "$output" == *"timed out"* ]] || \
  [[ "$output" == *"STALE"* ]] || \
  [[ "$output" == *"stale"* ]]
}

@test "AC-3: genuine staleness gate preserved — verify_otp_router_graph_freshness still exits non-zero for a graph whose end is before today" {
  # AC-3 regression guard: the existing BL-127 staleness gate (verify_otp_router_graph_freshness)
  # must still exit non-zero when end_date < today, regardless of the new poll function.
  # This ensures the new poll-wait code does NOT weaken the final freshness verdict.
  #
  # end=1779278400 = 2026-05-20 12:00 UTC (same stale epoch as the 2026-06-04 incident)
  # today=2026-06-18 → end_date < today → STALE → exit non-zero
  #
  # This test should already be GREEN (verify_otp_router_graph_freshness already passes
  # in BL-127 tests), but is included here as an explicit regression guard for AC-3.
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1764547200,"end":1779278400}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || \
  [[ "$output" == *"stale"* ]] || \
  [[ "$output" == *"ERROR"* ]]
}

@test "AC-3: wait_for_otp_router_reload timeout message includes the configured timeout value" {
  # AC-3 diagnosability: the timeout error log must include the timeout duration
  # so Railway build logs are self-diagnosing without needing to re-read the script.
  #
  # OTP_RELOAD_POLL_TIMEOUT=42 → timeout after 42s; "42" must appear in the
  # timeout message.  We use 42 (not 1) so the assertion cannot accidentally pass
  # on command-not-found output that doesn't contain "42".
  # CURRENTLY FAILS: function does not exist.
  # Precondition: function must exist for this test to be meaningful
  declare -f wait_for_otp_router_reload > /dev/null

  export OTP_RELOAD_POLL_TIMEOUT=42
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  # Never advances
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  [ "$status" -ne 0 ]
  # Timeout value "42" must appear in output so logs are diagnosable;
  # this string cannot appear accidentally in "command not found" output
  [[ "$output" == *"42"* ]]
}

# ===========================================================================
# AC-4: Timeout and interval are configurable via env vars with sensible defaults
#
# AC-4: The poll interval and timeout are configurable via env var(s) with
#        documented defaults.
# ===========================================================================

@test "AC-4: OTP_RELOAD_POLL_TIMEOUT env var controls the poll timeout (low value = fast timeout in tests)" {
  # AC-4: With OTP_RELOAD_POLL_TIMEOUT=1 and a never-advancing stub, the function
  # must time out within a short wall-clock time.  This proves the env var is
  # honoured, not a hardcoded constant.
  #
  # sleep stub in setup() makes intervals instant; timeout=1 means 1 retry budget.
  # CURRENTLY FAILS: function does not exist.
  # Precondition: function must exist for this assertion to be meaningful
  declare -f wait_for_otp_router_reload > /dev/null

  export OTP_RELOAD_POLL_TIMEOUT=1
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  # Must exit non-zero (timeout) — and must NOT be exit 127 (command not found)
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC-4: OTP_RELOAD_POLL_INTERVAL env var is accepted without error (does not cause script abort)" {
  # AC-4: The function must accept OTP_RELOAD_POLL_INTERVAL without erroring.
  # With interval=0 and a fresh first poll, the function exits 0 immediately.
  # This verifies the variable is consumed without triggering set -u failures.
  #
  # CURRENTLY FAILS: function does not exist.
  export OTP_RELOAD_POLL_TIMEOUT=60
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  # Fresh on first poll → exit 0 immediately
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  [ "$status" -eq 0 ]
}

@test "AC-4: wait_for_otp_router_reload works without OTP_RELOAD_POLL_TIMEOUT set (uses default)" {
  # AC-4: Non-breaking default — if OTP_RELOAD_POLL_TIMEOUT is unset, the function
  # must NOT abort with "unbound variable" (set -u) and must use a sensible default.
  # Test: unset var + fresh first poll → exits 0.
  #
  # CURRENTLY FAILS: function does not exist.
  unset OTP_RELOAD_POLL_TIMEOUT
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  [ "$status" -eq 0 ]
}

@test "AC-4: wait_for_otp_router_reload works without OTP_RELOAD_POLL_INTERVAL set (uses default)" {
  # AC-4: Non-breaking default for the interval too — unset must not abort.
  # CURRENTLY FAILS: function does not exist.
  export OTP_RELOAD_POLL_TIMEOUT=60
  unset OTP_RELOAD_POLL_INTERVAL
  export PRE_REDEPLOY_END_EPOCH=1781438400
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  [ "$status" -eq 0 ]
}

@test "AC-4: wait_for_otp_router_reload works without PRE_REDEPLOY_END_EPOCH set (queries current end first)" {
  # AC-4 / implementation contract: if PRE_REDEPLOY_END_EPOCH is not pre-set by the
  # caller, the function must query the current serviceTimeRange.end itself as the
  # baseline (capture-then-compare), not abort with "unbound variable".
  #
  # With unset PRE_REDEPLOY_END_EPOCH and a fresh stub (end=1798761600):
  #   - If function queries the baseline first → sees 1798761600 → no advance needed
  #     (same response) → behaviour is implementation-defined (could exit 0 immediately
  #     OR poll once more; either is acceptable as long as exit 0).
  #   - Must NOT abort with "unbound variable" error.
  #   - Must NOT be a command-not-found (exit 127).
  #
  # CURRENTLY FAILS: function does not exist.
  # Precondition: function must exist for unbound-variable assertion to be meaningful
  declare -f wait_for_otp_router_reload > /dev/null

  unset PRE_REDEPLOY_END_EPOCH
  export OTP_RELOAD_POLL_TIMEOUT=60
  export OTP_RELOAD_POLL_INTERVAL=0
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run wait_for_otp_router_reload
  # Must exit without "unbound variable" abort — status 0 or 1 both acceptable
  # as long as it isn't a bash set-u error (which exits 1 with "unbound variable")
  # AND is not a command-not-found (exit 127)
  [ "$status" -ne 127 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" != *": PRE_REDEPLOY_END_EPOCH"* ]]
}

# ===========================================================================
# AC-5(c): Regression — successful build path still uploads to GCS unchanged
#
# AC-5(c): A regression test that a successful build path still uploads to
#           GCS unchanged (assert the existing upload step / gsutil invocation
#           is unaffected by the new poll logic).
#
# NOTE: build-graph.sh under BATS_SOURCE_ONLY=true does NOT execute the main
# pipeline (the guard at line 138 returns early).  We therefore cannot test the
# full pipeline end-to-end in bats.  Instead, these tests verify the two
# functions that sit around the new poll-wait — trigger_railway_redeploy (already
# GREEN in BL-333 tests) and verify_otp_router_graph_freshness (already GREEN in
# BL-127 tests) — are unaffected by the introduction of wait_for_otp_router_reload.
# The AC-5(c) regression test also directly grep-inspects the script source to
# assert the gsutil upload commands are not modified.
# ===========================================================================

@test "AC-5(c) regression: trigger_railway_redeploy still exits 0 with Boolean! success after poll-wait addition" {
  # AC-5(c): The pre-existing BL-333 fix (Boolean! mutation) must still work.
  # Adding wait_for_otp_router_reload must not break trigger_railway_redeploy.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Railway redeploy triggered"* ]]
}

@test "AC-5(c) regression: verify_otp_router_graph_freshness still exits 0 for a fresh graph after poll-wait addition" {
  # AC-5(c): The BL-127 freshness gate must still function after Blake adds
  # wait_for_otp_router_reload.  This guards against Blake accidentally altering
  # verify_otp_router_graph_freshness as part of the poll-wait implementation.
  #
  # end=1798761600 = 2027-01-01 12:00 UTC, today=2026-06-18 → FRESH → exit 0
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE"* ]]
  [[ "$output" != *"stale"* ]]
}

@test "AC-5(c) regression: verify_otp_router_graph_freshness still exits non-zero for a genuinely stale graph after poll-wait addition" {
  # AC-5(c): The BL-127 fail-closed gate must NOT be weakened by the poll-wait
  # addition.  A graph stale for today must still fail.
  #
  # end=1779278400 = 2026-05-20 12:00 UTC, today=2026-06-18 → STALE → exit non-zero
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1764547200,"end":1779278400}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || \
  [[ "$output" == *"stale"* ]] || \
  [[ "$output" == *"ERROR"* ]]
}

@test "AC-5(c) regression: GCS upload commands (gsutil) are present and unmodified in build-graph.sh" {
  # AC-5(c): The gsutil upload commands must remain in the script source.
  # Grep-inspect: both the versioned upload and the 'latest' pointer update
  # must be present.  This guards against Blake accidentally removing or
  # reordering the upload steps when implementing the poll-wait.
  #
  # This test is currently GREEN (the commands exist); it is included as a
  # regression guard that will turn RED immediately if Blake removes them.
  local script_path="${BATS_TEST_DIRNAME}/../build-graph.sh"

  # Versioned upload must exist
  run grep -c 'gsutil.*cp.*GRAPH_OUTPUT_VERSION' "${script_path}"
  [ "$output" -ge 1 ]

  # 'latest' pointer update must exist
  run grep -c 'gsutil.*cp.*latest' "${script_path}"
  [ "$output" -ge 1 ]
}

@test "AC-5(c) regression: wait_for_otp_router_reload call site is positioned BETWEEN trigger_railway_redeploy and verify_otp_router_graph_freshness in build-graph.sh" {
  # AC-5(c) structural regression: the poll-wait must be INSERTED between the
  # two existing calls, not placed before trigger or after verify.
  #
  # Strategy: grep the script for the line numbers of each call and assert their
  # ordering:  trigger_railway_redeploy < wait_for_otp_router_reload < verify_otp_router_graph_freshness
  #
  # CURRENTLY FAILS: wait_for_otp_router_reload does not exist in the script yet,
  # so grep returns exit 1 for it → the line-number comparison fails.
  local script_path="${BATS_TEST_DIRNAME}/../build-graph.sh"

  # Extract line numbers (grep -n returns "linenum:text"; cut extracts linenum)
  local trigger_line wait_line verify_line

  trigger_line=$(grep -n 'trigger_railway_redeploy$' "${script_path}" | tail -1 | cut -d: -f1)
  wait_line=$(grep -n 'wait_for_otp_router_reload' "${script_path}" | tail -1 | cut -d: -f1)
  verify_line=$(grep -n 'verify_otp_router_graph_freshness$' "${script_path}" | tail -1 | cut -d: -f1)

  # All three must be found (non-empty line numbers)
  [ -n "${trigger_line}" ]
  [ -n "${wait_line}" ]
  [ -n "${verify_line}" ]

  # Ordering: trigger < wait < verify
  [ "${trigger_line}" -lt "${wait_line}" ]
  [ "${wait_line}" -lt "${verify_line}" ]
}
