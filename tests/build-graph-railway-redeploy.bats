#!/usr/bin/env bats
# BL-127 (TD-OTP-007): Test Specification — Railway redeploy failure propagation + serviceTimeRange gate
#
# SUPERSEDES BL-184 contract (see header below).
#
# BL-184 encoded a "resilient / never-fail" contract:
#   - curl failure        → return 0  (logged but swallowed)
#   - GraphQL error body  → return 0  (logged but swallowed)
#   - timeout             → return 0  (logged but swallowed)
#   - missing env vars    → return 0  (silent skip)
#
# BL-127 REPLACES that contract. The 2026-06-04 incident proved that a
# swallowed redeploy failure is worse than a visible build failure: otp-router
# kept serving a graph frozen at 2026-05-20, forward-dated tickets were
# unroutable, and the pipeline reported SUCCESS. The new contract is:
#
#   AC-2 (revised): On credentials-present + redeploy success → exit 0 + log
#                   "Railway redeploy triggered".  SUCCESS PATH PRESERVED.
#   AC-4 (new):     PROPAGATE non-zero on (a) curl/network failure,
#                   (b) GraphQL error body, (c) timeout.
#                   MISSING REQUIRED VARS → exit 1 unless
#                   RAILWAY_REDEPLOY_OPTIONAL=true (then silent skip + exit 0).
#   AC-5 (new):     POST-REDEPLOY GATE: after triggering the redeploy, poll
#                   otp-router's serviceTimeRange GraphQL field (OTP 2.x real
#                   contract — epoch integers, NO serverInfo wrapper) and assert
#                   the reported end epoch covers today.  If stale within the
#                   poll window → exit non-zero.
#
# DESIGN DECISION (Jessie, TD-1, 2026-06-06) — missing-required-var contract:
#   In a cron context, silent skip on missing creds caused the June incident.
#   Missing vars are now a hard failure UNLESS the caller sets
#   RAILWAY_REDEPLOY_OPTIONAL=true to explicitly opt into graceful skip.
#   This preserves the original optional-deploy use case while making the
#   default safe for production cron runs.
#
# Requirements:
#   - bats-core >= 1.10.0  (https://github.com/bats-core/bats-core)
#   - build-graph.sh must expose trigger_railway_redeploy() and
#     verify_otp_router_graph_freshness() when sourced with BATS_SOURCE_ONLY=true
#
# Run: bats tests/build-graph-railway-redeploy.bats

setup() {
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../build-graph.sh"

  # Default curl stub: success
  curl() {
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  # Default date stub: returns a fixed "today" so AC-5 tests are deterministic
  # Override STUB_TODAY to control what date the script considers "today"
  TODAY_DATE="${STUB_TODAY:-2026-06-06}"
  export TODAY_DATE
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
}

# ---------------------------------------------------------------------------
# AC-2 (revised): Success path — credentials present + redeploy succeeds
# ---------------------------------------------------------------------------
# AC-2: On credentials-present + redeploy success, exit 0 and log "Railway redeploy triggered"

@test "AC-2: trigger_railway_redeploy function is declared in build-graph.sh" {
  # The function must exist so blake cannot skip the implementation
  declare -f trigger_railway_redeploy > /dev/null
}

@test "AC-2: trigger_railway_redeploy sends POST to Railway GraphQL API when credentials present" {
  # AC-2: success path — all three env vars set, curl returns a deploymentId body
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":{"id":"dep-xyz"}}}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Railway redeploy triggered"* ]]
}

# ---------------------------------------------------------------------------
# AC-4: Failure PROPAGATION — failures must NOT be swallowed (BL-184 contract removed)
# ---------------------------------------------------------------------------
# AC-4(a): curl/network failure → non-zero exit (no longer return 0)

@test "AC-4(a): trigger_railway_redeploy exits non-zero when curl command fails (network error)" {
  # Replaces BL-184 test "returns exit 0 when curl command fails (network error)"
  # curl exit 7 = connection refused
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_EXIT=7
  export STUB_CURL_RESPONSE=""

  run trigger_railway_redeploy
  # MUST NOT return 0 — failure must propagate so Railway marks the build failed
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "AC-4(a): trigger_railway_redeploy exits non-zero on curl timeout (exit 28)" {
  # Replaces BL-184 test "logs error but does not propagate failure upward"
  # curl exit 28 = operation timeout
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_EXIT=28
  export STUB_CURL_RESPONSE=""

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

# AC-4(b): GraphQL error body → non-zero exit (no longer return 0)

@test "AC-4(b): trigger_railway_redeploy exits non-zero when Railway API returns HTTP 401 (errors body)" {
  # Replaces BL-184 test "returns exit 0 when Railway API returns HTTP 401"
  export RAILWAY_API_TOKEN="invalid-token"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Unauthorized"}]}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "AC-4(b): trigger_railway_redeploy exits non-zero when Railway API returns HTTP 500 (errors body)" {
  # Replaces BL-184 test "returns exit 0 when Railway API returns HTTP 500"
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Internal Server Error"}]}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

# AC-4 — missing required vars: FAIL unless RAILWAY_REDEPLOY_OPTIONAL=true
# Design decision: default is hard-fail; optional skip requires explicit opt-in.

@test "AC-4: trigger_railway_redeploy exits non-zero when RAILWAY_API_TOKEN is absent (cron default)" {
  # Replaces BL-184 "no-op and exits 0" behaviour for the default (non-optional) case
  unset RAILWAY_API_TOKEN
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  unset RAILWAY_REDEPLOY_OPTIONAL

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"RAILWAY_API_TOKEN"* ]]
}

@test "AC-4: trigger_railway_redeploy exits non-zero when RAILWAY_OTP_ROUTER_SERVICE_ID is absent (cron default)" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  unset RAILWAY_OTP_ROUTER_SERVICE_ID
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  unset RAILWAY_REDEPLOY_OPTIONAL

  run trigger_railway_redeploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"RAILWAY_OTP_ROUTER_SERVICE_ID"* ]]
}

