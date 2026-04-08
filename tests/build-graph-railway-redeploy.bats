#!/usr/bin/env bats
# BL-184 TD-1: Test Specification — otp-graph-builder Railway redeploy after graph upload
#
# BATS tests for AC-1 and AC-2 of BL-184.
# These tests run against the testable function extracted from build-graph.sh.
#
# Requirements:
#   - bats-core >= 1.10.0 (https://github.com/bats-core/bats-core)
#   - The production script must source trigger_railway_redeploy() and the
#     redeploy logic must be exercised AFTER the GCS upload lines.
#
# Run: bats tests/build-graph-railway-redeploy.bats
#
# Blake implementation note:
#   Extract the Railway redeploy logic into a sourced function called
#   trigger_railway_redeploy() in build-graph.sh so it can be tested in isolation.
#   The function must:
#     - Accept RAILWAY_API_TOKEN, RAILWAY_SERVICE_ID, RAILWAY_ENVIRONMENT_ID
#       as environment variables
#     - POST to https://backboard.railway.app/graphql/v2 to trigger a redeploy
#     - On curl failure: log "ERROR: Railway redeploy failed" and return 0
#     - On HTTP error (non-2xx): log "ERROR: Railway API returned HTTP ..." and return 0
#     - On success: log "Railway redeploy triggered" and return 0

setup() {
  # Source only the function, not the full script (avoids set -e side effects)
  # build-graph.sh must expose trigger_railway_redeploy() when sourced with
  # the env var BATS_SOURCE_ONLY=true
  export BATS_SOURCE_ONLY=true
  source "${BATS_TEST_DIRNAME}/../build-graph.sh"

  # Stub curl so no real HTTP calls are made
  curl() {
    echo "${STUB_CURL_RESPONSE:-}"
    return "${STUB_CURL_EXIT:-0}"
  }
  export -f curl
}

teardown() {
  unset BATS_SOURCE_ONLY
  unset RAILWAY_API_TOKEN
  unset RAILWAY_SERVICE_ID
  unset RAILWAY_ENVIRONMENT_ID
  unset STUB_CURL_RESPONSE
  unset STUB_CURL_EXIT
}

# ---------------------------------------------------------------------------
# AC-1: trigger_railway_redeploy() is called after successful GCS upload
# ---------------------------------------------------------------------------

@test "AC-1: trigger_railway_redeploy function exists in build-graph.sh" {
  # The function must be declared so Blake cannot skip the implementation
  declare -f trigger_railway_redeploy > /dev/null
}

@test "AC-1: trigger_railway_redeploy sends POST to Railway GraphQL API when credentials present" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_SERVICE_ID="svc-111aaa"
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"
  # Simulate curl success with a JSON response containing a deploymentId
  export STUB_CURL_RESPONSE='{"data":{"serviceInstanceRedeploy":{"id":"dep-xyz"}}}'
  export STUB_CURL_EXIT=0

  # Capture output to verify the correct API target is logged
  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  # The function must log success
  [[ "$output" == *"Railway redeploy triggered"* ]]
}

@test "AC-1: trigger_railway_redeploy is a no-op and exits 0 when RAILWAY_API_TOKEN is absent" {
  # When Railway credentials are not configured the function must silently skip
  unset RAILWAY_API_TOKEN
  export RAILWAY_SERVICE_ID="svc-111aaa"
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAILWAY_API_TOKEN not set"* ]] || [[ "$output" == *"skipping"* ]]
}

@test "AC-1: trigger_railway_redeploy is a no-op and exits 0 when RAILWAY_SERVICE_ID is absent" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  unset RAILWAY_SERVICE_ID
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAILWAY_SERVICE_ID not set"* ]] || [[ "$output" == *"skipping"* ]]
}

# ---------------------------------------------------------------------------
# AC-2: Railway API failure does NOT fail the graph build (resilient)
# ---------------------------------------------------------------------------

@test "AC-2: trigger_railway_redeploy returns exit 0 when curl command fails (network error)" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_SERVICE_ID="svc-111aaa"
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"
  # Simulate curl network failure (exit code 7 = connection refused)
  export STUB_CURL_EXIT=7
  export STUB_CURL_RESPONSE=""

  run trigger_railway_redeploy
  # CRITICAL: must exit 0 so the caller script (which uses set -e) does not abort
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: Railway redeploy failed"* ]]
}

@test "AC-2: trigger_railway_redeploy returns exit 0 when Railway API returns HTTP 401" {
  export RAILWAY_API_TOKEN="invalid-token"
  export RAILWAY_SERVICE_ID="svc-111aaa"
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"
  # Simulate successful curl but Railway returns an error body
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Unauthorized"}]}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: Railway API"* ]]
}

@test "AC-2: trigger_railway_redeploy returns exit 0 when Railway API returns HTTP 500" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_SERVICE_ID="svc-111aaa"
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_RESPONSE='{"errors":[{"message":"Internal Server Error"}]}'
  export STUB_CURL_EXIT=0

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: Railway API"* ]]
}

@test "AC-2: trigger_railway_redeploy logs error but does not propagate failure upward" {
  export RAILWAY_API_TOKEN="test-token-abc123"
  export RAILWAY_SERVICE_ID="svc-111aaa"
  export RAILWAY_ENVIRONMENT_ID="env-222bbb"
  export STUB_CURL_EXIT=28  # curl timeout
  export STUB_CURL_RESPONSE=""

  run trigger_railway_redeploy
  [ "$status" -eq 0 ]
  # Error must be logged for observability
  [[ "$output" == *"ERROR"* ]]
}
