# OTP Graph Builder - Deployment Summary

## Deployment Status: READY (Manual Step Required)

### Completed Steps

1. **GitHub Repository**
   - Repository created: https://github.com/loloatlo/railrepay-otp-graph-builder
   - Code pushed to `main` branch
   - Commit: Initial commit with all graph builder scripts
   - Remote configured: `origin -> https://github.com/loloatlo/railrepay-otp-graph-builder.git`

2. **Railway Environment Variables**
   - All required variables configured via Railway MCP
   - GCS credentials copied from otp-router service
   - OSM version set to: `great-britain-20251224.osm.pbf`
   - GTFS version set to: `gtfs-latest.zip`
   - Graph output bucket: `railrepay-graphs-prod`
   - Java heap: 10GB (`-Xmx10g`)

3. **Service Configuration**
   - Service name: `railrepay-otp-graph-builder`
   - Project: RailRepay
   - Environment: production
   - Restart policy: never (one-off job)
   - Dockerfile: `Dockerfile.builder`

### Required Manual Steps

**CRITICAL: You must complete these steps before the service can deploy:**

#### Step 1: Link Railway Service to GitHub

1. Open Railway dashboard: https://railway.app
2. Navigate to: RailRepay → railrepay-otp-graph-builder
3. Click Settings → Source
4. Click "Connect to GitHub"
5. Select repository: `loloatlo/railrepay-otp-graph-builder`
6. Branch: `main`
7. Enable "Auto-deploy on push to main"
8. Save

#### Step 2: Configure Service Resources

1. In Railway dashboard, go to: railrepay-otp-graph-builder → Settings → Resources
2. Set Memory: **12 GB** (minimum required for graph build)
3. Set CPU: 4 cores (recommended)
4. Save changes

#### Step 3: Verify Environment Variables

In Railway dashboard, confirm these variables are set:
- `GCS_CREDENTIALS_BASE64` (should be present)
- `OSM_VERSION=great-britain-20251224.osm.pbf`
- `GTFS_VERSION=gtfs-latest.zip`
- `GRAPH_BUCKET=railrepay-graphs-prod`
- `OTP_VERSION=2.6.0`
- `JAVA_OPTS=-Xmx10g`

### Deployment Architecture

```
GitHub Repository (loloatlo/railrepay-otp-graph-builder)
    ↓ (push to main)
Railway Auto-Deploy
    ↓
Build Docker Image (Dockerfile.builder)
    ↓
Run Graph Build Job (build-graph.sh)
    ↓
    ├─ Download OSM from gs://railrepay-osm-prod/
    ├─ Download GTFS from gs://railrepay-gtfs-prod/
    ├─ Build OTP graph (45-90 minutes)
    ├─ Validate graph (validate-graph.sh)
    └─ Upload to gs://railrepay-graphs-prod/<timestamp>/
    ↓
Job completes, container exits (restart policy: never)
```

### Build Process

**Duration:** 45-90 minutes
**Memory Usage:** Up to 10GB RAM during street graph processing
**Output:** 2-3GB graph files in GCS

**Input Files:**
- OSM: `gs://railrepay-osm-prod/great-britain-20251224.osm.pbf` (~1.8GB)
- GTFS: `gs://railrepay-gtfs-prod/gtfs-latest.zip`

**Output Location:**
- `gs://railrepay-graphs-prod/<timestamp>/Graph.obj`
- `gs://railrepay-graphs-prod/<timestamp>/streetGraph.obj`
- `gs://railrepay-graphs-prod/latest/` (symlink)
- `gs://railrepay-graphs-prod/latest/metadata.json`

### How to Trigger a Build

Once Railway is linked to GitHub, you can trigger builds in three ways:

**Method 1: Push to GitHub (Recommended)**
```bash
cd /mnt/c/Users/nicbo/Documents/RailRepay\ MVP/services/otp-graph-builder
# Make changes (e.g., update OSM_VERSION)
git add .
git commit -m "Update OSM version"
git push origin main
# Railway auto-deploys and runs the job
```

**Method 2: Manual Redeploy in Railway Dashboard**
1. Go to Railway dashboard
2. Select railrepay-otp-graph-builder service
3. Click "Redeploy"

**Method 3: Railway CLI**
```bash
railway redeploy --service railrepay-otp-graph-builder
```

### Monitoring the Build

**View Logs:**
- Railway dashboard → railrepay-otp-graph-builder → Logs
- Or via CLI: `railway logs --service railrepay-otp-graph-builder -f`

**Expected Log Output:**
1. "Downloading OSM data from gs://railrepay-osm-prod/..."
2. "Downloading GTFS data from gs://railrepay-gtfs-prod/..."
3. "Building OTP graph..." (this takes 45-90 minutes)
4. "Validating graph..."
5. "Uploading graph to gs://railrepay-graphs-prod/..."
6. "Build complete. Graph available at gs://railrepay-graphs-prod/latest/"

### Post-Build Steps

After the graph build completes successfully:

1. **Update otp-router Service:**
   ```bash
   # Set environment variable on otp-router
   railway variables set GRAPH_VERSION=latest --service railrepay-otp-router

   # Redeploy otp-router to load the new graph
   railway redeploy --service railrepay-otp-router
   ```

2. **Verify Router Loaded New Graph:**
   - Check otp-router logs for "Graph loaded successfully"
   - Test routing API endpoints

### Troubleshooting

**Build Fails During Download:**
- Verify GCS credentials are valid
- Check OSM_VERSION and GTFS_VERSION match files in GCS
- Ensure service account has read access to input buckets

**Out of Memory:**
- Increase memory allocation to 14-16 GB in Railway dashboard
- Check JAVA_OPTS is set to `-Xmx10g` or higher

**Build Timeout:**
- Railway jobs have maximum runtime limits
- Verify OSM file size is reasonable (<2 GB)
- Check CPU allocation (4 cores recommended)

**Upload Fails:**
- Verify service account has write access to `railrepay-graphs-prod`
- Check network connectivity to GCS
- Ensure sufficient disk space in container

### Files in Repository

| File | Purpose |
|------|---------|
| `Dockerfile.builder` | Multi-stage Docker build for OTP graph generation |
| `build-graph.sh` | Main build script (download, build, upload) |
| `validate-graph.sh` | Graph validation and metadata extraction |
| `extract-service-date.py` | GTFS service date extraction |
| `config/build-config.json` | OTP build configuration |
| `railway.toml` | Railway deployment configuration |
| `README.md` | Service documentation |
| `RAILWAY_SETUP.md` | Deployment setup guide |
| `.gitignore` | Git ignore patterns |

### Compliance with RailRepay SOPs

- **GitHub-based deployment:** MANDATORY - Code must be in GitHub, Railway deploys from GitHub
- **No Railway CLI upload:** `railway up` is NOT supported per SOPs
- **Environment isolation:** One-off job runs in isolated container
- **Secrets management:** GCS credentials stored as Railway environment variables
- **Observability:** Logs flow to Grafana Cloud via Loki integration

### Next Steps

1. Complete manual steps above (link GitHub, set memory)
2. Trigger first build via Railway dashboard redeploy
3. Monitor logs for successful completion (45-90 minutes)
4. Update otp-router to use the new graph
5. Test routing functionality

---

**Repository:** https://github.com/loloatlo/railrepay-otp-graph-builder
**Railway Service:** railrepay-otp-graph-builder
**Build Duration:** 45-90 minutes
**Memory Required:** 12 GB
**Deployment Method:** GitHub auto-deploy on push to `main`
