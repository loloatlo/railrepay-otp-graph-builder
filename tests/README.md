# otp-graph-builder Shell Tests

## BL-184: Railway redeploy after graph upload

Tests in `build-graph-railway-redeploy.bats` cover AC-1 and AC-2.

### Requirements

- **bats-core** >= 1.10.0 — https://github.com/bats-core/bats-core
- Install on Linux/WSL: `git clone https://github.com/bats-core/bats-core.git && cd bats-core && ./install.sh /usr/local`
- Install on macOS: `brew install bats-core`

### Run

```bash
bats tests/build-graph-railway-redeploy.bats
```

### What Blake must implement before tests go GREEN

1. Add `BATS_SOURCE_ONLY` guard to `build-graph.sh` so the script can be sourced without executing:

   ```bash
   if [ "${BATS_SOURCE_ONLY:-false}" = "true" ]; then
     # Only define functions, do not execute
     # ... function definitions here ...
     return 0
   fi
   ```

2. Extract the Railway API redeploy logic into `trigger_railway_redeploy()` function.

3. Call `trigger_railway_redeploy` after the GCS upload lines (after line 82 in the current script).

4. The function must not propagate failures (catch errors, log, return 0).