@test "AC-4: trigger_railway_redeploy exits 0 and skips when RAILWAY_API_TOKEN absent AND RAILWAY_REDEPLOY_OPTIONAL=true" {
  # Graceful skip path preserved — caller must explicitly opt in
  unset RAILWAY_API_TOKEN
  export RAILWAY_OTP_ROUTER_SERVICE_ID="svc-111aaa"
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export RAILWAY_REDEPLOY_OPTIONAL=true

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  # Must log a skip notice (not silently vanish)
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"SKIP"* ]] || [[ "$output" == *"optional"* ]]
}

@test "AC-4: trigger_railway_redeploy exits 0 and skips when RAILWAY_OTP_ROUTER_SERVICE_ID absent AND RAILWAY_REDEPLOY_OPTIONAL=true" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  unset RAILWAY_OTP_ROUTER_SERVICE_ID
  export RAILWAY_OTP_ROUTER_ENVIRONMENT_ID="env-222bbb"
  export RAILWAY_REDEPLOY_OPTIONAL=true

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"SKIP"* ]] || [[ "$output" == *"optional"* ]]
}

# ---------------------------------------------------------------------------
# AC-5: Post-redeploy serviceTimeRange gate
#
# After triggering the redeploy, verify_otp_router_graph_freshness() polls the
# otp-router GraphQL endpoint and asserts the reported serviceTimeRange.end
# covers today.  If the range is stale (frozen at a past date) the function
# exits non-zero so the build is marked failed.
#
# *** REAL OTP 2.x CONTRACT (corrected 2026-06-06, TD-OTP-007 re-opened TD-1)
#
#   PRIOR stub (WRONG — fabricated, never matched live API):
#     query:    { serverInfo { transitServiceTimeRange { start end } } }
#     response: {"data":{"serverInfo":{"transitServiceTimeRange":{"start":"YYYY-MM-DD","end":"YYYY-MM-DD"}}}}
#
#   CORRECT OTP 2.x contract (verified against live
#     https://railrepay-otp-router-production.up.railway.app/otp/routers/default/index/graphql):
#     query:    { serviceTimeRange { start end } }    ← top-level field, NO serverInfo wrapper
#     response: {"data":{"serviceTimeRange":{"start":<epoch-int>,"end":<epoch-int>}}}
#                                                      ← Unix epoch seconds, NOT ISO strings
#
#   Querying "serverInfo" against the live OTP 2.x router returns:
#     {"errors":[{"message":"FieldUndefined@[serverInfo]"}]}
#
#   Real live stale baseline (2026-06-04 incident): end = 1779231600 = 2026-05-20 UTC
#   The tests below reproduce this exact production bug so they encode a
#   faithful regression guard.
#
# Epoch values used in tests (all UTC):
#   Fresh  : 1782860400 → 2026-07-01  (end > today 2026-06-06 → exit 0)
#   Stale  : 1779231600 → 2026-05-20  (REAL production stale value; end < today → exit 1)
#   Boundary: 1780700400 → 2026-06-06 (end == today exactly → exit 0)
#
# Epoch conversion the implementation must use (POSIX date):
#   end_date=$(date -u -d "@${end_epoch}" +%Y-%m-%d)
# then compare end_date lexicographically against TODAY_DATE (YYYY-MM-DD).
#
# Stub strategy: reuse the curl stub; set STUB_CURL_RESPONSE to the correct
# epoch-integer shape.  OTP_ROUTER_SERVERINFO_URL is still the poll target.
# ---------------------------------------------------------------------------
# AC-5: function is declared

@test "AC-5: verify_otp_router_graph_freshness function is declared in build-graph.sh" {
  declare -f verify_otp_router_graph_freshness > /dev/null
}

# AC-5: verify the script POSTs the correct OTP 2.x query (serviceTimeRange, NOT serverInfo)

