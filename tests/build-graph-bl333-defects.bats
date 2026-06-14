#!/usr/bin/env bats
# BL-333 (TD-1): Test Specification — otp-graph-builder shell defects
#
# Defects being fixed (this session's findings — authoritative):
#
# DEFECT 1 (build-graph.sh ~line 39):
#   trigger_railway_redeploy() sends mutation with `{ id }` selection set.
#   Railway's API now returns Boolean! (no subfields). When the real Railway API
#   sees `{ id }`, it returns a GraphQL validation error (HTTP 400). curl exits
#   22 (HTTP 400 via --fail-with-body). set -euo pipefail (line 142) ABORTS the
#   script before verify_otp_router_graph_freshness() (the BL-127 fix) runs.
#   Net effect: auto otp-router redeploy never fires; BL-127 staleness-check fix
#   is never exercised.
#
# DEFECT 2 (validate-graph.sh ~line 85):
#   Plan query is hardcoded to `date:"2025-01-15"`. No serviceTimeRange check
#   exists. A graph stale for TODAY passes validation silently.
#
# ACs (from Quinn's TD-0 spec — each test maps to exactly one AC):
#
#   AC-1: trigger_railway_redeploy() issues serviceInstanceRedeploy(serviceId,
#         environmentId) mutation WITHOUT `{ id }` selection set (returns Boolean!),
#         and treats a Boolean! success response as success — no GraphQL 400, no abort.
#
#   AC-2: After a successful build, verify_otp_router_graph_freshness() is REACHED
#         and EXECUTES (not skipped due to earlier abort), and produces a correct
#         fresh/stale verdict given a mocked OTP serviceTimeRange response.
#
#   AC-3: The auto otp-router redeploy fires after a successful graph build (the
#         trigger_railway_redeploy call is made and its success allows the script
#         to continue to verify + completion).
#
#   AC-4: validate-graph.sh checks serviceTimeRange (or graph service window) covers
#         ~today within a CONFIGURABLE freshness window, and FAILS when the window is
#         stale-for-today — replacing the hardcoded 2025-01-15 behaviour.
#
#   AC-5 (regression): A normal successful build still completes and uploads to GCS
#         (${VERSION}/ + latest/) — the fix does not break the happy path.
#
# NOTE on AC-4 / validate-graph.sh:
#   validate-graph.sh is currently a linear script with no sourcing guard and no
#   testable functions. Blake must:
#     (a) Add a BATS_SOURCE_ONLY guard (same pattern as build-graph.sh lines 138-140)
#     (b) Extract the freshness check into check_graph_freshness() function
#   These tests import validate-graph.sh under BATS_SOURCE_ONLY=true and invoke
#   check_graph_freshness() directly — exactly as build-graph-railway-redeploy.bats
#   tests build-graph.sh functions.
#
# Requirements:
#   - bats-core >= 1.10.0
#   - build-graph.sh and validate-graph.sh must expose their functions when
#     sourced with BATS_SOURCE_ONLY=true
#
# Run: bats tests/build-graph-bl333-defects.bats

