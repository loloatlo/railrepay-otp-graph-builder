#!/bin/bash

# ---------------------------------------------------------------------------
# trigger_railway_redeploy()
#
# Posts a serviceInstanceRedeploy mutation to the Railway GraphQL API to
# trigger a redeploy of otp-router after a successful graph upload.
#
# Required env vars:
#   RAILWAY_API_TOKEN                  — Bearer token for Railway API
#   RAILWAY_OTP_ROUTER_SERVICE_ID      — The Railway service ID for otp-router
#   RAILWAY_OTP_ROUTER_ENVIRONMENT_ID  — The Railway environment ID (e.g., production)
#
# AC-4 (revised): Missing required vars → exit 1 (hard fail) unless
# RAILWAY_REDEPLOY_OPTIONAL=true (then log a skip notice and return 0).
# curl failure, timeout, or GraphQL errors body → exit 1 (propagated).
# ---------------------------------------------------------------------------
trigger_railway_redeploy() {
  if [ -z "${RAILWAY_API_TOKEN:-}" ]; then
    if [ "${RAILWAY_REDEPLOY_OPTIONAL:-}" = "true" ]; then
      echo "INFO: RAILWAY_API_TOKEN not set — skipping Railway redeploy (optional)"
      return 0
    fi
    echo "ERROR: RAILWAY_API_TOKEN is required but not set"
    return 1
  fi

  if [ -z "${RAILWAY_OTP_ROUTER_SERVICE_ID:-}" ]; then
    if [ "${RAILWAY_REDEPLOY_OPTIONAL:-}" = "true" ]; then
      echo "INFO: RAILWAY_OTP_ROUTER_SERVICE_ID not set — skipping Railway redeploy (optional)"
      return 0
    fi
    echo "ERROR: RAILWAY_OTP_ROUTER_SERVICE_ID is required but not set"
    return 1
  fi

  local environment_id="${RAILWAY_OTP_ROUTER_ENVIRONMENT_ID:-}"

  local query='{"query":"mutation { serviceInstanceRedeploy(serviceId: \"'"${RAILWAY_OTP_ROUTER_SERVICE_ID}"'\", environmentId: \"'"${environment_id}"'\") }"}'

  local response
  response=$(curl --silent --show-error --fail-with-body \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 3 --retry-connrefused --retry-delay 2 \
    -X POST "https://backboard.railway.app/graphql/v2" \
    -H "Authorization: Bearer ${RAILWAY_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${query}" 2>&1) || {
    local curl_exit=$?
    echo "ERROR: Railway redeploy failed — curl exited non-zero"
    echo "ERROR: curl exit code: ${curl_exit}"
    echo "ERROR: curl response: ${response}"
    return 1
  }

  # Check for GraphQL errors in the response body
  if echo "${response}" | grep -q '"errors"'; then
    echo "ERROR: Railway API returned an error response: ${response}"
    return 1
  fi

  echo "Railway redeploy triggered successfully for service ${RAILWAY_OTP_ROUTER_SERVICE_ID}"
  return 0
}

# ---------------------------------------------------------------------------
# verify_otp_router_graph_freshness()
#
# POSTs a serviceTimeRange GraphQL query to otp-router and verifies that the
# reported serviceTimeRange.end covers today.  If the graph is stale
# (frozen at a past date) the function exits non-zero so the pipeline fails
# visibly rather than silently serving outdated routing data.
#
# Required env vars:
#   OTP_ROUTER_SERVERINFO_URL — Full URL for the otp-router GraphQL endpoint
#
# Optional env vars:
#   TODAY_DATE — Override for "today" (YYYY-MM-DD).  Used by tests for
#                deterministic date comparison.  Defaults to $(date +%Y-%m-%d).
# ---------------------------------------------------------------------------
verify_otp_router_graph_freshness() {
  if [ -z "${OTP_ROUTER_SERVERINFO_URL:-}" ]; then
    echo "ERROR: OTP_ROUTER_SERVERINFO_URL is required but not set"
    return 1
  fi

  local today="${TODAY_DATE:-$(date +%Y-%m-%d)}"

  local query='{"query":"{ serviceTimeRange { start end } }"}'

  local response
  response=$(curl --silent --show-error --fail-with-body \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 3 --retry-connrefused --retry-delay 2 \
    -X POST "${OTP_ROUTER_SERVERINFO_URL}" \
    -H "Content-Type: application/json" \
    -d "${query}" 2>&1) || {
    local curl_exit=$?
    echo "ERROR: otp-router serverInfo query failed — curl exited non-zero"
    echo "ERROR: curl exit code: ${curl_exit}"
    echo "ERROR: curl response: ${response}"
    return 1
  }

  # Check for GraphQL errors in the response body
  if echo "${response}" | grep -q '"errors"'; then
    echo "ERROR: otp-router serverInfo returned GraphQL error response: ${response}"
    return 1
  fi

  # Extract the end epoch integer and convert to YYYY-MM-DD
  # Expected shape: {"data":{"serviceTimeRange":{"start":<epoch-int>,"end":<epoch-int>}}}
  # (OTP 2.x real contract — no serverInfo wrapper, epoch integers not ISO strings)
  local end_epoch
  end_epoch=$(echo "${response}" | grep -o '"end":[0-9]*' | head -1 | cut -d: -f2)
  if [ -z "${end_epoch}" ]; then
    echo "ERROR: Could not parse serviceTimeRange.end from response: ${response}"
    return 1
  fi
  local end_date
  end_date=$(date -u -d "@${end_epoch}" +%Y-%m-%d)

  # Compare dates lexicographically (YYYY-MM-DD format sorts correctly as strings)
  if [[ "${end_date}" < "${today}" ]]; then
    echo "ERROR: otp-router graph is STALE — serviceTimeRange end=${end_date} is before today=${today}"
    return 1
  fi

  echo "INFO: otp-router serviceTimeRange OK — end=${end_date} covers today=${today}"
  return 0
}

