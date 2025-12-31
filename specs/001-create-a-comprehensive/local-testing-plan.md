# Local Testing Enhancement Plan

**Date**: 2025-09-29 | **Parent Feature**: Media Automation Stack  
**Goal**: Enable local stack validation before Portainer deployment

## Summary

Add local testing capability to validate the media automation stack configuration, service health, and inter-service communication on local machine using temporary directories before deploying to production Portainer host.

**Technical Approach**:
1. Parameterize all host paths in `stacks/starr.yaml` via environment variables
2. Create `stacks/stack-test.env` with temporary directory paths
3. Create `scripts/test-stack.sh` for automated testing
4. Maintain backward compatibility with existing production deployments

## Technical Context

**Platform**: Docker Compose v2.x  
**Testing Strategy**: Temporary directories + isolated network + automated cleanup  
**Validation**: All services must reach healthy/running state  
**Cleanup**: Automatic on success, failure, or interrupt

## Design Decisions

### 1. Environment Variable Parameterization

**Variables to add**:
```env
STARR_CONFIG_ROOT=/mnt/spool/apps/config  # Base for config directories
STARR_MEDIA_ROOT=/mnt/dpool/media          # Base for media directories  
STARR_NETWORK_NAME=starr_net               # Network name
```

**Compose file changes** (example for prowlarr):
```yaml
# BEFORE:
volumes:
  - /mnt/spool/apps/config/prowlarr:/config

# AFTER:
volumes:
  - ${STARR_CONFIG_ROOT}/prowlarr:/config
  - ${STARR_MEDIA_ROOT}:/media
```

**Backward compatibility**:
```yaml
${STARR_CONFIG_ROOT:-/mnt/spool/apps/config}  # Use default if not set
```

### 2. Test Environment Configuration

**File**: `stacks/stack-test.env`
```env
TZ=America/New_York
PUID=1000
PGID=1000
UMASK=0002

# Test paths (overridden by test script)
STARR_CONFIG_ROOT=/tmp/starr-test/config
STARR_MEDIA_ROOT=/tmp/starr-test/media
STARR_NETWORK_NAME=starr_net_test

# Safe test values
TUNNEL_TOKEN=test-token-not-real
SONARR_API_KEY=
RADARR_API_KEY=
PROWLARR_API_KEY=
WEBUI_PORT=8080
```

### 3. Test Script Design

**File**: `scripts/test-stack.sh`

**Flow**:
1. Create `/tmp/starr-test-{timestamp}/` directory
2. Export environment variables for test paths
3. Create directory structure
4. Deploy: `docker compose up -d`
5. Poll health status (max 5 minutes)
6. Report results
7. Cleanup: `docker compose down -v` + remove temp dirs

**Features**:
- `--keep-running`: Leave stack running for manual inspection
- `--verbose`: Show detailed output
- Automatic cleanup on exit/interrupt

## Implementation Tasks

### Phase 1: Parameterization (T001-T006)
- T001: Add STARR_* variables to `stack.env`
- T002: Parameterize prowlarr, sonarr, radarr volumes
- T003: Parameterize sabnzbd, qbittorrent volumes
- T004: Parameterize flaresolverr, unpackerr, recyclarr, cloudflared
- T005: Parameterize network name
- T006: Validate syntax with `docker compose config`

### Phase 2: Test Environment (T007-T008)
- T007: Create `stack-test.env` with safe defaults
- T008: Document test vs production differences

### Phase 3: Test Script (T009-T016)
- T009: Create script skeleton with argument parsing
- T010: Implement temp directory creation
- T011: Add cleanup handlers (trap EXIT INT TERM)
- T012: Implement stack deployment
- T013: Add health check polling logic
- T014: Implement status reporting
- T015: Add --keep-running and --verbose flags
- T016: Test with actual stack

### Phase 4: Documentation (T017-T019)
- T017 [P]: Create `local-testing.md` guide
- T018 [P]: Update `README.md` with testing section
- T019 [P]: Update `AGENTS.md`

### Phase 5: Validation (T020-T024)
- T020: Run test - verify all services healthy
- T021: Verify cleanup on success
- T022: Verify cleanup on failure
- T023: Test --keep-running flag
- T024: Verify production deployment unaffected

**Total**: 24 tasks (4-6 hours)

## Testing Validation Criteria

**Success criteria**:
- ✅ All 9 services reach "healthy" or "running" state
- ✅ No services in "restarting" or "exited" state
- ✅ Test network isolated from production
- ✅ Automatic cleanup removes all containers and temp files
- ✅ Production deployment workflow unchanged
- ✅ Test script exits with correct status code

**Test scenarios**:
1. Clean test run (all healthy)
2. Test with --keep-running flag
3. Test with intentional failure (verify cleanup)
4. Ctrl+C during test (verify cleanup)
5. Production deployment still works

## Benefits

1. **Fast feedback**: Catch configuration errors locally (< 10 minutes)
2. **Safety**: No impact on production during testing
3. **CI/CD ready**: Can run in automated pipelines
4. **Debugging**: --keep-running flag for manual inspection
5. **Confidence**: Validates full stack before Portainer deployment

## Next Step

Run `/tasks` to generate detailed task list from this plan.




