# Tasks: Media Automation Stack

**Input**: Design documents from `/specs/001-create-a-comprehensive/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/, quickstart.md

## Execution Flow (main)
```
1. Load plan.md from feature directory
   → Infrastructure project: Docker Compose stack ✓
   → Extract: Services (9), network (starr_net), volumes (bind mounts) ✓
2. Load optional design documents:
   → research.md: Container versions, network topology ✓
   → data-model.md: Service configurations for 9 services ✓
   → contracts/: compose-schema.yaml, env-schema.env, service-ports.md ✓
   → quickstart.md: Deployment and validation procedures ✓
3. Generate tasks by category:
   → Foundation: compose skeleton, network, env template ✓
   → Services: 9 service definitions ✓
   → Integration: health checks, dependencies, tunnel ✓
   → Validation: syntax, deployment, smoke tests ✓
   → Documentation: README, troubleshooting ✓
4. Apply task rules:
   → Different services = mark [P] for parallel ✓
   → Sequential dependencies = no [P] ✓
   → Foundation before services ✓
5. Number tasks sequentially (T001-T027, plus T025-T027 optional) ✓
6. Generate dependency graph ✓
7. Create parallel execution examples ✓
8. Validate task completeness:
   → All services have definition tasks? ✓
   → All validation scenarios covered? ✓
   → Dependencies correctly ordered? ✓
9. Return: SUCCESS (30 tasks ready for execution: 27 core + 3 optional)
```

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel (different files, no dependencies)
- Include exact file paths in descriptions

## Path Conventions
- **Deployment artifacts**: `stacks/` at repository root
- **Environment config**: `stacks/stack.env`
- **Validation scripts**: `scripts/`
- **Documentation**: Repository root and `specs/` directory

## Deployment Method
**Portainer**: This stack is deployed via Portainer web UI on a remote host, not via direct docker-compose CLI. Tasks reference both Portainer UI steps and alternative CLI commands where applicable.

---

## Phase 1: Foundation Setup

### T001: Create Directory Structure
**File**: N/A (filesystem operations on Portainer host)
**Description**: Create required host directories for media, configs, and downloads on the remote Portainer host
**Location**: Execute on Portainer host (SSH or Portainer console)
**Commands**:
```bash
# SSH to Portainer host (or use Portainer console)
ssh user@portainer-host

# Media directories
sudo mkdir -p /mnt/dpool/media/{tv,movies,downloads/{usenet,torrents}}

# Configuration directories  
sudo mkdir -p /mnt/spool/apps/config/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,flaresolverr,unpackerr,recyclarr,cloudflared}

# Get PUID/PGID on this host (should match Plex stack: 1000/1000)
echo "PUID: $(id -u)"
echo "PGID: $(id -g)"

# Set ownership with PUID/PGID from above
sudo chown -R $(id -u):$(id -g) /mnt/dpool/media
sudo chown -R $(id -u):$(id -g) /mnt/spool/apps/config
```
**Validation**: `ls -la /mnt/dpool/media && ls -la /mnt/spool/apps/config`
**Note**: Verify PUID/PGID matches existing Plex stack (expected: 1000/1000)

### T002: Create Docker Compose Skeleton
**File**: `stacks/starr.yaml`
**Description**: Create initial Docker Compose file with version and basic structure
**Content**:
```yaml
version: "3.9"

services:
  # Services will be added in subsequent tasks

networks:
  # Network definition in T003

volumes:
  # Using bind mounts, no named volumes needed
  {}
```
**Validation**: `docker-compose -f stacks/starr.yaml config` (should parse without errors)

### T003: Define Network
**File**: `stacks/starr.yaml`
**Description**: Add `starr_net` bridge network definition
**Location**: `networks:` section
**Content**:
```yaml
networks:
  starr_net:
    name: starr_net
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```
**Validation**: `docker network ls | grep starr_net` (after compose up)

### T004: Create Environment Variable Template
**File**: `stacks/stack.env`
**Description**: Create centralized environment variable file from `contracts/env-schema.env`
**Content**: Copy from `specs/001-create-a-comprehensive/contracts/env-schema.env`
**Required Variables** (defaults match existing Plex stack):
- `TZ=America/New_York` (default timezone - already set in template, matches Plex)
- `PUID=1000` (user ID from Portainer host - from T001, matches Plex)
- `PGID=1000` (group ID from Portainer host - from T001, matches Plex)
- `UMASK=0002` (file mask - already set in template, matches Plex)
- `TUNNEL_TOKEN` (Cloudflare tunnel token - to be populated by user)
- API keys (initially empty, populated after first run)
**Note**: Verify PUID/PGID from T001 matches expected Plex values (1000/1000)
**Validation**: `cat stacks/stack.env` (verify all variables present, values match Plex stack)

---

## Phase 2: Core Service Definitions

### T005: Implement Prowlarr Service
**File**: `stacks/starr.yaml`
**Description**: Add Prowlarr (indexer management) service definition
**Location**: `services:` section
**Dependencies**: T003 (network must exist)
**Content**:
```yaml
  prowlarr:
    image: ghcr.io/hotio/prowlarr:1.11.0
    container_name: prowlarr
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UMASK: ${UMASK}
    volumes:
      - /mnt/spool/apps/config/prowlarr:/config
    networks:
      - starr_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9696/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped
```
**Validation**: Service starts and becomes healthy

### T006: Implement Sonarr Service
**File**: `stacks/starr.yaml`
**Description**: Add Sonarr (TV shows) service definition with Prowlarr dependency
**Location**: `services:` section
**Dependencies**: T005 (Prowlarr must be defined)
**Content**:
```yaml
  sonarr:
    image: ghcr.io/hotio/sonarr:4.0.0
    container_name: sonarr
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UMASK: ${UMASK}
    volumes:
      - /mnt/spool/apps/config/sonarr:/config
      - /mnt/dpool/media:/media
      - /mnt/dpool/media/downloads:/downloads
    networks:
      - starr_net
    depends_on:
      prowlarr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8989/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
    restart: unless-stopped
```
**Validation**: Service starts after Prowlarr is healthy

### T007: Implement Radarr Service
**File**: `stacks/starr.yaml`
**Description**: Add Radarr (movies) service definition with Prowlarr dependency
**Location**: `services:` section
**Dependencies**: T005 (Prowlarr must be defined)
**Content**:
```yaml
  radarr:
    image: ghcr.io/hotio/radarr:5.2.0
    container_name: radarr
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UMASK: ${UMASK}
    volumes:
      - /mnt/spool/apps/config/radarr:/config
      - /mnt/dpool/media:/media
      - /mnt/dpool/media/downloads:/downloads
    networks:
      - starr_net
    depends_on:
      prowlarr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7878/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
    restart: unless-stopped