# ---------------------------------------------------------------------------
# When sourced by bats tests, stop here — do not execute the build pipeline.
# ---------------------------------------------------------------------------
if [ "${BATS_SOURCE_ONLY:-}" = "true" ]; then
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail

# Configuration
OSM_VERSION="${OSM_VERSION:?OSM_VERSION required}"
GTFS_VERSION="${GTFS_VERSION:?GTFS_VERSION required}"
OTP_VERSION="${OTP_VERSION:-2.6.0}"
GRAPH_DIR="/var/otp/graphs/default"
BUILD_DIR="/var/otp/build"
GRAPH_BUCKET="${GRAPH_BUCKET:-railrepay-graphs-prod}"
GRAPH_OUTPUT_VERSION="${GRAPH_OUTPUT_VERSION:-$(date +%Y%m%d-%H%M%S)}"

echo "=== Graph Builder ==="
echo "OSM: ${OSM_VERSION}"
echo "GTFS: ${GTFS_VERSION}"
echo "OTP: ${OTP_VERSION}"
echo "Output version: ${GRAPH_OUTPUT_VERSION}"

# Authenticate with GCS
if [ -n "${GCS_CREDENTIALS_BASE64:-}" ]; then
    echo "Configuring GCS credentials..."
    echo "${GCS_CREDENTIALS_BASE64}" | base64 -d > /tmp/gcs-key.json
    gcloud auth activate-service-account --key-file=/tmp/gcs-key.json
    rm /tmp/gcs-key.json
fi

# Create directories
mkdir -p "${GRAPH_DIR}" "${BUILD_DIR}"

# Download inputs
echo "Downloading OSM from gs://railrepay-osm-prod/${OSM_VERSION}..."
gsutil cp "gs://railrepay-osm-prod/${OSM_VERSION}" "${BUILD_DIR}/great-britain.osm.pbf"

echo "Downloading GTFS from gs://railrepay-gtfs-prod/${GTFS_VERSION}..."
gsutil cp "gs://railrepay-gtfs-prod/${GTFS_VERSION}" "${BUILD_DIR}/gtfs.zip"

# Extract service date
SERVICE_DATE=$(python3 /opt/extract-service-date.py "${BUILD_DIR}/gtfs.zip")
echo "Valid service date: ${SERVICE_DATE}"

# Copy inputs to graph directory
cp "${BUILD_DIR}/great-britain.osm.pbf" "${GRAPH_DIR}/"
cp "${BUILD_DIR}/gtfs.zip" "${GRAPH_DIR}/"

# Copy build config
cp /opt/config/build-config.json "${GRAPH_DIR}/"

# Build graph
JAVA_HEAP="${JAVA_OPTS:--Xmx10g}"
echo "Building graph with ${JAVA_HEAP} (this will take 45-90 minutes)..."
java ${JAVA_HEAP} -jar /opt/otp.jar --build --save "${GRAPH_DIR}"

# Create metadata
cat > "${GRAPH_DIR}/metadata.json" << EOF
{
  "osmVersion": "${OSM_VERSION}",
  "gtfsVersion": "${GTFS_VERSION}",
  "otpVersion": "${OTP_VERSION}",
  "buildTimestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "validServiceDate": "${SERVICE_DATE}",
  "graphVersion": "${GRAPH_OUTPUT_VERSION}"
}
EOF

echo "Graph built successfully"
echo "Metadata: $(cat ${GRAPH_DIR}/metadata.json)"

# Validate graph before upload
if [ -x /opt/validate-graph.sh ]; then
    echo "=== Running validation ==="
    /opt/validate-graph.sh "${GRAPH_DIR}" || {
        echo "ERROR: Graph validation failed"
        exit 1
    }
fi

# Upload to GCS
echo "=== Uploading graph to GCS ==="
gsutil -m cp -r "${GRAPH_DIR}/"* "gs://${GRAPH_BUCKET}/${GRAPH_OUTPUT_VERSION}/"

# Also update 'latest' pointer
gsutil -m cp -r "${GRAPH_DIR}/"* "gs://${GRAPH_BUCKET}/latest/"

echo "=== Graph build complete ==="
echo "Graph uploaded to: gs://${GRAPH_BUCKET}/${GRAPH_OUTPUT_VERSION}/"
echo "Latest pointer updated: gs://${GRAPH_BUCKET}/latest/"

# Trigger otp-router redeploy so it loads the new graph (AC-1 / AC-2)
trigger_railway_redeploy

# Verify otp-router loaded the fresh graph (AC-5)
verify_otp_router_graph_freshness
