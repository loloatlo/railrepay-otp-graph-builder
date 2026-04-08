#!/bin/bash

# ---------------------------------------------------------------------------
# trigger_railway_redeploy()
#
# Posts a serviceInstanceRedeploy mutation to the Railway GraphQL API to
# trigger a redeploy of otp-router after a successful graph upload.
#
# Required env vars:
#   RAILWAY_API_TOKEN          — Bearer token for Railway API
#   RAILWAY_SERVICE_ID         — The Railway service ID for otp-router
#   RAILWAY_ENVIRONMENT_ID     — The Railway environment ID (e.g., production)
#
# AC-2: Any failure (network or HTTP error) is logged but exits 0 so the
# graph build pipeline (which uses set -e) is never aborted.
# ---------------------------------------------------------------------------
trigger_railway_redeploy() {
  if [ -z "${RAILWAY_API_TOKEN:-}" ]; then
    echo "WARNING: RAILWAY_API_TOKEN not set — skipping Railway redeploy"
    return 0
  fi

  if [ -z "${RAILWAY_SERVICE_ID:-}" ]; then
    echo "WARNING: RAILWAY_SERVICE_ID not set — skipping Railway redeploy"
    return 0
  fi

  local environment_id="${RAILWAY_ENVIRONMENT_ID:-}"

  local query='{"query":"mutation { serviceInstanceRedeploy(serviceId: \"'"${RAILWAY_SERVICE_ID}"'\", environmentId: \"'"${environment_id}"'\") { id } }"}'

  local response
  response=$(curl --silent --show-error --fail-with-body \
    --max-time 30 \
    -X POST "https://backboard.railway.app/graphql/v2" \
    -H "Authorization: Bearer ${RAILWAY_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${query}" 2>&1) || {
    echo "ERROR: Railway redeploy failed — curl exited non-zero"
    return 0
  }

  # Check for GraphQL errors in the response body
  if echo "${response}" | grep -q '"errors"'; then
    echo "ERROR: Railway API returned an error response: ${response}"
    return 0
  fi

  echo "Railway redeploy triggered successfully for service ${RAILWAY_SERVICE_ID}"
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