```
**Validation**: Service starts after Prowlarr is healthy

---

## Phase 3: Download Client Definitions (Parallel)

### T008 [P]: Implement Sabnzbd Service
**File**: `stacks/starr.yaml`
**Description**: Add Sabnzbd (Usenet client) service definition
**Location**: `services:` section
**Dependencies**: T003 (network), can run parallel with T009
**Content**:
```yaml
  sabnzbd:
    image: ghcr.io/hotio/sabnzbd:4.2.0
    container_name: sabnzbd
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UMASK: ${UMASK}
    volumes:
      - /mnt/spool/apps/config/sabnzbd:/config
      - /mnt/dpool/media/downloads/usenet:/downloads
    networks:
      - starr_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api?mode=version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped
```
**Validation**: Service starts independently

### T009 [P]: Implement qBittorrent Service
**File**: `stacks/starr.yaml`
**Description**: Add qBittorrent (torrent client) service definition with port publishing
**Location**: `services:` section
**Dependencies**: T003 (network), can run parallel with T008
**Content**:
```yaml
  qbittorrent:
    image: ghcr.io/hotio/qbittorrent:4.6.0
    container_name: qbittorrent
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UMASK: ${UMASK}
      WEBUI_PORT: 8080
    volumes:
      - /mnt/spool/apps/config/qbittorrent:/config
      - /mnt/dpool/media/downloads/torrents:/downloads
    ports:
      - "6881:6881/tcp"
      - "6881:6881/udp"
    networks:
      - starr_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v2/app/version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped
```
**Validation**: Service starts and peer ports 6881 are published to host

---

## Phase 4: Supporting Service Definitions (Parallel)

### T010 [P]: Implement Flaresolverr Service
**File**: `stacks/starr.yaml`
**Description**: Add Flaresolverr (Cloudflare bypass) service definition
**Location**: `services:` section
**Dependencies**: T003 (network), can run parallel with T011, T012
**Content**:
```yaml
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:3.3.16
    container_name: flaresolverr
    environment:
      TZ: ${TZ}
    networks:
      - starr_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8191/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    restart: unless-stopped
```
**Validation**: Service starts independently

### T011 [P]: Implement Unpackerr Service
**File**: `stacks/starr.yaml`
**Description**: Add Unpackerr (archive extraction) service definition
**Location**: `services:` section
**Dependencies**: T008, T009 (download clients for depends_on), can run parallel with T010, T012
**Content**:
```yaml
  unpackerr:
    image: ghcr.io/hotio/unpackerr:0.12.0
    container_name: unpackerr
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UN_SONARR_0_URL: http://sonarr:8989
      UN_SONARR_0_API_KEY: ${SONARR_API_KEY}
      UN_RADARR_0_URL: http://radarr:7878
      UN_RADARR_0_API_KEY: ${RADARR_API_KEY}
    volumes:
      - /mnt/spool/apps/config/unpackerr:/config
      - /mnt/dpool/media/downloads:/downloads
    networks:
      - starr_net
    depends_on:
      - sabnzbd
      - qbittorrent
    restart: unless-stopped
```
**Validation**: Service starts after download clients

### T012 [P]: Implement Recyclarr Service
**File**: `stacks/starr.yaml`
**Description**: Add Recyclarr (settings sync) service definition
**Location**: `services:` section
**Dependencies**: T003 (network), can run parallel with T010, T011
**Content**:
```yaml
  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:6.0.0
    container_name: recyclarr
    environment:
      TZ: ${TZ}
      RECYCLARR_CREATE_CONFIG: "true"
    volumes:
      - /mnt/spool/apps/config/recyclarr:/config
    networks:
      - starr_net
    restart: unless-stopped
```
**Validation**: Service starts independently

---

## Phase 5: Remote Access Integration

### T013: Implement Cloudflare Tunnel Service
**File**: `stacks/starr.yaml`
**Description**: Add cloudflared (Cloudflare Tunnel) service definition
**Location**: `services:` section
**Dependencies**: T005-T012 (all services defined for tunnel routing)
**Content**:
```yaml
  cloudflared:
    image: cloudflare/cloudflared:2024.1.0
    container_name: cloudflared
    command: tunnel run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN}
    networks:
      - starr_net
    restart: unless-stopped
```
**Note**: Tunnel routing configuration must be done in Cloudflare Dashboard
**Validation**: Service starts and connects to Cloudflare

---

## Phase 6: Validation & Testing

### T014: Validate Compose Syntax
**File**: `stacks/starr.yaml` (validation only)
**Description**: Run Docker Compose config validation to verify YAML syntax
**Command**: `docker-compose -f stacks/starr.yaml config`
**Expected**: Valid YAML output with no errors
**Fix**: Correct any indentation, missing keys, or syntax errors

### T015: Test Initial Deployment
**File**: `stacks/starr.yaml` (deployment test via Portainer)
**Description**: Deploy the stack via Portainer and verify all services start
**Deployment Steps**:
1. **Access Portainer**: Navigate to Portainer web UI
2. **Create Stack**: Stacks → + Add stack
3. **Name**: `starr-media-automation`
4. **Upload Compose**: Web editor (paste) or Upload `stacks/starr.yaml`
5. **Environment**: Load `stacks/stack.env` or manually add variables
   - TZ=America/New_York
   - PUID=(from Portainer host)
   - PGID=(from Portainer host)
   - UMASK=0002
   - TUNNEL_TOKEN=(from Cloudflare)
6. **Deploy**: Click "Deploy the stack"
7. **Wait**: 2-3 minutes for initialization

**Validation via Portainer UI**:
- Stack status: Active ✅
- All 9 containers: Running 🟢 or Healthy 🟢
- No containers in "Exited" or "Restarting" state

**Alternative CLI Validation** (SSH to Portainer host):
```bash
docker ps --filter "label=com.docker.compose.project=starr-media-automation"
```
**Expected**: All 9 containers running, 6 showing "(healthy)" status

### T016: Verify Service Health Checks
**File**: N/A (runtime validation)
**Description**: Verify all services with health checks report healthy status

**Via Portainer UI** (Recommended):
1. Navigate to stack in Portainer
2. View container list
3. Check status column for each service

**Via SSH** (Alternative):
```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

**Expected Health Status**:
- prowlarr: healthy 🟢
- sonarr: healthy 🟢
- radarr: healthy 🟢
- sabnzbd: healthy 🟢
- qbittorrent: healthy 🟢
- flaresolverr: healthy 🟢
- unpackerr: running 🟢
- recyclarr: running 🟢
- cloudflared: running 🟢

**Validation**: All health checks passing within 5 minutes

### T017: Test Network Connectivity
**File**: N/A (runtime validation)
**Description**: Verify services can communicate on starr_net
**Commands**:
```bash
# Test Sonarr can reach Prowlarr
docker exec sonarr curl -s http://prowlarr:9696/ping

# Test Radarr can reach Prowlarr  
docker exec radarr curl -s http://prowlarr:7878/ping

# Test Prowlarr can reach Flaresolverr
docker exec prowlarr curl -s http://flaresolverr:8191/health
```
**Expected**: All curl commands return successful responses
**Validation**: DNS resolution working, services reachable

