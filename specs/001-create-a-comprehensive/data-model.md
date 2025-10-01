# Data Model: Media Automation Stack

**Date**: 2025-09-29  
**Purpose**: Service configuration schema and Docker Compose entity definitions

## Overview

This document defines the configuration schema for all services in the media automation stack. Unlike traditional data models with database entities, this infrastructure stack uses Docker Compose declarative configuration as the data model.

## Entity Definitions

### Service Definition

Represents a containerized service in the Docker Compose stack.

**Attributes**:
- `service_name` (string): Unique identifier for the service
- `image` (string): Container image with semantic version tag
- `container_name` (string): Human-readable container name
- `environment` (map): Environment variables (may reference `stack.env`)
- `volumes` (list): Host-to-container path mappings
- `networks` (list): Network attachments
- `ports` (list, optional): Host-to-container port mappings
- `depends_on` (map, optional): Service dependencies with conditions
- `healthcheck` (map, optional): Health check configuration
- `restart` (string): Restart policy (default: `unless-stopped`)

**Example**:
```yaml
sonarr:
  image: ghcr.io/hotio/sonarr:4.0.0
  container_name: sonarr
  environment:
    TZ: ${TZ}
    PUID: ${PUID}
    PGID: ${PGID}
  volumes:
    - /mnt/spool/apps/config/sonarr:/config
    - /mnt/dpool/media:/media
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
  restart: unless-stopped
```

### Environment Variable

Represents a configurable parameter for service behavior.

**Attributes**:
- `name` (string): Variable name (UPPER_SNAKE_CASE)
- `value` (string | number | boolean): Variable value
- `source` (enum): `env_file` | `inline` | `secret`
- `required` (boolean): Whether variable must be set
- `description` (string): Purpose and usage notes
- `default` (string, optional): Default value if not set

**Categories**:

1. **Common Variables** (applies to all services):
   - `TZ`: Timezone for scheduling and logging
   - `PUID`: User ID for file operations
   - `PGID`: Group ID for file operations
   - `UMASK`: File creation mask

2. **Service-Specific Variables**:
   - API keys (generated on first run or configured manually)
   - Service-specific ports
   - Feature toggles

### Volume Mount

Represents a bind mount from host to container filesystem.

**Attributes**:
- `host_path` (string): Absolute path on host system
- `container_path` (string): Absolute path in container
- `mode` (enum): `rw` (read-write) | `ro` (read-only)
- `purpose` (string): Description of what data is stored
- `ownership` (string): Expected PUID:PGID ownership

**Categories**:

1. **Configuration Volumes** (persistent service state):
   - Pattern: `/mnt/spool/apps/config/<service>:/config:rw`
   - Contains: databases, settings, API keys, logs
   - Ownership: PUID:PGID from environment

2. **Media Volumes** (shared media library):
   - Pattern: `/mnt/dpool/media:/media:rw`
   - Contains: TV shows, movies, organized media
   - Ownership: PUID:PGID from environment

3. **Download Volumes** (temporary staging):
   - Pattern: `/mnt/dpool/media/downloads:/downloads:rw`
   - Contains: In-progress and completed downloads
   - Ownership: PUID:PGID from environment

### Network

Represents Docker network for service communication.

**Attributes**:
- `name` (string): Network name (`starr_net`)
- `driver` (string): Network driver (`bridge`)
- `internal` (boolean): Whether external connectivity allowed
- `ipam` (map, optional): IP address management configuration

**Configuration**:
```yaml
networks:
  starr_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```

**DNS Resolution**: Services resolve each other by service name (e.g., `http://prowlarr:9696`)

### Port Mapping

Represents network port exposure from container to host.

**Attributes**:
- `host_port` (integer): Port on host system
- `container_port` (integer): Port inside container
- `protocol` (enum): `tcp` | `udp`
- `purpose` (string): What service the port provides
- `exposure` (enum): `published` (host-accessible) | `internal` (network-only)

**Port Allocation Table**:

| Service      | Container Port | Host Port | Protocol | Exposure  | Purpose              |
|--------------|----------------|-----------|----------|-----------|----------------------|
| Sonarr       | 8989           | -         | tcp      | internal  | Web UI (tunnel only) |
| Radarr       | 7878           | -         | tcp      | internal  | Web UI (tunnel only) |
| Prowlarr     | 9696           | -         | tcp      | internal  | Web UI (tunnel only) |
| Sabnzbd      | 8080           | -         | tcp      | internal  | Web UI (tunnel only) |
| qBittorrent  | 8080           | -         | tcp      | internal  | Web UI (tunnel only) |
| qBittorrent  | 6881           | 6881      | tcp      | published | BitTorrent peers     |
| qBittorrent  | 6881           | 6881      | udp      | published | BitTorrent DHT       |
| Flaresolverr | 8191           | -         | tcp      | internal  | Proxy API            |

**Note**: Only qBittorrent peer ports are published to host. All web UIs accessible via Cloudflare Tunnel only.

### Dependency Relationship

