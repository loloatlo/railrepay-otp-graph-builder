#!/bin/bash

# ---------------------------------------------------------------------------
# check_graph_freshness()
#
# Queries the OTP GraphQL endpoint for serviceTimeRange and verifies that
# the graph's end epoch covers today (within a configurable tolerance window).
#
# Required env vars:
#   OTP_VALIDATION_URL — Full URL for the OTP GraphQL endpoint.
#                        If not set, falls back to constructing from
#                        VALIDATION_PORT (default 8080).
#
# Optional env vars:
#   TODAY_DATE           — Override for "today" (YYYY-MM-DD). Defaults to
#                          $(date +%Y-%m-%d). Used by tests for deterministic
#                          date comparisons.
#   GRAPH_FRESHNESS_DAYS — Tolerance window in days (default 0).
#                          A graph ending this many days before today is still
#                          considered fresh.
#                          end_date >= (today - GRAPH_FRESHNESS_DAYS) → exit 0
#                          end_date <  (today - GRAPH_FRESHNESS_DAYS) → exit 1
# ---------------------------------------------------------------------------
check_graph_freshness() {
  local validation_url="${OTP_VALIDATION_URL:-http://localhost:${VALIDATION_PORT:-8080}/otp/routers/default/index/graphql}"

  local today="${TODAY_DATE:-$(date +%Y-%m-%d)}"
  local freshness_days="${GRAPH_FRESHNESS_DAYS:-0}"

  # Compute threshold date: today - GRAPH_FRESHNESS_DAYS
  local threshold_date
  if [ "${freshness_days}" -eq 0 ]; then
    threshold_date="${today}"
  else
    threshold_date=$(date -u -d "${today} - ${freshness_days} days" +%Y-%m-%d)
  fi

  local query='{"query":"{ serviceTimeRange { start end } }"}'

  local response
  response=$(curl --silent --show-error \
    -X POST "${validation_url}" \
    -H "Content-Type: application/json" \
    -d "${query}" 2>&1) || {
    local curl_exit=$?
    echo "ERROR: OTP serviceTimeRange query failed — curl exited non-zero (exit ${curl_exit})"
    echo "ERROR: curl response: ${response}"
    return 1
  }

  # Check for GraphQL errors in the response body
  if echo "${response}" | grep -q '"errors"'; then
    echo "ERROR: OTP serviceTimeRange returned GraphQL error: ${response}"
    return 1
  fi

  # Extract the end epoch integer and convert to YYYY-MM-DD (UTC)
  local end_epoch
  end_epoch=$(echo "${response}" | grep -o '"end":[0-9]*' | head -1 | cut -d: -f2)
  if [ -z "${end_epoch}" ]; then
    echo "ERROR: Could not parse serviceTimeRange.end from response: ${response}"
    return 1
  fi

  local end_date
  end_date=$(date -u -d "@${end_epoch}" +%Y-%m-%d)

  # Compare lexicographically (YYYY-MM-DD sorts correctly as strings)
  if [[ "${end_date}" < "${threshold_date}" ]]; then
    echo "ERROR: Graph is STALE — serviceTimeRange end=${end_date} is before threshold=${threshold_date} (today=${today}, GRAPH_FRESHNESS_DAYS=${freshness_days})"
    return 1
  fi

  echo "INFO: Graph freshness OK — serviceTimeRange end=${end_date} covers threshold=${threshold_date} (today=${today})"
  return 0
}

# ---------------------------------------------------------------------------
# When sourced by bats tests, stop here — do not execute the validation pipeline.
# ---------------------------------------------------------------------------
if [ "${BATS_SOURCE_ONLY:-}" = "true" ]; then
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail

GRAPH_DIR="${1:-/var/otp/graphs/default}"
OTP_JAR="${2:-/opt/otp.jar}"
VALIDATION_PORT="${VALIDATION_PORT:-8080}"

echo "=== Graph Validation ==="
echo "Graph directory: ${GRAPH_DIR}"

# Check graph file exists
if [ ! -f "${GRAPH_DIR}/graph.obj" ]; then
    echo "ERROR: graph.obj not found in ${GRAPH_DIR}"
    exit 1
fi

# Check metadata exists
if [ ! -f "${GRAPH_DIR}/metadata.json" ]; then
    echo "ERROR: metadata.json not found in ${GRAPH_DIR}"
    exit 1
