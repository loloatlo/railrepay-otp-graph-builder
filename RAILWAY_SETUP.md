# OTP Graph Builder - Railway Job Setup

## Prerequisites

1. GitHub repository created: `https://github.com/loloatlo/railrepay-otp-graph-builder`
2. Railway service created and linked to GitHub repository
3. GCS credentials (base64 encoded)
4. OSM data uploaded to `gs://railrepay-osm-prod/`
5. GTFS data in `gs://railrepay-gtfs-prod/`

## One-Time Setup (COMPLETED)

### 1. GitHub Repository Setup (DONE)

```bash
cd services/otp-graph-builder
git init
git add .
git commit -m "Initial commit: OTP graph builder service"
git branch -M main
git remote add origin https://github.com/loloatlo/railrepay-otp-graph-builder.git
git push -u origin main
```

Repository: https://github.com/loloatlo/railrepay-otp-graph-builder

### 2. Railway Service Configuration (DONE)

Environment variables configured via Railway MCP:

| Variable | Value | Description |
|----------|-------|-------------|
| `GCS_CREDENTIALS_BASE64` | `<base64 encoded JSON>` | GCS service account key (copied from otp-router) |
| `OSM_VERSION` | `great-britain-20251224.osm.pbf` | OSM file in GCS |
| `GTFS_VERSION` | `gtfs-latest.zip` | GTFS file in GCS |
| `GRAPH_BUCKET` | `railrepay-graphs-prod` | Output bucket |
| `OTP_VERSION` | `2.6.0` | OTP version |
| `JAVA_OPTS` | `-Xmx10g` | JVM memory allocation (10GB heap) |

### 3. Link Railway to GitHub (REQUIRED - MANUAL STEP)

**You must complete this step in the Railway dashboard:**

1. Go to Railway dashboard: https://railway.app
2. Navigate to project "RailRepay"
3. Select service "railrepay-otp-graph-builder"
4. Go to Settings → Source
5. Click "Connect to GitHub"
6. Select repository: `loloatlo/railrepay-otp-graph-builder`
7. Set branch: `main`
8. Enable "Auto-deploy on push to main"
9. Save changes

**Deployment Method:**
- GitHub-based deployment is MANDATORY per RailRepay SOPs
- Code changes pushed to `main` branch will auto-deploy to Railway
- Railway CLI direct upload (`railway up`) is NOT supported

### 4. Configure Resources (MANUAL STEP)

In Railway dashboard:
- **Memory:** 12 GB (REQUIRED - set in Settings → Resources)
- **CPU:** 4 cores (recommended)
- **Restart Policy:** Never (already set in railway.toml)

## Running the Graph Build

### Method 1: Push to GitHub (RECOMMENDED)

```bash
cd services/otp-graph-builder
# Make any necessary changes
git add .
git commit -m "Update graph builder configuration"
git push origin main
# Railway auto-deploys and runs the job
```

### Method 2: Manual Redeploy in Railway Dashboard

1. Go to Railway dashboard
2. Select the otp-graph-builder service
3. Click "Redeploy" to trigger a new build

### Method 3: Railway CLI Redeploy

```bash
cd services/otp-graph-builder
railway redeploy --service railrepay-otp-graph-builder
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