# ---------------------------------------------------------------------------
# Shared setup — source build-graph.sh and install curl stub
# ---------------------------------------------------------------------------
setup() {
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../build-graph.sh"

  # Default curl stub — success path; override STUB_CURL_RESPONSE / STUB_CURL_EXIT
  # per-test to drive the scenario under test.
  curl() {
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  # Fixed "today" so AC-2/AC-3/AC-4 freshness comparisons are deterministic.
  # Tests that need a different today override TODAY_DATE explicitly.
  TODAY_DATE="${STUB_TODAY:-2026-06-14}"
  export TODAY_DATE

  # Default env vars for trigger_railway_redeploy — individual tests unset or change
  export RAILWAY_API_TOKEN="test-token-bl333"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-bl333"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-production"
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
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
  unset GRAPH_FRESHNESS_DAYS
}

# ===========================================================================
# AC-1: Mutation shape — Boolean! return type (no { id } selection set)
#
# ROOT CAUSE: line 39 of build-graph.sh assembles:
#   mutation { serviceInstanceRedeploy(serviceId: "…", environmentId: "…") { id } }
#                                                                          ^^^^
#   Railway now returns Boolean! — requesting { id } causes HTTP 400 / curl exit 22.
#
# These tests:
#   AC-1a — assert the mutation string the function constructs does NOT contain
#            the literal `{ id }` after serviceInstanceRedeploy(...).
#   AC-1b — assert that when Railway responds with the correct Boolean! shape
#            (no "id" field, just `{"data":{"serviceInstanceRedeploy":true}}`)
#            the function exits 0 (success), proving no regression on the
#            response-shape check.
#   AC-1c — assert that when Railway returns a GraphQL 400 because of the old
#            `{ id }` shape (simulated as a STUB that returns an `"errors"` body),
#            the current code exits non-zero — confirming the bug exists and the
#            test is RED against the CURRENT code.
#
# Test AC-1a fails against current code because the constructed query CONTAINS
# `{ id }`. It will pass once Blake removes `{ id }` from line 39.
# ===========================================================================

@test "AC-1: trigger_railway_redeploy mutation does NOT include '{ id }' selection set (Railway returns Boolean!)" {
  # AC-1: The mutation string must not contain `{ id }` after serviceInstanceRedeploy(...)
  # because Railway's API now returns Boolean! which has no subfields.
  #
  # Strategy: override curl to capture the -d payload, then assert the content.
  # A curl stub that echoes STUB_CURL_RESPONSE is set in setup(); we override curl
  # here to also write the captured body to a temp file for inspection.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  CAPTURED_BODY_FILE=$(mktemp)
  curl() {
    local prev=""
    for arg in "$@"; do
      if [ "$prev" = "-d" ]; then
        echo "$arg" > "${CAPTURED_BODY_FILE}"
      fi
      prev="$arg"
    done
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  run trigger_railway_redeploy

  local body
  body=$(cat "${CAPTURED_BODY_FILE}" 2>/dev/null || echo "")
  rm -f "${CAPTURED_BODY_FILE}"

  # The mutation body must NOT contain `{ id }` — that field does not exist on Boolean!
  # CURRENTLY FAILS: current code produces: serviceInstanceRedeploy(...) { id }
  [[ "$body" != *'{ id }'* ]]
}

@test "AC-1: trigger_railway_redeploy exits 0 when Railway returns Boolean! true (correct post-fix shape)" {
  # AC-1: With the correct mutation (no { id }), Railway returns Boolean! true.
  # The function must treat this as success and exit 0.
  #
  # CURRENTLY: this test MAY pass IF the curl stub returns 0 and the response
  # body has no "errors" key — the existing success path is broad enough. The
  # definitive RED test is AC-1a above (mutation shape assertion).
  # This test validates the post-fix happy path is correctly interpreted.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Railway redeploy triggered"* ]]
}

@test "AC-1: trigger_railway_redeploy exits 0 when Railway returns Boolean! false (documented non-error per API)" {
  # AC-1: Railway can return false (e.g., already deploying) which is a valid Boolean!
  # value, NOT an error. The function must exit 0 for this shape too — it is not
  # an errors body.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":false}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
}

@test "AC-1: trigger_railway_redeploy exits non-zero when Railway returns GraphQL 400 (old { id } mutation shape — current defect)" {
  # AC-1 RED proof: when the mutation includes { id }, Railway returns an errors body.
  # The function already checks for "errors" in the response and returns non-zero.
  # This test documents that the CURRENT code would abort on the real Railway API,
  # because the real API sends {"errors":[{"message":"...Boolean! cannot have subfields"}]}.
  # We simulate that 400 response here.
  #
  # This test is currently GREEN (the errors-body handler already works).
  # It exists as a REGRESSION GUARD: after the fix removes { id }, the real
  # Railway API will return Boolean! (not this error), so this scenario should
  # not occur — but if it does recur, this test catches it.
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Field '\''serviceInstanceRedeploy'\'' of type '\''Boolean!'\'' must not have a sub selection"}]}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

# ===========================================================================
# AC-2: verify_otp_router_graph_freshness() is REACHED after trigger_railway_redeploy
#
# ROOT CAUSE: The { id } mutation 400s → curl exits 22 → set -euo pipefail aborts
# the entire build-graph.sh script before reaching verify_otp_router_graph_freshness().
#
# Under BATS_SOURCE_ONLY=true the pipeline (set -euo pipefail) is NOT active,
# so we cannot directly test "the pipeline aborts". Instead, we test the two
# observable contract properties:
#
#   AC-2a — With a Boolean!-success stub, trigger_railway_redeploy exits 0 AND
#            verify_otp_router_graph_freshness can then be called and exits 0
#            (fresh graph). This confirms both functions are reachable in sequence.
#   AC-2b — With a fresh-graph OTP stub, verify_otp_router_graph_freshness
#            produces a correct FRESH verdict (exits 0, logs "OK").
#   AC-2c — With a stale-graph OTP stub, verify_otp_router_graph_freshness
#            produces a correct STALE verdict (exits non-zero, logs "stale" or "ERROR").
#
# AC-2b and AC-2c directly test the freshness-verdict correctness requirement
# from the AC specification ("produces a correct fresh/stale verdict given a
# mocked OTP serviceTimeRange response").
# ===========================================================================

@test "AC-2: trigger_railway_redeploy exits 0 with Boolean! response then verify_otp_router_graph_freshness is reachable (exits 0, fresh graph)" {
  # AC-2: Both functions execute in sequence without abort.
  # Stub: redeploy returns Boolean! true; freshness check returns end epoch > today.
  # end=1798761600 = 2027-01-01 12:00 UTC (noon-UTC — well beyond 2026-06-14 today)
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]

  # Now reset stub to OTP freshness response and call the verify function
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]] || [[ "$output" == *"fresh"* ]] || [[ "$output" == *"serviceTimeRange"* ]]
}