fi

# Display metadata
echo "Metadata:"
cat "${GRAPH_DIR}/metadata.json"

# Start OTP in background for validation
VALIDATION_HEAP="${JAVA_OPTS:--Xmx16g}"
echo "Starting OTP server for validation with ${VALIDATION_HEAP}..."
java ${VALIDATION_HEAP} -jar "${OTP_JAR}" --load "${GRAPH_DIR}" --port "${VALIDATION_PORT}" &
OTP_PID=$!

# Wait for OTP to be ready by checking if GraphQL endpoint responds
echo "Waiting for OTP to start..."
MAX_WAIT=600
WAITED=0
# Use 'agencies' query - available in GTFS GraphQL API (serverInfo is Transmodel-only)
HEALTH_QUERY='{"query":"{ agencies { name } }"}'
while true; do
    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$HEALTH_QUERY" \
        "http://127.0.0.1:${VALIDATION_PORT}/otp/routers/default/index/graphql" 2>/dev/null || echo "")

    if echo "$RESPONSE" | grep -q "agencies"; then
        break
    fi

    sleep 2
    WAITED=$((WAITED + 2))
    if [ $WAITED -gt $MAX_WAIT ]; then
        echo "ERROR: OTP did not start within ${MAX_WAIT} seconds"
        kill $OTP_PID 2>/dev/null || true
        exit 1
    fi

    # Show progress every 30 seconds
    if [ $((WAITED % 30)) -eq 0 ]; then
        echo "Still waiting for OTP... (${WAITED}s elapsed)"
    fi
done

echo "OTP started successfully"
echo "GraphQL response: $RESPONSE"

# Test 2: stopsByRadius query (verify transit data)
echo "Test 2: stopsByRadius query (verify transit data loaded)..."
STOPS_QUERY='{"query":"{ stopsByRadius(lat:51.481, lon:-3.179, radius:1000) { edges { node { stop { gtfsId name } } } } }"}'
STOPS_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$STOPS_QUERY" \
    "http://localhost:${VALIDATION_PORT}/otp/routers/default/index/graphql")

if echo "$STOPS_RESPONSE" | grep -q "gtfsId"; then
    STOP_COUNT=$(echo "$STOPS_RESPONSE" | grep -o "gtfsId" | wc -l)
    echo "✓ Transit data loaded: Found ${STOP_COUNT} stops near Cardiff"
else
    echo "✗ Transit data not loaded: $STOPS_RESPONSE"
    kill $OTP_PID
    exit 1
fi

# Test 3: Coordinate routing (verify OSM data)
echo "Test 3: Coordinate routing (verify OSM data loaded)..."
PLAN_DATE="$(date +%Y-%m-%d)"
PLAN_QUERY='{"query":"{ plan(from:{lat:51.481,lon:-3.179}, to:{lat:51.621,lon:-3.944}, date:\"'"${PLAN_DATE}"'\", time:\"09:00:00\") { itineraries { legs { mode startTime } } } }"}'
PLAN_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$PLAN_QUERY" \
    "http://localhost:${VALIDATION_PORT}/otp/routers/default/index/graphql")

if echo "$PLAN_RESPONSE" | grep -q "LOCATION_NOT_FOUND"; then
    echo "✗ OSM data not loaded: Coordinate routing failed with LOCATION_NOT_FOUND"
    echo "Response: $PLAN_RESPONSE"
    kill $OTP_PID
    exit 1
elif echo "$PLAN_RESPONSE" | grep -q "itineraries"; then
    echo "✓ OSM data loaded: Coordinate routing successful"
else
    echo "⚠ Routing response unclear: $PLAN_RESPONSE"
fi

# Test 4: Graph freshness check (verify serviceTimeRange covers today)
echo "Test 4: Graph freshness check (serviceTimeRange covers today)..."
OTP_VALIDATION_URL="http://localhost:${VALIDATION_PORT}/otp/routers/default/index/graphql"
export OTP_VALIDATION_URL
check_graph_freshness || {
    kill $OTP_PID
    exit 1
}

# Cleanup
kill $OTP_PID

echo "=== Validation Complete ==="
echo "✓ Graph is valid and ready for deployment"
exit 0
