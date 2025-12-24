# OTP Graph Builder

Builds OpenTripPlanner graphs from OSM and GTFS data, then uploads to GCS for consumption by otp-router.

## Purpose

This service separates graph building (expensive, one-time operation) from graph loading (fast, on-demand). The graph builder runs as a one-off job, while otp-router instances load pre-built graphs.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Graph Builder (One-off Job)                             │
├─────────────────────────────────────────────────────────┤
│ 1. Download OSM (great-britain.osm.pbf)                 │
│ 2. Download GTFS (gtfs.zip)                             │
│ 3. Extract service date (deterministic 6-day offset)    │
│ 4. Build OTP graph (--build --save)                     │
│ 5. Create metadata.json                                 │
│ 6. Validate graph (coordinate routing + stopsByRadius)  │
│ 7. Upload to GCS (gs://railrepay-graphs-prod/)          │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
                  GCS Bucket (Artifact)
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ OTP Router (Deployed Service)                           │
├─────────────────────────────────────────────────────────┤
│ 1. Download pre-built graph from GCS                    │
│ 2. Load graph (--load)                                  │
│ 3. Start server (--serve)                               │
└─────────────────────────────────────────────────────────┘
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OSM_VERSION` | Yes | OSM file version in GCS (e.g., `great-britain-250101.osm.pbf`) |
| `GTFS_VERSION` | Yes | GTFS file version in GCS (e.g., `gtfs-250101.zip`) |
| `OTP_VERSION` | No | OTP version (default: `2.6.0`) |
| `GCS_CREDENTIALS_BASE64` | Yes | Base64-encoded GCS service account key |

## Usage

### Build Graph Locally

```bash
docker build -f Dockerfile.builder -t otp-graph-builder .

docker run --rm \
  -e OSM_VERSION=great-britain-250101.osm.pbf \
  -e GTFS_VERSION=gtfs-250101.zip \
  -e GCS_CREDENTIALS_BASE64=$(cat /path/to/key.json | base64 -w0) \
  -v $(pwd)/output:/var/otp/graphs/default \
  otp-graph-builder
```

### Validate Graph

```bash
docker run --rm \
  -v $(pwd)/output:/var/otp/graphs/default \
  otp-graph-builder \
  /opt/validate-graph.sh /var/otp/graphs/default /opt/otp.jar
```

### Upload to GCS

```bash
# After successful validation
gsutil -m cp -r output/* gs://railrepay-graphs-prod/$(date +%Y%m%d)/
```

## Output Artifacts

The builder produces:

- `graph.obj` - Serialized OTP graph (multi-GB binary)
- `metadata.json` - Build metadata including OSM/GTFS versions, service date
- `streetGraph.obj` - Street network graph
- `transitGraph.obj` - Transit network graph (if applicable)

## Service Date Extraction

The `extract-service-date.py` script:
1. Reads GTFS `calendar.txt` or `calendar_dates.txt`
2. Finds earliest service date
3. Adds 6-day offset (deterministic, avoids edge cases)
4. Returns `YYYY-MM-DD` format

This ensures routing queries use a valid service date.

## Validation

The `validate-graph.sh` script:
1. Starts OTP with the built graph
2. Tests health endpoint
3. Tests `stopsByRadius` query (verifies transit data loaded)
4. Tests coordinate routing (verifies OSM data loaded)
5. Exits with error if validation fails

## CI/CD Integration

```yaml
# Example GitHub Actions workflow
- name: Build OTP Graph
  run: |
    docker build -f services/otp-graph-builder/Dockerfile.builder \
      -t otp-graph-builder .
    docker run --rm \
      -e OSM_VERSION=${{ secrets.OSM_VERSION }} \
      -e GTFS_VERSION=${{ secrets.GTFS_VERSION }} \
      -e GCS_CREDENTIALS_BASE64=${{ secrets.GCS_CREDENTIALS_BASE64 }} \
      -v ./graphs:/var/otp/graphs/default \
      otp-graph-builder

- name: Validate Graph
  run: |
    docker run --rm \
      -v ./graphs:/var/otp/graphs/default \
      otp-graph-builder \
      /opt/validate-graph.sh /var/otp/graphs/default /opt/otp.jar

- name: Upload to GCS
  run: |
    gsutil -m cp -r graphs/* gs://railrepay-graphs-prod/${{ github.sha }}/
```

## Troubleshooting

### Graph has zero edges (|E|=0)

**Cause**: OSM data not included in build.

**Fix**: Ensure `build-config.json` includes OSM source:

```json
{
  "osm": [
    {
      "source": "great-britain.osm.pbf",
      "osmTagMapping": "uk"
    }
  ]
}
```

### LOCATION_NOT_FOUND errors

**Cause**: No street network data, only transit.

**Fix**: Same as above - OSM data must be included.

### Service date errors

**Cause**: Invalid service date in routing queries.

**Fix**: Use `validServiceDate` from `metadata.json`:

```bash
SERVICE_DATE=$(cat graphs/default/metadata.json | jq -r .validServiceDate)
```

## References

- [OTP Build Configuration](https://docs.opentripplanner.org/en/v2.6.0/BuildConfiguration/)
- [OTP Router Configuration](https://docs.opentripplanner.org/en/v2.6.0/RouterConfiguration/)
- [Railway deployment guide](../../docs/deployment/railway.md)