@test "AC-2: verify_otp_router_graph_freshness produces correct FRESH verdict for graph ending after today" {
  # AC-2: fresh graph verdict — end epoch 1798761600 = 2027-01-01 12:00 UTC, today = 2026-06-14
  # end_date (2027-01-01) >= today (2026-06-14) → exit 0
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]] || [[ "$output" == *"serviceTimeRange"* ]]
}

@test "AC-2: verify_otp_router_graph_freshness produces correct STALE verdict for graph ending before today" {
  # AC-2: stale graph verdict — end epoch 1747483200 = 2025-05-17 12:00 UTC, today = 2026-06-14
  # end_date (2025-05-17) < today (2026-06-14) → exit non-zero
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1740000000,"end":1747483200}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"STALE"* ]] || [[ "$output" == *"ERROR"* ]]
}

# ===========================================================================
# AC-3: Auto otp-router redeploy fires after a successful graph build
#
# The build pipeline sequence (post set -euo pipefail section) is:
#   ... GCS upload ...
#   trigger_railway_redeploy      ← must be called; must succeed (exit 0)
#   verify_otp_router_graph_freshness ← must then be called; must succeed
#
# Under BATS_SOURCE_ONLY we test this as: given a Boolean!-success redeploy
# stub AND a fresh-graph freshness stub, calling both functions in sequence
# exits 0 at each step — proving neither causes an abort that would prevent
# the other from running.
#
# AC-3a: redeploy call succeeds (exit 0) with Boolean! response
# AC-3b: after redeploy success, freshness check is invoked and exits 0
# AC-3c: the mutation string contains serviceInstanceRedeploy (redeploy fires, not skipped)
# ===========================================================================

@test "AC-3: trigger_railway_redeploy exits 0 with Boolean! true response (redeploy fires after successful build)" {
  # AC-3: The auto redeploy step executes and returns success.
  # Boolean! true = Railway accepted the redeploy request.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Railway redeploy triggered"* ]]
}

