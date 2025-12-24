#!/bin/bash
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
echo "Building graph (this will take 45-90 minutes)..."
java -Xmx10g -jar /opt/otp.jar --build --save "${GRAPH_DIR}"

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