@test "AC-5: verify_otp_router_graph_freshness queries serviceTimeRange (not serverInfo) and does not reference transitServiceTimeRange" {
  # The script must POST a body containing "serviceTimeRange" at the top level of the selection set.
  # It must NOT contain "serverInfo" or "transitServiceTimeRange" — those fields do not exist in
  # the live OTP 2.x router and return FieldUndefined errors.
  #
  # Strategy: capture what curl receives by overriding curl to record its arguments, then
  # assert the -d argument contains "serviceTimeRange" and does not contain "serverInfo".
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  # Return a valid fresh response so the function reaches the query-dispatch code
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1776000000,"end":1782860400}}}'
  export STUB_CURL_EXIT=0

  # Override curl to capture the -d payload into CAPTURED_CURL_BODY
  CAPTURED_CURL_BODY_FILE=$(mktemp)
  curl() {
    local prev=""
    for arg in "$@"; do
      if [ "$prev" = "-d" ]; then
        echo "$arg" > "${CAPTURED_CURL_BODY_FILE}"
      fi
      prev="$arg"
    done
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl

  run verify_otp_router_graph_freshness

  local body
  body=$(cat "${CAPTURED_CURL_BODY_FILE}" 2>/dev/null || echo "")
  rm -f "${CAPTURED_CURL_BODY_FILE}"

  # Must reference the real OTP 2.x field
  [[ "$body" == *"serviceTimeRange"* ]]
  # Must NOT reference the non-existent OTP 2.x fields
  [[ "$body" != *"serverInfo"* ]]
  [[ "$body" != *"transitServiceTimeRange"* ]]
}

# AC-5: today falls within serviceTimeRange (epoch end > today) → exit 0

@test "AC-5: verify_otp_router_graph_freshness exits 0 when serviceTimeRange end epoch covers today (fresh graph)" {
  # TODAY_DATE = 2026-06-06 (set in setup)
  # end epoch 1782860400 = 2026-07-01 UTC — after today → fresh
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1764547200,"end":1782860400}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"serviceTimeRange"* ]] || [[ "$output" == *"fresh"* ]] || [[ "$output" == *"OK"* ]]
}

# AC-5: range end epoch is before today (stale graph — reproduces the 2026-06-04 production incident)

@test "AC-5: verify_otp_router_graph_freshness exits non-zero when serviceTimeRange end epoch is before today (stale graph)" {
  # TODAY_DATE = 2026-06-06
  # end epoch 1779231600 = 2026-05-20 UTC — REAL production stale baseline from the incident.
  # This is the exact value that caused otp-router to serve outdated routing data for 18 days.
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1764547200,"end":1779231600}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"STALE"* ]] || [[ "$output" == *"ERROR"* ]]
}

# AC-5: end epoch equals today exactly → pass (boundary case, not stale)

@test "AC-5: verify_otp_router_graph_freshness exits 0 when serviceTimeRange end epoch equals today (boundary)" {
  # end epoch 1780700400 = 2026-06-06 UTC — exactly today, acceptable (not stale)
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"data":{"serviceTimeRange":{"start":1764547200,"end":1780700400}}}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -eq 0 ]
}

# AC-5: otp-router unreachable after redeploy (curl failure) → non-zero exit with clear error

@test "AC-5: verify_otp_router_graph_freshness exits non-zero when otp-router is unreachable (curl exit 7)" {
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export STUB_CURL_EXIT=7
  export STUB_CURL_RESPONSE=""

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"unreachable"* ]] || [[ "$output" == *"failed"* ]]
}

# AC-5: OTP 2.x FieldUndefined error (simulates what the live router returns when queried with the
# WRONG serverInfo shape — real error seen by Moykle during TD-4 deploy verification)

@test "AC-5: verify_otp_router_graph_freshness exits non-zero when OTP returns FieldUndefined GraphQL error (wrong query)" {
  # Real error body returned by live OTP 2.x router when queried with the old serverInfo shape.
  # This test would have caught the contract mismatch before deploy.
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"errors":[{"message":"FieldUndefined@[serverInfo]"}]}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"error"* ]]
}

# AC-5: generic GraphQL errors body (OTP startup still in progress) → non-zero

@test "AC-5: verify_otp_router_graph_freshness exits non-zero when serviceTimeRange returns GraphQL errors (OTP loading)" {
  export OTP_ROUTER_SERVERINFO_URL="http://otp-router.internal:8080/otp/routers/default/index/graphql"
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Graph is loading"}]}'
  export STUB_CURL_EXIT=0

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"error"* ]]
}

# AC-5: OTP_ROUTER_SERVERINFO_URL not set → exit non-zero (cannot verify freshness without target)

@test "AC-5: verify_otp_router_graph_freshness exits non-zero when OTP_ROUTER_SERVERINFO_URL is not set" {
  unset OTP_ROUTER_SERVERINFO_URL

  run verify_otp_router_graph_freshness
  [ "$status" -ne 0 ]
  [[ "$output" == *"OTP_ROUTER_SERVERINFO_URL"* ]]
}