@test "AC-3: trigger_railway_redeploy mutation targets serviceInstanceRedeploy endpoint (not a no-op)" {
  # AC-3: The mutation must contain the serviceInstanceRedeploy keyword — proving it
  # is calling the Railway API, not silently skipping.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  CAPTURED_BODY_FILE=$(mktemp)
  curl() {
    local prev=""
    for arg in "$@"; do
      if [ "$prev" = "-d" ]; then
        echo "$arg" > "${CAPTURED_BODY_FILE}"
      fi
      prev="$arg"
    done
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  run trigger_railway_redeploy

  local body
  body=$(cat "${CAPTURED_BODY_FILE}" 2>/dev/null || echo "")
  rm -f "${CAPTURED_BODY_FILE}"

  # The mutation must reference the Railway serviceInstanceRedeploy mutation
  [[ "$body" == *"serviceInstanceRedeploy"* ]]
  # The mutation must include the serviceId argument
  [[ "$body" == *"serviceId"* ]]
}

@test "AC-3: trigger_railway_redeploy exits 0 then verify_otp_router_graph_freshness exits 0 — full post-build chain completes without abort" {
  # AC-3: Exercises the two-step post-build chain:
  #   trigger_railway_redeploy (Boolean! success) → exits 0
  #   verify_otp_router_graph_freshness (fresh OTP) → exits 0
  # Both steps must succeed for the build to be marked complete.
  # end=1798761600 = 2027-01-01 12:00 UTC, today=2026-06-14 → fresh

  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0
  run trigger_railway_redeploy
  [ "$status" -eq 0 ]

  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0
  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
}

# ===========================================================================
# AC-4: validate-graph.sh — serviceTimeRange freshness check (replaces hardcoded 2025-01-15)
#
# CURRENT STATE (defect): validate-graph.sh line 85 hardcodes date:"2025-01-15"
# in the plan query. There is no serviceTimeRange check. A graph stale for TODAY
# passes validation silently.
#
# REQUIRED FIX: Blake must:
#   (a) Add BATS_SOURCE_ONLY guard at end of validate-graph.sh (same pattern as
#       build-graph.sh lines 138-140)
#   (b) Extract a check_graph_freshness() function that:
#       - accepts an OTP GraphQL URL (or reads OTP_VALIDATION_URL env var)
#       - queries serviceTimeRange { start end } via curl
#       - compares end epoch to TODAY (via TODAY_DATE env var or $(date +%Y-%m-%d))
#       - exits 0 if end_date >= today (fresh)
#       - exits non-zero if end_date < today (stale)
#       - accepts GRAPH_FRESHNESS_DAYS env var (default 0) as a tolerance window
#         (the plan date in the query should be today - GRAPH_FRESHNESS_DAYS,
#          or the comparison is end_date >= today - GRAPH_FRESHNESS_DAYS)
#   (c) Call check_graph_freshness() as part of the validation sequence
#   (d) Remove the hardcoded 2025-01-15 date from the plan query (or make it
#       compute from today's date)
#
# These tests source validate-graph.sh under BATS_SOURCE_ONLY=true (which Blake
# must add) and call check_graph_freshness() directly.
#
# setup_validate_graph() is called at the start of each AC-4 test to source
# validate-graph.sh AFTER build-graph.sh (which setup() already sourced).
# We cannot source in the setup() block because:
#   1. validate-graph.sh currently lacks the BATS_SOURCE_ONLY guard (that's
#      the defect — sourcing it would execute the full script and fail)
#   2. Once Blake adds the guard, these tests will be able to source it here
#
# The tests are written to FAIL now (before Blake's fix) because:
#   - check_graph_freshness does not exist yet → declare -f will return non-zero
#   - validate-graph.sh lacks BATS_SOURCE_ONLY guard → sourcing fails
# ===========================================================================

# Helper: source validate-graph.sh in BATS_SOURCE_ONLY mode.
# This will FAIL against current code (no guard → script runs and errors).
# After Blake's fix (guard added + check_graph_freshness extracted), it passes.
source_validate_graph() {
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../validate-graph.sh" 2>/dev/null
}

@test "AC-4: validate-graph.sh can be sourced under BATS_SOURCE_ONLY=true without executing the full validation pipeline" {
  # AC-4 prerequisite: validate-graph.sh must expose check_graph_freshness() when
  # sourced with BATS_SOURCE_ONLY=true, mirroring build-graph.sh lines 138-140.
  # CURRENTLY FAILS: validate-graph.sh has no BATS_SOURCE_ONLY guard; sourcing it
  # tries to run the full validation (OTP start, curl, kill, etc.) and fails.
  source_validate_graph
  # If we reach here without error, the guard is in place
  true
}

@test "AC-4: check_graph_freshness function is declared in validate-graph.sh after sourcing" {
  # AC-4: Blake must extract the freshness check into a named function.
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph
  declare -f check_graph_freshness > /dev/null
}

@test "AC-4: check_graph_freshness exits 0 when OTP serviceTimeRange end epoch covers today (fresh graph)" {
  # AC-4: Fresh graph passes validation.
  # end=1798761600 = 2027-01-01 12:00 UTC, today=2026-06-14 → end_date >= today → exit 0
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph

  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0
  # Reuse the curl stub installed in setup()

  run check_graph_freshness
  [ "$status" -eq 0 ]
}

@test "AC-4: check_graph_freshness exits non-zero when OTP serviceTimeRange end epoch is before today (stale graph)" {
  # AC-4: Stale graph fails validation — the CRITICAL new behaviour.
  # end=1747483200 = 2025-05-17 12:00 UTC, today=2026-06-14 → end_date < today → exit non-zero
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph

  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1740000000,"end":1747483200}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"STALE"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "AC-4: check_graph_freshness exits non-zero when stale graph end date is the infamous hardcoded 2025-01-15 (defect baseline)" {
  # AC-4 RED proof against the EXACT defect: a graph ending 2025-01-15 must now
  # be flagged as stale when today is 2026-06-14. Previously the hardcoded plan
  # date masked this — today's test date exposes the gap.
  # end epoch for 2025-01-15 12:00 UTC = 1736942400
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph

  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1734000000,"end":1736942400}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"STALE"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "AC-4: check_graph_freshness exits 0 when serviceTimeRange end epoch equals today exactly (boundary — must not be false-positive stale)" {
  # AC-4 boundary: end_date == today → fresh (same-day graph is valid).
  # end=1718366400 = 2026-06-14 12:00 UTC, today=2026-06-14 → end_date >= today → exit 0
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph

  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
  # 2026-06-14 12:00:00 UTC = 1718366400? Let me compute correctly:
  # Base: 2026-06-14 = days since epoch
  # 2026-01-01 = 1767225600 (from known: 2026-05-17 12:00 = 1747483200 used above is wrong — that's 2025)
  # Re-derive: 1747483200 / 86400 = 20230.59... days → 1970 + 55.4 years → 2025-05-17 ✓
  # 2026-06-14 12:00 UTC:
  #   2026 = 2025 + 1 year = 1747483200 (2025-05-17) base is off
  #   Use direct: 2026-01-01 00:00 UTC = 1767225600
  #   2026-06-14 = 2026-01-01 + 164 days = 1767225600 + (164 * 86400) = 1767225600 + 14169600 = 1781395200
  #   2026-06-14 12:00 UTC = 1781395200 + 43200 = 1781438400
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781438400}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -eq 0 ]
}

