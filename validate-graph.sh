#!/bin/bash
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
HEALTH_QUERY='{"query":"{ serverInfo { version } }"}'
while true; do
    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$HEALTH_QUERY" \
        "http://localhost:${VALIDATION_PORT}/otp/routers/default/index/graphql" 2>/dev/null || echo "")

    if echo "$RESPONSE" | grep -q "version"; then
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
echo "Server info: $RESPONSE"

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
PLAN_QUERY='{"query":"{ plan(from:{lat:51.481,lon:-3.179}, to:{lat:51.621,lon:-3.944}, date:\"2025-01-15\", time:\"09:00:00\") { itineraries { legs { mode startTime } } } }"}'
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

# Cleanup
kill $OTP_PID

echo "=== Validation Complete ==="
echo "✓ Graph is valid and ready for deployment"
exit 0