### T018: Verify Volume Persistence
**File**: N/A (runtime validation)
**Description**: Verify configuration survives container restart
**Commands**:
```bash
# Restart a service
docker-compose -f stacks/starr.yaml restart prowlarr

# Wait for restart
sleep 30

# Verify config persisted
docker exec prowlarr ls -la /config
```
**Expected**: Config directory contains initialization files
**Validation**: Data persisted across restart

### T019: Test Port Publishing
**File**: N/A (runtime validation)
**Description**: Verify qBittorrent peer ports published correctly
**Commands**:
```bash
# Check published ports
docker ps --filter name=qbittorrent --format "{{.Ports}}"

# Test port accessibility from host
netstat -tlnp | grep 6881
netstat -ulnp | grep 6881
```
**Expected**: Ports 6881/tcp and 6881/udp published and listening
**Validation**: External peers can connect

### T020: Verify Web UI Isolation
**File**: N/A (runtime validation)
**Description**: Verify web UIs NOT accessible directly from host
**Commands**:
```bash
# Attempt direct connection (should fail)
curl -I http://localhost:8989  # Sonarr
curl -I http://localhost:7878  # Radarr
curl -I http://localhost:9696  # Prowlarr
```
**Expected**: Connection refused (ports not published)
**Validation**: Only tunnel access possible

### T021: Execute Integration Smoke Tests
**File**: N/A (runtime validation)
**Description**: Run end-to-end integration tests from quickstart.md
**Test Scenarios**:
1. Prowlarr indexer search functionality
2. Sonarr can communicate with Prowlarr API
3. Radarr can communicate with Prowlarr API
4. Sonarr can control Sabnzbd
5. Radarr can control qBittorrent
6. Unpackerr can monitor download clients
7. Recyclarr can access Sonarr/Radarr APIs
**Commands**: Follow procedures in `specs/001-create-a-comprehensive/quickstart.md` Steps 8-9
**Validation**: All integration points functional

---

## Phase 7: Documentation

### T022: Create Deployment README
**File**: `README.md` (repository root)
**Description**: Create or update main README with stack deployment instructions
**Sections**:
1. Overview of media automation stack
2. Prerequisites (Docker, Compose, Cloudflare)
3. Quick start deployment steps
4. Service access URLs
5. Configuration guide
6. Troubleshooting common issues
**Reference**: Use `specs/001-create-a-comprehensive/quickstart.md` as source
**Validation**: README complete and accurate

### T023: Document Troubleshooting Procedures
**File**: `TROUBLESHOOTING.md` (repository root) or section in README
**Description**: Document common issues and resolution steps
**Topics**:
- Permission denied errors (PUID/PGID)
- Services failing health checks
- Network connectivity issues
- Port conflicts
- Cloudflare Tunnel connection failures
- API key configuration
**Reference**: Use quickstart.md troubleshooting section
**Validation**: All common issues documented

### T024: Update Repository Documentation
**File**: `AGENTS.md` (if exists) or relevant docs
**Description**: Update any agent context or workflow documentation
**Updates**:
- Add starr.yaml to list of stacks
- Document stack.env usage
- Reference quickstart guide
- Update stack validation procedures
**Validation**: Documentation consistent with new stack

---

## Phase 8: Optional Enhancements

### T025 [P]: Configure Dependabot
**File**: `.github/dependabot.yml`
**Description**: Set up Dependabot to monitor Docker image versions (optional)
**Content**:
```yaml
version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/stacks"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
```
**Validation**: Dependabot config valid, PRs created for updates
**Note**: Optional task, only if automated updates desired

### T026 [P]: Create Stack Backup Script
**File**: `scripts/backup-starr-configs.sh`
**Description**: Create script to backup service configurations
**Content**:
```bash
#!/bin/bash
tar -czf starr-config-$(date +%Y%m%d).tar.gz \
  /mnt/spool/apps/config/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,unpackerr,recyclarr}
```
**Validation**: Script runs and creates backup archive
**Note**: Optional task

### T027 [P]: Create Monitoring Dashboard Config
**File**: `monitoring/prometheus.yml` or `monitoring/grafana-dashboard.json`
**Description**: Create monitoring configuration for stack observability (optional)
**Content**: Prometheus exporters or Grafana dashboard definitions
**Validation**: Monitoring stack can scrape metrics
**Note**: Optional task, advanced use case

---

## Dependencies

**Critical Path** (must be sequential):
```
T001 (directories) → T002 (skeleton) → T003 (network) → T004 (env) →
  T005 (Prowlarr) → [T006 (Sonarr) + T007 (Radarr)] →
    [T008 (Sabnzbd) + T009 (qBittorrent)] →
      [T010 (Flaresolverr) + T011 (Unpackerr) + T012 (Recyclarr)] →
        T013 (Cloudflared) →
          T014-T021 (Validation) →
            T022-T024 (Documentation) →
              [T025-T027 (Optional)]
```

**Parallel Opportunities**:
- T008 + T009 (download clients - independent services)
- T010 + T011 + T012 (supporting services - independent)
- T025 + T026 + T027 (optional enhancements - independent)

**Blocking Dependencies**:
- T005 blocks T006, T007 (Prowlarr must exist before Sonarr/Radarr)
- T008, T009 block T011 (download clients must exist for Unpackerr depends_on)
- T005-T012 block T013 (all services must exist before tunnel routing)
- T002-T013 block T014-T021 (stack must be complete before validation)

---

## Parallel Execution Examples

### Example 1: Download Clients (Phase 3)
```bash
# After T007 is complete, run these in parallel:
Task T008: "Implement Sabnzbd service definition in stacks/starr.yaml"
Task T009: "Implement qBittorrent service definition in stacks/starr.yaml"
```
**Conflict Check**: Different service blocks in same file - review for merge conflicts

### Example 2: Supporting Services (Phase 4)
```bash
# After T009 is complete, run these in parallel:
Task T010: "Implement Flaresolverr service definition in stacks/starr.yaml"
Task T011: "Implement Unpackerr service definition in stacks/starr.yaml"
Task T012: "Implement Recyclarr service definition in stacks/starr.yaml"
```
**Conflict Check**: Different service blocks in same file - review for merge conflicts

### Example 3: Documentation (Phase 7)
```bash
# After T021 is complete, run these in parallel:
Task T022: "Create deployment README in README.md"
Task T023: "Document troubleshooting procedures in TROUBLESHOOTING.md"
Task T024: "Update repository documentation in AGENTS.md"
```
**Conflict Check**: Different files - no conflicts expected

### Example 4: Optional Enhancements (Phase 8)
```bash
# Run these in parallel (if desired):
Task T025: "Configure Dependabot in .github/dependabot.yml"
Task T026: "Create backup script in scripts/backup-starr-configs.sh"
Task T027: "Create monitoring config in monitoring/"
```
**Conflict Check**: Different files - no conflicts expected

---

## Notes