@test "AC-4: check_graph_freshness exits 0 when graph is within GRAPH_FRESHNESS_DAYS tolerance window" {
  # AC-4 configurable tolerance: if GRAPH_FRESHNESS_DAYS=3, a graph ending up to
  # 3 days ago is still considered fresh.
  # today=2026-06-14, GRAPH_FRESHNESS_DAYS=3, end=2026-06-12 → within tolerance → exit 0
  # end epoch for 2026-06-12 12:00 UTC = 1781438400 - (2 * 86400) = 1781265600
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph

  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
  export GRAPH_FRESHNESS_DAYS=3
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781265600}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -eq 0 ]
}

@test "AC-4: check_graph_freshness exits non-zero when graph exceeds GRAPH_FRESHNESS_DAYS tolerance window" {
  # AC-4 tolerance exceeded: GRAPH_FRESHNESS_DAYS=1, end=2026-06-12 (2 days ago) → stale
  # CURRENTLY FAILS: function does not exist.
  source_validate_graph

  export OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql"
  export GRAPH_FRESHNESS_DAYS=1
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1781265600}}}'
  export STUB_CURL_EXIT=0

  run check_graph_freshness
  [ "$status" -ne 0 ]
}

@test "AC-4: validate-graph.sh plan query does NOT use hardcoded date '2025-01-15' (defect removed)" {
  # AC-4: The hardcoded 2025-01-15 date must be removed from the plan query.
  # We verify this by grepping the script source directly.
  # CURRENTLY FAILS: the hardcoded date IS present in the current script.
  run grep -c '2025-01-15' "${BATS_TEST_DIRNAME}/../validate-graph.sh"
  # grep -c returns 0 matches → exit 1 from grep → but `run` captures the status.
  # We assert the count is 0 (no occurrences of the hardcoded date).
  [ "$output" = "0" ]
}

