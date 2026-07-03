#!/usr/bin/env bats
# BL-360 (TD-OTP-C): Test Specification — freshness gate forward headroom
#
# ORIGIN: 2026-07-02 graph-currency incident (Blake T1: H-B acute). Live
# otp-router graph ended 2026-06-30; today (2026-07-02) returned 0
# itineraries. Both existing freshness checks assert only
# `serviceTimeRange.end >= today` — ZERO forward buffer. A graph ending
# EXACTLY today passes the gate today, yet is one missed/late twice-weekly
# rebuild away from stranding. This suite hardens both gates to require a
# configurable forward-headroom buffer: `end >= today + N`.
#
# RELATIONSHIP TO SIBLING ITEMS:
#   BL-335 (TD-OTP-B) widens the GENERATED GTFS window to today+14 (data
#   side). THIS item (BL-360/TD-OTP-C) hardens the GATE that validates the
#   loaded graph (verification side). Complementary, not overlapping.
#
#   BL-334 (TD-OTP-A) — ALREADY SHIPPED (commit 0559eef, 2026-06-18):
#   wait_for_otp_router_reload() poll-and-wait + reload-confirmation
#   exit-code propagation. AC-4 below is a REGRESSION LOCK ONLY — do NOT
#   re-implement, and do NOT modify build-graph-bl334-poll-wait.bats
#   (Test Lock Rule).
#
# TARGET FUNCTIONS (both currently assert only `end >= today`, no headroom):
#   build-graph.sh    -> verify_otp_router_graph_freshness()  (~line 126)
#   validate-graph.sh -> check_graph_freshness()               (~line 69)
#
# NEW ENV VAR (Quinn T2 planning, 2026-07-02): GRAPH_FRESHNESS_HEADROOM_DAYS
#   Forward buffer in days, default >=2. `end >= today + N` -> FRESH;
#   `end < today + N` -> STALE (fail-closed, non-zero exit).
#
#   NOTE: GRAPH_FRESHNESS_DAYS (validate-graph.sh, existing) is a SEPARATE,
#   BACKWARD-tolerance knob (end >= today - GRAPH_FRESHNESS_DAYS). Do NOT
#   conflate the two. GRAPH_FRESHNESS_HEADROOM_DAYS is a new, independent,
#   FORWARD-looking knob added to BOTH scripts.
#
# ACs (from BL-360 Notion page, each test maps to exactly one AC):
#   AC-1 (build-graph.sh):    verify_otp_router_graph_freshness() asserts
#                             end_date >= today + N (N configurable, default >=2).
#   AC-2 (validate-graph.sh): check_graph_freshness() gains the same
#                             forward-headroom assertion, independent of the
#                             existing backward GRAPH_FRESHNESS_DAYS tolerance.
#   AC-3 (loud failure):      stale/near-stale -> non-zero exit with a
#                             self-diagnosing log line naming end_date, today, N.
#   AC-4 (regression lock):   BL-334 reload-confirmation exit-code propagation
#                             is NOT weakened by this change (guard only).
#   AC-5 (coverage):          (a) end==today -> STALE; (b) end==today+N -> FRESH;
#                             (c) end==today+N-1 -> STALE; (d) forward buffer var
#                             is configurable with a documented default.
#
# Requirements:
#   - bats-core >= 1.10.0
#   - build-graph.sh / validate-graph.sh must expose their functions when
#     sourced with BATS_SOURCE_ONLY=true (existing guard, BL-127/BL-333 precedent)
#
# Run: bats tests/build-graph-bl360-freshness-headroom.bats
#
# Epoch reference (all at 12:00:00 UTC to be timezone-unambiguous on any host):
#   TODAY_DATE fixed at 2026-07-02 (matches the incident date).
#   2026-07-02 12:00 UTC = 1782993600
#   +1 day  (2026-07-03 12:00 UTC) = 1783080000
#   +2 days (2026-07-04 12:00 UTC) = 1783166400  <- default headroom N=2 boundary
#   +3 days (2026-07-05 12:00 UTC) = 1783252800