### Implementation Strategy
- **Portainer Deployment**: Stack deployed via Portainer UI, not command-line docker-compose
- **Remote Host**: All operations on Portainer host, not local machine
- **Incremental Development**: Add one service at a time to compose file
- **Test After Each Service**: Validate syntax after each service addition
- **Commit Frequently**: Commit after each task completion
- **Environment Variables**: Populate stack.env with Portainer host PUID/PGID during initial setup (T004)
- **Timezone**: Default TZ=America/New_York already set in template
- **API Keys**: Retrieved after first deployment, updated in stack.env, then re-deploy via Portainer

### Testing Approach
- **Syntax First**: Always validate with `docker-compose config` before deployment
- **Deploy Incrementally**: Test with subset of services before full stack
- **Health Checks**: Wait for all health checks to pass before integration tests
- **Rollback Plan**: Keep previous working version for quick rollback

### Common Pitfalls to Avoid
- ❌ Creating directories on local machine instead of Portainer host (T001)
- ❌ Using local PUID/PGID instead of Portainer host values
- ❌ Incorrect PUID/PGID causing permission errors
- ❌ Missing TUNNEL_TOKEN in stack.env
- ❌ Not waiting for Prowlarr healthy before deploying Sonarr/Radarr
- ❌ Port 6881 conflicts with existing services on Portainer host
- ❌ Attempting to access web UIs directly (should use tunnel only)
- ❌ Forgetting to upload stack.env to Portainer environment variables

### Success Criteria
✅ All 27 core tasks (T001-T027) completable  
✅ Docker Compose syntax validates  
✅ All services start and become healthy  
✅ Network connectivity between services working  
✅ Volume persistence confirmed  
✅ Only qBittorrent peer ports published  
✅ Web UIs accessible ONLY via Cloudflare Tunnel  
✅ Integration smoke tests pass  
✅ Documentation complete and accurate

---

## Task Generation Rules Applied

1. **From Contracts**:
   - `compose-schema.yaml` → Service definition tasks (T005-T013)
   - `env-schema.env` → Environment template task (T004)
   - `service-ports.md` → Port configuration in service tasks

2. **From Data Model**:
   - Each service schema → Individual service task
   - Network definition → Network task (T003)
   - Volume mappings → Directory creation (T001)

3. **From Quickstart**:
   - Deployment steps → Validation tasks (T014-T021)
   - Configuration procedures → Documentation tasks (T022-T024)

4. **Ordering**:
   - Foundation (T001-T004) → Services (T005-T013) → Validation (T014-T021) → Documentation (T022-T024)
   - Dependencies enforced (Prowlarr before Sonarr/Radarr)

---

## Validation Checklist
*GATE: Checked before task execution*

- [x] All services have corresponding definition tasks
- [x] All validation scenarios from quickstart covered
- [x] Foundation tasks come before service tasks
- [x] Parallel tasks truly independent (different service blocks)
- [x] Each task specifies exact file path
- [x] Dependencies correctly ordered (Prowlarr → Sonarr/Radarr)
- [x] Health checks configured for all applicable services
- [x] Documentation tasks included

---

**Total Tasks**: 27 core tasks + 3 optional = 30 tasks
**Estimated Completion Time**: 4-6 hours (including testing and configuration)
**Ready for Execution**: Yes ✓

---
---

# Enhancement: Local Testing Capability

**Goal**: Enable local stack validation before Portainer deployment  
**Input**: `local-testing-plan.md`  
**Total Tasks**: 24 tasks (LT001-LT024)  
**Estimated Time**: 4-6 hours

## Enhancement Overview

This enhancement adds the ability to test the media automation stack locally using temporary directories before deploying to production Portainer host. Key changes:

1. **Parameterize paths** in `stacks/starr.yaml` via environment variables
2. **Test environment** with `stacks/stack-test.env` (safe defaults)
3. **Automated test script** `scripts/test-stack.sh` (create, deploy, validate, cleanup)
4. **Backward compatible** with existing production deployments

## Enhancement Execution Flow

```
Phase 1: Parameterization (LT001-LT006) → Sequential
  ↓
Phase 2: Test Environment (LT007-LT008) → Sequential
  ↓
Phase 3: Test Script (LT009-LT016) → Sequential
  ↓
Phase 4: Documentation (LT017-LT019) → Parallel [P]
  ↓
Phase 5: Validation (LT020-LT024) → Sequential
```

---

## Phase 1: Parameterization

### LT001: Add Environment Variables to Production Config
**File**: `stacks/stack.env`
**Description**: Add base path variables for host directories
**Location**: Top of file (after existing common settings)
**Content**:
```env
# Host paths for production deployment (added for local testing support)
STARR_CONFIG_ROOT=/mnt/spool/apps/config
STARR_MEDIA_ROOT=/mnt/dpool/media
STARR_NETWORK_NAME=starr_net
```
**Validation**: `cat stacks/stack.env | grep STARR_`
**Note**: These provide defaults for production; test environment overrides them

### LT002: Parameterize Media Management Services
**File**: `stacks/starr.yaml`
**Description**: Replace hardcoded paths with environment variables for prowlarr, sonarr, radarr
**Location**: Service definitions for prowlarr, sonarr, radarr
**Changes**:
```yaml
# Prowlarr
volumes:
  - ${STARR_CONFIG_ROOT}/prowlarr:/config

# Sonarr
volumes:
  - ${STARR_CONFIG_ROOT}/sonarr:/config
  - ${STARR_MEDIA_ROOT}:/media
  - ${STARR_MEDIA_ROOT}/downloads:/downloads

# Radarr
volumes:
  - ${STARR_CONFIG_ROOT}/radarr:/config
  - ${STARR_MEDIA_ROOT}:/media
  - ${STARR_MEDIA_ROOT}/downloads:/downloads
```
**Validation**: `docker compose -f stacks/starr.yaml --env-file stacks/stack.env config | grep -A 2 "volumes:" | head -20`
**Dependencies**: LT001 (env vars must exist)

### LT003: Parameterize Download Clients
**File**: `stacks/starr.yaml`
**Description**: Replace hardcoded paths with environment variables for sabnzbd, qbittorrent
**Location**: Service definitions for sabnzbd, qbittorrent
**Changes**:
```yaml
# Sabnzbd
volumes:
  - ${STARR_CONFIG_ROOT}/sabnzbd:/config
  - ${STARR_MEDIA_ROOT}/downloads/usenet:/downloads

# qBittorrent
volumes:
  - ${STARR_CONFIG_ROOT}/qbittorrent:/config
  - ${STARR_MEDIA_ROOT}/downloads/torrents:/downloads
```
**Validation**: `docker compose -f stacks/starr.yaml --env-file stacks/stack.env config --quiet`
**Dependencies**: LT001

### LT004: Parameterize Supporting Services
**File**: `stacks/starr.yaml`
**Description**: Replace hardcoded paths with environment variables for flaresolverr, unpackerr, recyclarr, cloudflared
**Location**: Service definitions for flaresolverr, unpackerr, recyclarr, cloudflared
**Changes**:
```yaml
# Unpackerr
volumes:
  - ${STARR_CONFIG_ROOT}/unpackerr:/config
  - ${STARR_MEDIA_ROOT}/downloads:/downloads

# Recyclarr
volumes:
  - ${STARR_CONFIG_ROOT}/recyclarr:/config

# Cloudflared (no volumes in current config, skip if not present)
# Flaresolverr (no volumes in current config, skip if not present)
```
**Validation**: `docker compose -f stacks/starr.yaml --env-file stacks/stack.env config --quiet`
**Dependencies**: LT001