# ===========================================================================
# AC-5 (regression): Happy path still completes — fix doesn't break existing behaviour
#
# After removing { id } and adding serviceTimeRange check:
#   - trigger_railway_redeploy still exits 0 with a valid Railway response
#   - verify_otp_router_graph_freshness still exits 0 with a fresh OTP response
#   - The "Railway redeploy triggered" log line still appears
#
# These tests are deliberately written against the POST-FIX contract.
# They are mostly GREEN today (the existing functions already handle the stub
# correctly on the success path), EXCEPT for the mutation-shape assertion
# already covered in AC-1.
#
# The one new regression guard here (AC-5d) asserts that both existing
# BL-127 contracts (non-zero on curl failure, non-zero on errors body) are
# PRESERVED after the Boolean! fix — confirming the fix is additive, not
# breaking.
# ===========================================================================

@test "AC-5 (regression): trigger_railway_redeploy still exits 0 and logs success after Boolean! fix (happy path preserved)" {
  # AC-5: Post-fix success path — Boolean! response → exit 0 + success log.
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":true}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Railway redeploy triggered"* ]]
}

@test "AC-5 (regression): trigger_railway_redeploy still exits non-zero on curl failure after Boolean! fix (BL-127 contract preserved)" {
  # AC-5: BL-127 error-propagation contract must survive the Boolean! fix.
  # curl exit 22 = HTTP 400 (the exact error the old { id } mutation causes on real Railway)
  export STUB_CURL_EXIT=22
  export STUB_CURL_RESPONSE=""

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "AC-5 (regression): trigger_railway_redeploy still exits non-zero on GraphQL errors body after Boolean! fix (BL-127 contract preserved)" {
  # AC-5: errors-body check must survive — if Railway ever returns an errors body,
  # the function must still propagate failure.
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Unauthorized"}]}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "AC-5 (regression): verify_otp_router_graph_freshness still exits 0 for fresh graph after Boolean! fix (BL-127 contract preserved)" {
  # AC-5: serviceTimeRange freshness check (BL-127) still works as before.
  # end=1798761600 = 2027-01-01 12:00 UTC, today=2026-06-14 → fresh
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1798761600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]] || [[ "$output" == *"serviceTimeRange"* ]]
}

@test "AC-5 (regression): verify_otp_router_graph_freshness still exits non-zero for stale graph after Boolean! fix (BL-127 contract preserved)" {
  # AC-5: Stale detection (BL-127) still works.
  # end=1747483200 = 2025-05-17 12:00 UTC, today=2026-06-14 → stale
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1740000000,"end":1747483200}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"STALE"* ]] || [[ "$output" == *"ERROR"* ]]
}