Represents startup ordering and health dependencies between services.

**Attributes**:
- `dependent_service` (string): Service that depends on another
- `dependency_service` (string): Service that must be ready first
- `condition` (enum): `service_started` | `service_healthy` | `service_completed_successfully`

**Dependency Graph**:
```
Prowlarr (service_healthy)
    ↓
    ├─▶ Sonarr (service_healthy)
    │
    └─▶ Radarr (service_healthy)
            ↓
    ┌───────┴───────┐
    │               │
Sabnzbd       qBittorrent
(service_started) (service_started)
    │               │
    └───────┬───────┘
            ↓
      Unpackerr
```

### Health Check

Represents service readiness verification.

**Attributes**:
- `test` (list): Command to execute for health check
- `interval` (duration): Time between checks (e.g., `30s`)
- `timeout` (duration): Max time for check to complete (e.g., `10s`)
- `retries` (integer): Number of consecutive failures before unhealthy
- `start_period` (duration): Grace period for service startup (e.g., `60s`)

**Standard Configuration**:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:<port>/<endpoint>"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

## Service Configuration Schemas

### Media Management Services

#### Sonarr (TV Shows)

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

**Key Configuration**:
- Monitors TV shows for new episodes
- Searches via Prowlarr indexers
- Controls download clients (Sabnzbd, qBittorrent)
- Renames and organizes to `/media/tv/`

#### Radarr (Movies)

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

**Key Configuration**:
- Monitors movies for releases
- Searches via Prowlarr indexers
- Controls download clients (Sabnzbd, qBittorrent)
- Renames and organizes to `/media/movies/`

#### Prowlarr (Indexer Management)

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

**Key Configuration**:
- Aggregates multiple indexers (Usenet/torrent)
- Syncs indexers to Sonarr and Radarr
- Uses Flaresolverr for Cloudflare bypass
- Must start before Sonarr/Radarr

### Download Clients

#### Sabnzbd (Usenet)

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

**Key Configuration**:
- Processes Usenet (NZB) downloads
- Controlled by Sonarr/Radarr
- Priority: Usenet first (per clarifications)
- Auto-retry failed downloads up to 3 times

#### qBittorrent (Torrents)

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
  networks:
    - starr_net
  ports:
    - "6881:6881/tcp"
    - "6881:6881/udp"
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8080/api/v2/app/version"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 60s
  restart: unless-stopped
```

**Key Configuration**:
- Processes torrent downloads
- Controlled by Sonarr/Radarr
- Peer ports 6881/tcp and 6881/udp published to host
- Web UI (8080) internal only (accessed via tunnel)
- Fallback when Usenet unavailable

### Supporting Services

#### Flaresolverr (Cloudflare Bypass)

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

**Key Configuration**:
- Proxies requests to bypass Cloudflare protection
- Used by Prowlarr for protected indexers
- No persistent volumes needed

#### Unpackerr (Archive Extraction)

```yaml
unpackerr:
  image: ghcr.io/hotio/unpackerr:0.12.0
  container_name: unpackerr
  environment:
    TZ: ${TZ}
    PUID: ${PUID}
    PGID: ${PGID}
    UN_SONARR_0_URL: http://sonarr:8989
    UN_RADARR_0_URL: http://radarr:7878
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

**Key Configuration**:
- Automatically extracts compressed archives
- Monitors download clients for completion
- Validates and cleans up after extraction
- Notifies Sonarr/Radarr when ready

#### Recyclarr (Settings Sync)

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

**Key Configuration**:
- Syncs TRaSH Guides settings to Sonarr/Radarr
- Runs periodically (cron-style)
- Updates quality profiles and custom formats
- Preserves manual customizations

#### Cloudflared (Tunnel)

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

**Key Configuration**:
- Routes Cloudflare Tunnel to internal services
- Provides secure remote access without VPN
- Requires Cloudflare Access for authentication
- No persistent volumes needed (token in env)

## Configuration Validation Rules

### Required Checks

1. **Volume Paths Exist**: All host paths must exist before deployment
2. **PUID/PGID Match**: User/group IDs must match host filesystem ownership
3. **Network Connectivity**: All services on `starr_net` can resolve each other
4. **Health Checks Pass**: Services report healthy before dependents start
5. **Port Conflicts**: No host port conflicts (only 6881/tcp and 6881/udp used)
6. **Environment Variables Set**: All required variables in `stack.env`
7. **API Keys Generated**: Service API keys configured after first run
8. **Download Paths Accessible**: All services can write to download directories

### Configuration Dependencies

```
1. Create host directories
2. Set PUID/PGID in stack.env
3. Deploy compose stack
4. Wait for services to become healthy
5. Configure Prowlarr indexers
6. Add Prowlarr apps to Sonarr/Radarr
7. Configure download clients in Sonarr/Radarr
8. Configure Recyclarr with API keys
9. Configure Cloudflare Tunnel routing
10. Test end-to-end workflow
```

---

**Status**: Data model complete. Service schemas defined. Ready for contract generation.