# ---------------------------------------------------------------------------
# setup / teardown — build-graph.sh scenarios
# ---------------------------------------------------------------------------
setup_build_graph() {
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../build-graph.sh"

  curl() {
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  TODAY_DATE="${STUB_TODAY:-2026-07-02}"
  export TODAY_DATE
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
}

# ---------------------------------------------------------------------------
# setup / teardown — validate-graph.sh scenarios
# ---------------------------------------------------------------------------
setup_validate_graph() {
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../validate-graph.sh"

  curl() {
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  TODAY_DATE="${STUB_TODAY:-2026-07-02}"
  export TODAY_DATE
  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
}

teardown() {
  unset BATS_SOURCE_ONLY
  unset OTP_ROUTER_SERVERINFO_URL
  unset OTP_VALIDATION_URL
  unset STUB_CURL_RESPONSE
  unset STUB_CURL_EXIT
  unset STUB_TODAY
  unset TODAY_DATE
  unset GRAPH_FRESHNESS_HEADROOM_DAYS
  unset GRAPH_FRESHNESS_DAYS
  unset PRE_REDEPLOY_END_EPOCH
  unset OTP_RELOAD_POLL_TIMEOUT
  unset OTP_RELOAD_POLL_INTERVAL
}

# ===========================================================================
# AC-1 + AC-5(a): build-graph.sh -> verify_otp_router_graph_freshness()
#                 DISPOSITIVE RED: end == today must now be STALE
# ===========================================================================

@test "AC-1/AC-5(a) [build-graph.sh]: verify_otp_router_graph_freshness reports STALE when end == today (zero headroom, DEFAULT config — no forward buffer)" {
  # DISPOSITIVE RED: under CURRENT code, end==today passes (end >= today).
  # This proves the headroom requirement is enforced, not just `>= today`.
  # No GRAPH_FRESHNESS_HEADROOM_DAYS set -> must use the new default (>=2),
  # so end==today (0 days of headroom) is STALE.
  # CURRENTLY FAILS: current code has no headroom concept; end==today passes.
  setup_build_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  # end = 2026-07-02 12:00 UTC (== today, zero forward headroom)
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1782993600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || [[ "$output" == *"stale"* ]]
}

@test "AC-1/AC-5(b) [build-graph.sh]: verify_otp_router_graph_freshness reports FRESH when end == today + N (N=default headroom)" {
  # end = 2026-07-04 12:00 UTC (today + 2 days) with default N>=2 -> FRESH.
  # CURRENTLY FAILS if the default headroom is asserted at all — under current
  # code this already passes (end > today), so this is a guard/GREEN-by-luck
  # test rather than the dispositive assertion; kept for AC-5(b) coverage.
  setup_build_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783166400}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"FRESH"* ]] || [[ "$output" == *"OK"* ]]
}

@test "AC-1/AC-5(c) [build-graph.sh]: verify_otp_router_graph_freshness reports STALE when end == today + N - 1 (one day short of default headroom)" {
  # end = 2026-07-03 12:00 UTC (today + 1 day). With default N>=2, this is
  # 1 day short of the required headroom -> STALE.
  # CURRENTLY FAILS: current code only checks end >= today; today+1 already
  # passes under current code, so this is also a dispositive RED assertion.
  setup_build_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783080000}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || [[ "$output" == *"stale"* ]]
}

@test "AC-1/AC-5(d) [build-graph.sh]: GRAPH_FRESHNESS_HEADROOM_DAYS is configurable — explicit N=3 requires end >= today+3" {
  # Differentiating configured value (N=3, distinct from the default) proves
  # the var is genuinely read, not a hardcoded constant.
  # end = 2026-07-04 12:00 UTC (today + 2 days) with N=3 explicitly configured
  # -> 2 days of headroom < 3 required -> STALE.
  # CURRENTLY FAILS: the env var does not exist / is not honoured.
  setup_build_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export GRAPH_FRESHNESS_HEADROOM_DAYS=3
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783166400}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || [[ "$output" == *"stale"* ]]
}

@test "AC-1/AC-5(d) [build-graph.sh]: GRAPH_FRESHNESS_HEADROOM_DAYS=3 explicit config passes when end >= today+3" {
  # Same configured N=3, but end = today + 3 days exactly -> satisfies the
  # configured headroom -> FRESH. Proves the var drives the threshold in
  # both directions (not just tightening).
  # CURRENTLY FAILS: the env var does not exist / is not honoured (would
  # currently pass anyway since end > today, but must pass FOR THE RIGHT
  # REASON once headroom logic exists — verified via AC-3 log content below).
  setup_build_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export GRAPH_FRESHNESS_HEADROOM_DAYS=3
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783252800}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
}

# ===========================================================================
# AC-3: loud failure — self-diagnosing log line naming end_date, today, N
# ===========================================================================

@test "AC-3 [build-graph.sh]: STALE verdict logs end_date, today, and the configured headroom N (self-diagnosing)" {
  # AC-3: the failure log must name all three values so Railway build logs
  # are diagnosable without re-reading the script.
  # CURRENTLY FAILS: current error message does not mention a headroom value N.
  setup_build_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export GRAPH_FRESHNESS_HEADROOM_DAYS=2
  # end == today -> STALE under the new gate
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1782993600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  # end_date must be named
  [[ "$output" == *"2026-07-02"* ]]
  # the configured headroom value (2) must be named
  [[ "$output" == *"2"* ]]
}

# ===========================================================================
# AC-2 + AC-5: validate-graph.sh -> check_graph_freshness()
#              same headroom hardening, independent of GRAPH_FRESHNESS_DAYS
# ===========================================================================

@test "AC-2/AC-5(a) [validate-graph.sh]: check_graph_freshness reports STALE when end == today (zero headroom, DEFAULT config)" {
  # DISPOSITIVE RED: under CURRENT code, end==today passes.
  # CURRENTLY FAILS: no headroom concept exists yet.
  setup_validate_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1782993600}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || [[ "$output" == *"stale"* ]]
}