### LT005: Parameterize Network Name
**File**: `stacks/starr.yaml`
**Description**: Replace hardcoded network name with environment variable
**Location**: `networks:` section
**Changes**:
```yaml
networks:
  starr_net:
    name: ${STARR_NETWORK_NAME:-starr_net}
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```
**Validation**: `docker compose -f stacks/starr.yaml --env-file stacks/stack.env config | grep "name:" | grep starr`
**Dependencies**: LT001
**Note**: Uses `:-` syntax for backward compatibility (defaults to starr_net if not set)

### LT006: Validate Parameterized Configuration
**File**: `stacks/starr.yaml` (validation only)
**Description**: Run full validation with existing environment to ensure no breaking changes
**Commands**:
```bash
# Validate syntax
docker compose -f stacks/starr.yaml --env-file stacks/stack.env config --quiet

# Verify services list unchanged
docker compose -f stacks/starr.yaml --env-file stacks/stack.env config --services

# Run validation script
./scripts/validate-stack.sh starr
```
**Expected**: 
- No errors
- All 9 services listed
- Network name shows "starr_net"
**Dependencies**: LT002, LT003, LT004, LT005
**Note**: This ensures production deployment unaffected by parameterization

---

## Phase 2: Test Environment Setup

### LT007: Create Test Environment Configuration
**File**: `stacks/stack-test.env`
**Description**: Create environment file with safe test defaults
**Content**:
```env
# Local Testing Environment Configuration
# This file contains SAFE DEFAULTS for local testing
# DO NOT put production secrets here - this file is committed to git

# ============================================
# COMMON SETTINGS (match production)
# ============================================

TZ=America/New_York
PUID=1000
PGID=1000
UMASK=0002

# ============================================
# TEST PATHS (overridden by test script)
# ============================================

# These are placeholder values - test script will override with timestamp-based paths
STARR_CONFIG_ROOT=/tmp/starr-test/config
STARR_MEDIA_ROOT=/tmp/starr-test/media

# Test network name (prevents conflict with production)
STARR_NETWORK_NAME=starr_net_test

# ============================================
# TEST VALUES (safe, non-functional)
# ============================================

# Cloudflare Tunnel - test value (non-functional)
TUNNEL_TOKEN=test-token-not-real-value-for-local-testing-only

# Web UI Port
WEBUI_PORT=8080

# API Keys - empty on first run (services generate them)
SONARR_API_KEY=
RADARR_API_KEY=
PROWLARR_API_KEY=

# ============================================
# USAGE
# ============================================
# This file is used by scripts/test-stack.sh
# Run: ./scripts/test-stack.sh starr
```
**Validation**: 
- `cat stacks/stack-test.env | grep STARR_`
- `docker compose -f stacks/starr.yaml --env-file stacks/stack-test.env config --quiet`
**Dependencies**: LT006 (parameterization complete)

### LT008: Document Environment Differences
**File**: `stacks/stack-test.env` (comments) and `README.md` (reference subsection)
**Description**: Add clear documentation of test vs production environment differences
**Add to README.md** (within Local Testing section created by LT018):
```markdown
### Environment Differences

| Variable | Production (`stack.env`) | Test (`stack-test.env`) |
|----------|-------------------------|-------------------------|
| `STARR_CONFIG_ROOT` | `/mnt/spool/apps/config` | `/tmp/starr-test-{timestamp}/config` |
| `STARR_MEDIA_ROOT` | `/mnt/dpool/media` | `/tmp/starr-test-{timestamp}/media` |
| `STARR_NETWORK_NAME` | `starr_net` | `starr_net_test_{pid}` |
| `TUNNEL_TOKEN` | Real Cloudflare token | `test-token-not-real` |
| Cleanup | Manual (via Portainer) | Automatic (script) |
```
**Validation**: Table renders correctly in README
**Dependencies**: LT007
**Note**: This subsection goes within the "## Local Testing" section created by LT018

---

## Phase 3: Test Script Development

### LT009: Create Test Script Skeleton
**File**: `scripts/test-stack.sh`
**Description**: Create executable script with argument parsing and basic structure
**Content**:
```bash
#!/bin/bash
set -euo pipefail

# Configuration
STACK_NAME="${1:-starr}"
STACK_FILE="stacks/${STACK_NAME}.yaml"
TEST_ENV="stacks/stack-test.env"
TIMEOUT=300  # 5 minutes
POLL_INTERVAL=10  # seconds

# Flags
KEEP_RUNNING=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-running) KEEP_RUNNING=true ;;
    --verbose|-v) VERBOSE=true ;;
    *) STACK_NAME="$1" ;;
  esac
  shift
done

# Verify prerequisites
if ! command -v jq &> /dev/null; then
  echo "❌ Error: jq is required but not installed"
  echo "   Install with:"
  echo "   - Fedora/RHEL: sudo dnf install jq"
  echo "   - Ubuntu/Debian: sudo apt install jq"
  echo "   - macOS: brew install jq"
  exit 1
fi

# Verify files exist
if [ ! -f "$STACK_FILE" ]; then
  echo "Error: Stack file not found: $STACK_FILE"
  exit 1
fi

if [ ! -f "$TEST_ENV" ]; then
  echo "Error: Test environment file not found: $TEST_ENV"
  exit 1
fi

echo "🚀 Starting local stack test: $STACK_NAME"
echo "   Stack file: $STACK_FILE"
echo "   Test env: $TEST_ENV"

# TODO: Implement phases in subsequent tasks
echo "⚠️  Script skeleton only - not yet functional"
exit 1
```
**Validation**: 
- `chmod +x scripts/test-stack.sh`
- `./scripts/test-stack.sh --help || true` (should show error about skeleton)
**Dependencies**: LT007 (test env must exist)

