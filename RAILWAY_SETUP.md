# OTP Graph Builder - Railway Job Setup

## Prerequisites

1. Railway CLI installed and logged in
2. GCS credentials (base64 encoded)
3. OSM data uploaded to `gs://railrepay-osm-prod/`
4. GTFS data in `gs://railrepay-gtfs-prod/`

## One-Time Setup

### 1. Create the Graph Builder Service in Railway

```bash
cd services/otp-graph-builder
railway link
railway up
```

### 2. Configure Environment Variables

In Railway dashboard, set:

| Variable | Value | Description |
|----------|-------|-------------|
| `GCS_CREDENTIALS_BASE64` | `<base64 encoded JSON>` | GCS service account key |
| `OSM_VERSION` | `great-britain-20251222.osm.pbf` | OSM file in GCS |
| `GTFS_VERSION` | `gtfs-latest.zip` | GTFS file in GCS |
| `GRAPH_BUCKET` | `railrepay-graphs-prod` | Output bucket |
| `OTP_VERSION` | `2.6.0` | OTP version |

### 3. Configure Resources

In Railway dashboard:
- **Memory:** 12 GB (required for graph build)
- **CPU:** 4 cores (recommended)

## Running the Graph Build

### Option A: Railway Dashboard

1. Go to Railway dashboard
2. Select the otp-graph-builder service
3. Click "Redeploy" to trigger a new build

### Option B: Railway CLI

```bash
railway run --service otp-graph-builder
```

### Option C: Trigger via API

```bash
curl -X POST "https://backboard.railway.app/graphql/v2" \
  -H "Authorization: Bearer $RAILWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { serviceInstanceRedeploy(serviceId: \"<SERVICE_ID>\") { id } }"}'
```

## Build Duration

- **Expected:** 45-90 minutes
- **Memory peak:** ~10 GB during street graph processing
- **Output:** ~2-3 GB graph files

## Monitoring

Watch logs in Railway dashboard or:
```bash
railway logs --service otp-graph-builder -f
```

## Output

After successful build:
- Graph files uploaded to `gs://railrepay-graphs-prod/<timestamp>/`
- Latest pointer updated at `gs://railrepay-graphs-prod/latest/`
- Metadata available at `gs://railrepay-graphs-prod/latest/metadata.json`

## Updating otp-router

After graph build completes:
1. Set `GRAPH_VERSION=latest` on otp-router (or specific timestamp)
2. Redeploy otp-router to load new graph

## Troubleshooting

### Build Fails During Download

Check:
- GCS credentials are valid and base64 encoded
- OSM_VERSION and GTFS_VERSION match files in GCS buckets
- Service account has read access to input buckets

### Out of Memory

Increase memory allocation in Railway dashboard:
- Go to service settings
- Increase memory to 14-16 GB if needed

### Build Timeout

Railway jobs have a maximum runtime. If the build times out:
- Check OSM file size (should be <2 GB for Great Britain)
- Verify CPU allocation is sufficient
- Consider increasing timeout in Railway settings

### Upload Fails

Check:
- Service account has write access to `railrepay-graphs-prod` bucket
- Network connectivity to GCS
- Available disk space in container