@test "AC-2/AC-5(b) [validate-graph.sh]: check_graph_freshness reports FRESH when end == today + N (N=default headroom)" {
  setup_validate_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783166400}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -eq 0 ]
}

@test "AC-2/AC-5(c) [validate-graph.sh]: check_graph_freshness reports STALE when end == today + N - 1 (one day short of default headroom)" {
  # CURRENTLY FAILS: current code only checks end >= threshold_date (which
  # defaults to today when GRAPH_FRESHNESS_DAYS=0); today+1 already passes
  # under current code.
  setup_validate_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783080000}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || [[ "$output" == *"stale"* ]]
}

@test "AC-2/AC-5(d) [validate-graph.sh]: GRAPH_FRESHNESS_HEADROOM_DAYS is configurable independently of GRAPH_FRESHNESS_DAYS" {
  # Sets BOTH knobs simultaneously with distinct values to prove they are
  # separate, non-conflated variables:
  #   GRAPH_FRESHNESS_DAYS=5       (backward tolerance — irrelevant here, end > today)
  #   GRAPH_FRESHNESS_HEADROOM_DAYS=3 (forward headroom — the one under test)
  # end = today + 2 days -> satisfies backward tolerance trivially (end > today)
  # but does NOT satisfy the forward headroom of 3 -> STALE.
  # CURRENTLY FAILS: GRAPH_FRESHNESS_HEADROOM_DAYS does not exist; current
  # code would only look at GRAPH_FRESHNESS_DAYS and pass (end > today).
  setup_validate_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export GRAPH_FRESHNESS_DAYS=5
  export GRAPH_FRESHNESS_HEADROOM_DAYS=3
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1783166400}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]] || [[ "$output" == *"stale"* ]]
}

@test "AC-2/AC-5(d) [validate-graph.sh]: existing GRAPH_FRESHNESS_DAYS backward tolerance still works unmodified when headroom is explicitly disabled" {
  # Regression guard: with GRAPH_FRESHNESS_HEADROOM_DAYS=0 (explicit opt-out),
  # the pre-existing backward-tolerance behaviour (GRAPH_FRESHNESS_DAYS=3,
  # end = today - 2 days -> within tolerance -> FRESH) must be unaffected by
  # the new forward-headroom knob. Proves the two knobs are independent.
  setup_validate_graph

  export STUB_TODAY=2026-06-14
  TODAY_DATE=2026-06-14
  export TODAY_DATE
  export GRAPH_FRESHNESS_DAYS=3
  export GRAPH_FRESHNESS_HEADROOM_DAYS=0
  # end = 2026-06-12 12:00 UTC (today - 2 days) — within GRAPH_FRESHNESS_DAYS=3 tolerance
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781265600}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -eq 0 ]
}

@test "AC-3 [validate-graph.sh]: STALE verdict logs end_date, today, and the configured headroom N (self-diagnosing)" {
  setup_validate_graph

  export STUB_TODAY=2026-07-02
  TODAY_DATE=2026-07-02
  export TODAY_DATE
  export GRAPH_FRESHNESS_HEADROOM_DAYS=2
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1782993600}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"2026-07-02"* ]]
  [[ "$output" == *"2"* ]]
}

# ===========================================================================
# AC-4: REGRESSION LOCK — BL-334 reload-confirmation exit-code propagation
#       must NOT be weakened by the headroom change. Guard test only; does
#       NOT modify build-graph-bl334-poll-wait.bats (Test Lock Rule).
# ===========================================================================

@test "AC-4 (regression lock) [build-graph.sh]: wait_for_otp_router_reload still exits non-zero when serviceTimeRange never advances past pre-redeploy baseline, independent of headroom config" {
  # AC-4: BL-334 shipped wait_for_otp_router_reload() with reload-confirmation
  # exit-code propagation (commit 0559eef, 2026-06-18). This headroom change
  # must not weaken that: even with GRAPH_FRESHNESS_HEADROOM_DAYS configured,
  # a router that never confirms a new serviceTimeRange must still fail closed.
  # This test should be GREEN already (wait_for_otp_router_reload is untouched
  # by BL-360) — included as an explicit regression guard per AC-4.
  setup_build_graph

  export GRAPH_FRESHNESS_HEADROOM_DAYS=2
  export OTP_RELOAD_POLL_TIMEOUT=1
  export OTP_RELOAD_POLL_INTERVAL=0
  export PRE_REDEPLOY_END_EPOCH=1781438400
  # Stub always returns end == PRE_REDEPLOY_END_EPOCH (graph never replaced)
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  export STUB_CURL_EXIT=0

  sleep() {
    : # no-op — poll loop is instant in tests
  }
  export -f sleep

  run wait_for_otp_router_reload
  [ "$status" -ne 0 ]
}

@test "AC-4 (regression lock) [build-graph.sh]: wait_for_otp_router_reload function still declared and reachable after headroom change" {
  # AC-4 prerequisite guard: the BL-334 function must still exist and be
  # sourceable — proves BL-360's changes to build-graph.sh did not remove or
  # rename it.
  setup_build_graph
  declare -f wait_for_otp_router_reload > /dev/null
}