### LT010: Implement Temporary Directory Creation
**File**: `scripts/test-stack.sh`
**Description**: Add logic to create timestamp-based temp directories and export environment variables
**Location**: After argument parsing, before deployment
**Add**:
```bash
# Create timestamp-based temp directory
TIMESTAMP=$(date +%s)
TEST_DIR="/tmp/starr-test-${TIMESTAMP}"
export STARR_CONFIG_ROOT="${TEST_DIR}/config"
export STARR_MEDIA_ROOT="${TEST_DIR}/media"
export STARR_NETWORK_NAME="starr_net_test_$$"

echo "📁 Creating test directories..."
echo "   Base: $TEST_DIR"
echo "   Config: $STARR_CONFIG_ROOT"
echo "   Media: $STARR_MEDIA_ROOT"
echo "   Network: $STARR_NETWORK_NAME"

# Create directory structure
mkdir -p "$STARR_CONFIG_ROOT"/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,flaresolverr,unpackerr,recyclarr,cloudflared}
mkdir -p "$STARR_MEDIA_ROOT"/{tv,movies,downloads/{usenet,torrents}}

[ "$VERBOSE" = true ] && ls -la "$TEST_DIR"
```
**Validation**: Run script and verify directories created (will fail at deployment phase, that's OK)
**Dependencies**: LT009

### LT011: Implement Cleanup Handlers
**File**: `scripts/test-stack.sh`
**Description**: Add trap handlers for automatic cleanup on exit, interrupt, or termination
**Location**: After environment variable exports, before directory creation
**Add**:
```bash
# Cleanup function
cleanup() {
  local EXIT_CODE=$?
  
  if [ "$KEEP_RUNNING" = false ]; then
    echo ""
    echo "🧹 Cleaning up..."
    
    # Stop and remove containers
    if docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --quiet 2>/dev/null | grep -q .; then
      echo "   Stopping containers..."
      docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" down -v 2>/dev/null || true
    fi
    
    # Remove temp directory
    if [ -d "$TEST_DIR" ]; then
      echo "   Removing test directory: $TEST_DIR"
      rm -rf "$TEST_DIR"
    fi
    
    echo "✓ Cleanup complete"
  else
    echo ""
    echo "⚠️  Stack left running (--keep-running flag)"
    echo "   Test directory: $TEST_DIR"
    echo "   Network: $STARR_NETWORK_NAME"
    echo ""
    echo "   To inspect:"
    echo "   docker compose -f $STACK_FILE --env-file $TEST_ENV ps"
    echo "   docker compose -f $STACK_FILE --env-file $TEST_ENV logs -f"
    echo ""
    echo "   To stop:"
    echo "   docker compose -f $STACK_FILE --env-file $TEST_ENV down -v"
    echo "   rm -rf $TEST_DIR"
  fi
  
  exit $EXIT_CODE
}

# Trap cleanup on exit, interrupt, and termination
trap cleanup EXIT INT TERM
```
**Validation**: Test with Ctrl+C during execution - cleanup should run
**Dependencies**: LT010

### LT012: Implement Stack Deployment
**File**: `scripts/test-stack.sh`
**Description**: Add docker compose deployment logic
**Location**: After directory creation
**Add**:
```bash
# Deploy stack
echo ""
echo "🐳 Deploying stack..."
if [ "$VERBOSE" = true ]; then
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" up -d
else
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" up -d > /dev/null 2>&1
fi

if [ $? -ne 0 ]; then
  echo "❌ Stack deployment failed"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" logs --tail=50
  exit 1
fi

echo "✓ Stack deployed"
```
**Validation**: Script should successfully deploy stack (check with `docker ps`)
**Dependencies**: LT011

### LT013: Implement Health Check Polling
**File**: `scripts/test-stack.sh`
**Description**: Add logic to poll service health status until all healthy or timeout
**Location**: After deployment
**Add**:
```bash
# Wait for services to become healthy
echo ""
echo "⏳ Waiting for services to become healthy (timeout: ${TIMEOUT}s)..."
ELAPSED=0
ALL_HEALTHY=false

while [ $ELAPSED -lt $TIMEOUT ]; do
  # Get container status as JSON
  STATUS_JSON=$(docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --format json 2>/dev/null || echo "[]")
  
  # Count total services
  TOTAL=$(echo "$STATUS_JSON" | jq -s 'length')
  
  # Count healthy/running services
  # Services with health checks: count as healthy
  # Services without health checks: count if running
  HEALTHY=$(echo "$STATUS_JSON" | jq -s '
    [.[] | select(
      (.Health == "healthy") or 
      (.Health == null and .State == "running")
    )] | length
  ')
  
  echo -ne "   Progress: $HEALTHY/$TOTAL services ready\r"
  
  # Check if all services are healthy/running
  if [ "$HEALTHY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo -ne "\n"
    ALL_HEALTHY=true
    break
  fi
  
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
```
**Validation**: Script waits for services to become healthy
**Dependencies**: LT012
**Note**: Requires `jq` for JSON parsing

### LT014: Implement Status Reporting
**File**: `scripts/test-stack.sh`
**Description**: Add final status report and exit code logic
**Location**: After health check polling
**Add**:
```bash
# Report final status
echo "📊 Final Service Status:"
docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps

echo ""
if [ "$ALL_HEALTHY" = true ]; then
  echo "✅ All services healthy! Test PASSED"
  echo ""
  echo "Services:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --format "table {{.Service}}\t{{.Status}}"
  exit 0
else
  echo "❌ Timeout waiting for services. Test FAILED"
  echo ""
  echo "Service Status:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --format "table {{.Service}}\t{{.Status}}"
  echo ""
  echo "Recent Logs:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" logs --tail=30
  exit 1
fi
```
**Validation**: Script reports success/failure correctly
**Dependencies**: LT013

### LT015: Add Command-Line Flags
**File**: `scripts/test-stack.sh`
**Description**: Implement --keep-running and --verbose flag functionality throughout script
**Location**: Various locations where flags are referenced
**Changes**:
- Already implemented in argument parsing (LT009)
- Implemented in cleanup (LT011)
- Implemented in deployment (LT012)
- Add help text at top:
```bash
# Usage information
usage() {
  cat << EOF
Usage: $0 [STACK_NAME] [OPTIONS]

Test a Docker Compose stack locally with temporary directories.

Arguments:
  STACK_NAME        Name of stack to test (default: starr)

Options:
  --keep-running    Leave stack running after test for manual inspection
  --verbose, -v     Show detailed output
  --help, -h        Show this help message

Examples:
  $0 starr                    # Run test with cleanup
  $0 starr --keep-running     # Run test, leave running
  $0 starr --verbose          # Run test with detailed output

EOF
  exit 0
}

# Add to argument parsing:
case $1 in
  --help|-h) usage ;;
esac
```
**Validation**: 
- `./scripts/test-stack.sh --help` shows usage
- `./scripts/test-stack.sh --keep-running` leaves containers running
**Dependencies**: LT014

### LT016: Test Script with Actual Stack
**File**: N/A (validation task)
**Description**: Run the complete test script with the starr stack and verify all functionality
**Commands**:
```bash
# Test 1: Normal run (should deploy, validate, cleanup)
./scripts/test-stack.sh starr

# Test 2: Keep running
./scripts/test-stack.sh starr --keep-running
docker compose -f stacks/starr.yaml --env-file stacks/stack-test.env ps
docker compose -f stacks/starr.yaml --env-file stacks/stack-test.env down -v

# Test 3: Verbose mode
./scripts/test-stack.sh starr --verbose

# Test 4: Interrupt test (Ctrl+C during health check)
./scripts/test-stack.sh starr
# Press Ctrl+C - verify cleanup runs
```
**Expected**:
- All 9 services start
- Health checks pass (or timeout clearly reported)
- Automatic cleanup removes containers and temp dirs
- --keep-running leaves stack running
- Ctrl+C triggers cleanup
**Dependencies**: LT015
**Note**: This is a comprehensive test of the complete script

---

## Phase 4: Documentation (Parallel)

### LT017 [P]: Create Local Testing Guide
**File**: `specs/001-create-a-comprehensive/local-testing.md`
**Description**: Create comprehensive user guide for local testing
**Content**:
```markdown
# Local Testing Guide

## Overview

Test the media automation stack locally before deploying to Portainer.

## Quick Start

\`\`\`bash
# Run full test (creates temp dirs, deploys, validates, cleans up)
./scripts/test-stack.sh starr

# Keep stack running for manual inspection
./scripts/test-stack.sh starr --keep-running

# Verbose output
./scripts/test-stack.sh starr --verbose
\`\`\`

## What Gets Tested

1. ✅ Docker Compose syntax validation
2. ✅ All 9 services start successfully
3. ✅ Services reach healthy state (or running for services without health checks)
4. ✅ Network isolation (separate test network)
5. ✅ Volume mounts work correctly
6. ✅ Environment variable substitution

## Test Environment

**Temporary directories created**:
- \`/tmp/starr-test-{timestamp}/config/\` - Service configurations
- \`/tmp/starr-test-{timestamp}/media/\` - Media and downloads

**Network**: \`starr_net_test_{pid}\` (isolated from production)

**Configuration**: \`stacks/stack-test.env\` (safe defaults, no secrets)

## Cleanup

Automatic cleanup happens on:
- ✅ Test success
- ✅ Test failure
- ✅ Ctrl+C interrupt

Unless \`--keep-running\` flag is used.

## Troubleshooting

### Test Fails with Timeout

- Check Docker daemon: \`docker info\`
- Increase timeout in script if needed
- Check logs: \`docker compose -f stacks/starr.yaml --env-file stacks/stack-test.env logs\`

### Port Conflicts

Test uses same ports as production. Ensure production stack not running locally.

### Permission Errors

Ensure your user can run Docker:
\`\`\`bash
sudo usermod -aG docker $USER
# Log out and back in
\`\`\`

## Integration with CI/CD

\`\`\`yaml
# Example GitHub Actions
- name: Test Stack
  run: ./scripts/test-stack.sh starr
\`\`\`

## Differences from Production

| Aspect | Local Test | Production (Portainer) |
|--------|------------|------------------------|
| Directories | \`/tmp/starr-test-*/\` | \`/mnt/dpool/\`, \`/mnt/spool/\` |
| Network | \`starr_net_test_*\` | \`starr_net\` |
| Config | \`stack-test.env\` | \`stack.env\` (secrets) |
| Cleanup | Automatic | Manual (via Portainer) |
| Tunnel | Fake token | Real Cloudflare token |
\`\`\`
```
**Validation**: Documentation is clear and accurate
**Dependencies**: LT016 (script must be tested first)
**Note**: Can run in parallel with LT018, LT019. The script now validates `jq` prerequisite automatically (see LT009)

### LT018 [P]: Update Main README with Testing Section
**File**: `README.md`
**Description**: Add Local Testing section to main README
**Location**: After "Quick Start: Media Automation Stack" section
**Content**:
```markdown
## Local Testing

Before deploying to Portainer, you can test the stack locally:

\`\`\`bash
# Quick test
./scripts/test-stack.sh starr

# Keep running for inspection
./scripts/test-stack.sh starr --keep-running
\`\`\`

**What it does:**
- Creates temporary directories in \`/tmp/starr-test-{timestamp}/\`
- Deploys all 9 services with test configuration
- Validates services reach healthy state
- Automatically cleans up containers and temp files

**See**: [Local Testing Guide](specs/001-create-a-comprehensive/local-testing.md) for details

**Requirements:**
- Docker Engine 20.10+
- \`jq\` for JSON parsing: \`sudo dnf install jq\` (Fedora) or \`sudo apt install jq\` (Ubuntu)
\`\`\`
```
**Validation**: Section renders correctly and links work
**Dependencies**: LT017 (guide must exist for link)
**Note**: Can run in parallel with LT017, LT019. LT008 will add an "Environment Differences" subsection within this section

### LT019 [P]: Update AGENTS.md Context
**File**: `AGENTS.md`
**Description**: Add local testing information to agent context
**Location**: After "### Stack-Specific Notes" section
**Content**:
```markdown
### Local Testing

**Test Script**: \`scripts/test-stack.sh\`
- **Purpose**: Validate stack configuration locally before Portainer deployment
- **Usage**: \`./scripts/test-stack.sh starr [--keep-running] [--verbose]\`
- **Test Environment**: Uses \`stacks/stack-test.env\` with temporary directories
- **Validation**: All 9 services must reach healthy/running state
- **Cleanup**: Automatic (removes containers and temp files)

**Environment Parameterization**:
- Host paths now use environment variables:
  - \`STARR_CONFIG_ROOT\` - base config directory
  - \`STARR_MEDIA_ROOT\` - base media directory
  - \`STARR_NETWORK_NAME\` - network name
- **Production**: Uses \`stacks/stack.env\` (not committed)
- **Testing**: Uses \`stacks/stack-test.env\` (committed, safe defaults)
- **Backward Compatible**: Defaults to original paths if variables not set

**Test Workflow**:
1. Edit \`stacks/starr.yaml\`
2. Run \`./scripts/test-stack.sh starr\` to validate locally
3. If tests pass, deploy to Portainer with confidence

**Troubleshooting Tests**:
- Timeout waiting for healthy: Check \`docker compose logs\`
- Port conflicts: Ensure no production stack running locally
- Permission errors: Ensure user in docker group
\`\`\`
**Validation**: Information accurate and helpful for agents
**Dependencies**: LT017, LT018 (other docs referenced)
**Note**: Can run in parallel with LT017, LT018

---

## Phase 5: Validation

### LT020: Validate Full Test Cycle
**File**: N/A (validation task)
**Description**: Run complete test cycle and verify all services reach healthy state
**Commands**:
```bash
# Clean environment (ensure no existing containers)
docker ps -a | grep starr && echo "Warning: Existing starr containers found"

# Run test
time ./scripts/test-stack.sh starr

# Verify results
echo "Exit code: $?"
ls /tmp/starr-test-* 2>/dev/null && echo "ERROR: Temp dir not cleaned" || echo "✓ Cleanup successful"
docker ps -a | grep starr_net_test && echo "ERROR: Test containers still running" || echo "✓ Containers cleaned"
```
**Expected**:
- Exit code: 0
- All 9 services healthy
- No temp directories remain
- No test containers remain
- Total time: < 10 minutes
**Dependencies**: LT016, LT017, LT018, LT019

### LT021: Validate Cleanup on Success
**File**: N/A (validation task)
**Description**: Verify automatic cleanup removes all test artifacts after successful test
**Commands**:
```bash
# Run test and capture temp dir location
./scripts/test-stack.sh starr 2>&1 | tee test-output.log

# Extract temp dir path from output
TEMP_DIR=$(grep "Base:" test-output.log | awk '{print $3}')
echo "Temp directory was: $TEMP_DIR"

# Verify cleanup
[ -d "$TEMP_DIR" ] && echo "❌ FAIL: Temp dir exists" || echo "✅ PASS: Temp dir cleaned"

# Verify containers cleaned
docker ps -a --format "{{.Names}}" | grep -E "(prowlarr|sonarr|radarr)" && echo "❌ FAIL: Containers exist" || echo "✅ PASS: Containers cleaned"

# Verify network cleaned
docker network ls | grep "starr_net_test" && echo "❌ FAIL: Test network exists" || echo "✅ PASS: Network cleaned"

rm test-output.log
```
**Expected**: All cleanup verifications pass
**Dependencies**: LT020

### LT022: Validate Cleanup on Failure
**File**: N/A (validation task)
**Description**: Verify cleanup runs even when test fails (e.g., timeout)
**Commands**:
```bash
# Modify script temporarily to force timeout
cp scripts/test-stack.sh scripts/test-stack.sh.bak
sed -i 's/TIMEOUT=300/TIMEOUT=5/' scripts/test-stack.sh

# Run test (will timeout and fail)
./scripts/test-stack.sh starr
EXIT_CODE=$?

echo "Exit code: $EXIT_CODE (should be 1)"

# Verify cleanup still ran
ls /tmp/starr-test-* 2>/dev/null && echo "❌ FAIL: Temp dir exists" || echo "✅ PASS: Temp dir cleaned"
docker ps -a | grep starr_net_test && echo "❌ FAIL: Containers exist" || echo "✅ PASS: Containers cleaned"

# Restore original script
mv scripts/test-stack.sh.bak scripts/test-stack.sh
```
**Expected**: 
- Exit code: 1 (failure)
- Cleanup still runs successfully
- No temp dirs or containers remain
**Dependencies**: LT021

### LT023: Validate --keep-running Flag
**File**: N/A (validation task)
**Description**: Verify --keep-running flag leaves stack running and provides cleanup instructions
**Commands**:
```bash
# Run with --keep-running
./scripts/test-stack.sh starr --keep-running 2>&1 | tee keep-running-output.log

# Verify stack still running
docker ps --format "{{.Names}}" | grep -E "(prowlarr|sonarr|radarr)" && echo "✅ Stack still running" || echo "❌ Stack not running"

# Verify temp dir exists
ls /tmp/starr-test-* 2>/dev/null && echo "✅ Temp dir exists" || echo "❌ Temp dir not found"

# Verify instructions printed
grep "To stop:" keep-running-output.log && echo "✅ Cleanup instructions provided" || echo "❌ No instructions"

# Extract cleanup command and run it
CLEANUP_CMD=$(grep "docker compose" keep-running-output.log | grep "down -v")
echo "Running: $CLEANUP_CMD"
eval $CLEANUP_CMD

# Verify cleanup worked
docker ps -a | grep starr_net_test && echo "❌ Containers still exist" || echo "✅ Containers cleaned"

rm keep-running-output.log
```
**Expected**:
- Stack runs successfully
- Stack left running after test
- Cleanup instructions displayed
- Manual cleanup works
**Dependencies**: LT022

### LT024: Validate Production Deployment Unaffected
**File**: N/A (validation task)
**Description**: Verify parameterization doesn't break existing production deployment workflow
**Commands**:
```bash
# Validate production config syntax
docker compose -f stacks/starr.yaml --env-file stacks/stack.env config --quiet
echo "Production config: $?"

# Verify default values work (simulate missing env vars)
unset STARR_CONFIG_ROOT STARR_MEDIA_ROOT STARR_NETWORK_NAME
docker compose -f stacks/starr.yaml --env-file stacks/stack.env config | grep -E "(mnt/spool|mnt/dpool|starr_net)" && echo "✅ Defaults work" || echo "❌ Defaults broken"

# Verify validation script still works
./scripts/validate-stack.sh starr
echo "Validation script: $?"

# Check quickstart.md deployment steps unchanged
grep -A 5 "Deploy via Portainer" specs/001-create-a-comprehensive/quickstart.md | grep -q "Upload" && echo "✅ Deployment docs unchanged" || echo "⚠️ Check deployment docs"
```
**Expected**:
- All commands exit with 0
- Production config validates
- Defaults to original paths
- Validation script works
- Deployment documentation still accurate
**Dependencies**: LT023
**Note**: This is the final validation - ensures we didn't break anything

---

## Enhancement Dependencies

**Critical Path**:
```
LT001 (env vars) → LT002-LT005 (parameterize) → LT006 (validate) →
  LT007 (test env) → LT008 (docs) →
    LT009-LT016 (test script) →
      [LT017 + LT018 + LT019] (parallel docs) →
        LT020-LT024 (validation)
```

**Parallel Opportunities**:
- LT017, LT018, LT019 (documentation tasks - different files)

**Blocking Dependencies**:
- LT006 must pass before test environment creation (ensure parameterization works)
- LT016 must pass before documentation (ensure script works)
- All implementation tasks must complete before final validation

---

## Enhancement Notes

### Implementation Strategy
- **Backward Compatibility First**: Use `${VAR:-default}` syntax to maintain existing behavior
- **Test Incrementally**: Validate after each parameterization phase
- **Script Development**: Build test script incrementally, test each phase
- **Document As You Go**: Update docs while changes are fresh

### Testing Approach
- **Syntax First**: Validate compose file after each parameterization task
- **Script Testing**: Test each script component independently before integration
- **End-to-End**: Run full test cycle multiple times
- **Edge Cases**: Test --keep-running, Ctrl+C, timeouts, failures

### Common Pitfalls to Avoid
- ❌ Forgetting backward compatibility (use `:-` defaults)
- ❌ Not testing cleanup on failure scenarios
- ❌ Hardcoding paths in test script (use variables)
- ❌ Not validating production deployment after changes
- ❌ Missing `jq` dependency (document in README)

### Success Criteria
✅ Local test script completes in < 10 minutes  
✅ All 9 services reach healthy state  
✅ Automatic cleanup removes all artifacts  
✅ --keep-running flag works for debugging  
✅ Production deployment unchanged  
✅ Documentation complete and accurate  
✅ CI/CD ready (exit codes correct)

---

## Enhancement Validation Checklist

- [ ] LT001-LT006: Parameterization complete and validated
- [ ] LT007-LT008: Test environment configured and documented
- [ ] LT009-LT016: Test script complete and functional
- [ ] LT017-LT019: Documentation updated (parallel)
- [ ] LT020: Full test cycle passes
- [ ] LT021: Cleanup validated on success
- [ ] LT022: Cleanup validated on failure
- [ ] LT023: --keep-running flag validated
- [ ] LT024: Production deployment validated

---

**Enhancement Total**: 24 tasks (LT001-LT024)
**Estimated Completion Time**: 4-6 hours
**Ready for Execution**: Yes ✓

**Previous Implementation**: 30 tasks (T001-T027) - COMPLETE
**Combined Total**: 54 tasks
