# Research: Media Automation Stack

**Date**: 2025-09-29  
**Purpose**: Container image selection, network topology, and integration patterns for Starr apps stack

## Container Image Selection

### Decision Matrix

| Service      | Image Source          | Current Version | Rationale |
|--------------|----------------------|-----------------|-----------|
| Sonarr       | ghcr.io/hotio/sonarr | 4.0.0          | Hotio maintains optimized Starr app images with proper permissions handling |
| Radarr       | ghcr.io/hotio/radarr | 5.2.0          | Consistent with Sonarr, same maintainer ensures compatibility |
| Prowlarr     | ghcr.io/hotio/prowlarr | 1.11.0       | Latest stable, critical for indexer management |
| Sabnzbd      | ghcr.io/hotio/sabnzbd | 4.2.0         | Well-maintained Usenet client with proper volume handling |
| qBittorrent  | ghcr.io/hotio/qbittorrent | 4.6.0     | Includes VueTorrent UI, proper permissions for media paths |
| Flaresolverr | ghcr.io/flaresolverr/flaresolverr | 3.3.16 | Official image, Cloudflare bypass capability |
| Unpackerr    | ghcr.io/hotio/unpackerr | 0.12.0      | Automatic archive extraction for completed downloads |
| Recyclarr    | ghcr.io/recyclarr/recyclarr | 6.0.0    | Official image, TRaSH Guides integration for settings sync |
| Cloudflared  | cloudflare/cloudflared | 2024.1.0   | Official Cloudflare Tunnel client |

### Version Strategy

**Semantic Versioning**: All images use semantic tags (e.g., `4.0.0` not `latest`) to ensure:
- Reproducible deployments
- Automated dependency update detection (Dependabot, Renovate)
- Controlled version upgrades with change review

**Tag Format**: `ghcr.io/hotio/<service>:<major>.<minor>.<patch>`

### Compatibility Notes

- **Sonarr v4**: Requires Prowlarr for indexer management (no native indexer support)
- **Radarr v5**: Requires Prowlarr for indexer management  
- **Prowlarr**: Must be configured before Sonarr/Radarr can search
- **qBittorrent v4.6+**: Changed API authentication - Sonarr/Radarr must use correct credentials
- **Recyclarr v6**: Uses new TRaSH Guides API, supports both Sonarr v4 and Radarr v5

## Network Topology

### Network Design

```
┌─────────────── starr_net (bridge) ───────────────┐
│                                                    │
│  ┌──────────┐         ┌──────────┐               │
│  │ Prowlarr │────────▶│  Sonarr  │               │
│  │  :9696   │         │  :8989   │               │
│  └────┬─────┘         └────┬─────┘               │
│       │                    │                      │
│       │               ┌────▼─────┐               │
│       └──────────────▶│  Radarr  │               │
│                       │  :7878   │               │
│                       └────┬─────┘               │
│                            │                      │
│       ┌────────────────────┴──────────────┐      │
│       │                                    │      │
│  ┌────▼─────┐                    ┌────────▼───┐  │
│  │ Sabnzbd  │                    │ qBittorrent │  │
│  │  :8080   │                    │   :8080     │  │
│  └────┬─────┘                    └────┬────────┘  │
│       │                               │           │
│       └───────────┬───────────────────┘           │
│                   │                               │
│             ┌─────▼──────┐                        │
│             │ Unpackerr  │                        │
│             │ (no port)  │                        │
│             └────────────┘                        │
│                                                    │
│  ┌──────────────┐      ┌──────────────┐          │
│  │ Flaresolverr │◀─────│  Recyclarr   │          │
│  │    :8191     │      │  (periodic)  │          │
│  └──────────────┘      └──────────────┘          │
│                                                    │
│  ┌──────────────────────────────────────┐         │
│  │          Cloudflared Tunnel          │         │
│  │  (routes to all web UIs via tunnel)  │         │
│  └──────────────────────────────────────┘         │
└────────────────────────────────────────────────────┘
                       │
                       │ 6881/tcp, 6881/udp
                       ▼
                  Host Network
                (BitTorrent peers only)
```

### Service Communication Patterns

| From Service | To Service    | Protocol | Purpose |
|--------------|---------------|----------|---------|
| Sonarr       | Prowlarr      | HTTP API | Search indexers |
| Radarr       | Prowlarr      | HTTP API | Search indexers |
| Sonarr       | Sabnzbd       | HTTP API | Add Usenet downloads |
| Sonarr       | qBittorrent   | HTTP API | Add torrent downloads |
| Radarr       | Sabnzbd       | HTTP API | Add Usenet downloads |
| Radarr       | qBittorrent   | HTTP API | Add torrent downloads |
| Prowlarr     | Flaresolverr  | HTTP API | Bypass Cloudflare protection |
| Unpackerr    | Sabnzbd       | HTTP API | Monitor download completion |
| Unpackerr    | qBittorrent   | HTTP API | Monitor download completion |
| Recyclarr    | Sonarr        | HTTP API | Sync settings/formats |
| Recyclarr    | Radarr        | HTTP API | Sync settings/formats |
| Cloudflared  | All services  | HTTP     | Tunnel routing to web UIs |

### Network Configuration

```yaml
networks:
  starr_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```

**DNS Resolution**: Docker's built-in DNS allows services to resolve each other by service name (e.g., `http://prowlarr:9696`)

## Volume Mount Strategy

### Path Conventions

Following existing Plex stack patterns:

| Purpose | Host Path | Container Path | Access |
|---------|-----------|----------------|--------|
| Media Library | `/mnt/dpool/media` | `/media` | RW (all) |
| TV Shows | `/mnt/dpool/media/tv` | `/media/tv` | RW (Sonarr) |
| Movies | `/mnt/dpool/media/movies` | `/media/movies` | RW (Radarr) |
| Downloads | `/mnt/dpool/media/downloads` | `/downloads` | RW (clients) |
| Usenet Downloads | `/mnt/dpool/media/downloads/usenet` | `/downloads/usenet` | RW (Sabnzbd) |
| Torrent Downloads | `/mnt/dpool/media/downloads/torrents` | `/downloads/torrents` | RW (qBittorrent) |

### Configuration Paths

| Service | Host Config Path | Container Path |
|---------|------------------|----------------|
| Sonarr | `/mnt/spool/apps/config/sonarr` | `/config` |
| Radarr | `/mnt/spool/apps/config/radarr` | `/config` |
| Prowlarr | `/mnt/spool/apps/config/prowlarr` | `/config` |
| Sabnzbd | `/mnt/spool/apps/config/sabnzbd` | `/config` |
| qBittorrent | `/mnt/spool/apps/config/qbittorrent` | `/config` |
| Unpackerr | `/mnt/spool/apps/config/unpackerr` | `/config` |
| Recyclarr | `/mnt/spool/apps/config/recyclarr` | `/config` |
| Cloudflared | `/mnt/spool/apps/config/cloudflared` | `/etc/cloudflared` |

### Permission Handling

**PUID/PGID Environment Variables**: All Hotio images support these for proper file ownership:
```env
PUID=1000  # User ID for file operations
PGID=1000  # Group ID for file operations
```

**Directory Creation**: Host directories must exist before container startup to avoid permission issues.

## Environment Variable Schema

### Common Variables (All Services)

```env
# Timezone for logging and scheduling
TZ=America/New_York

# User/Group IDs for file permissions
PUID=1000
PGID=1000

# Umask for created files (0002 = rwxrwxr-x)
UMASK=0002
```

### Service-Specific Variables

**Sonarr**:
```env
SONARR_API_KEY=<generated_on_first_run>
```

**Radarr**:
```env
RADARR_API_KEY=<generated_on_first_run>
```

**Prowlarr**:
```env
PROWLARR_API_KEY=<generated_on_first_run>
```

**Sabnzbd**:
```env
SABNZBD_API_KEY=<configured_manually>
SABNZBD_NZB_KEY=<configured_manually>
```

**qBittorrent**:
```env
QBITTORRENT_WEBUI_PORT=8080
# Username/password configured in UI on first run
```

**Cloudflared**:
```env
TUNNEL_TOKEN=<from_cloudflare_dashboard>
```

**Recyclarr**:
```env
RECYCLARR_API_KEY_SONARR=<from_sonarr>
RECYCLARR_API_KEY_RADARR=<from_radarr>
```

## Cloudflare Tunnel Integration

### Tunnel Configuration Pattern

**Service**: `cloudflared` container runs Cloudflare Tunnel client

**Routing Configuration**: Tunnel routes external requests to internal service web UIs

```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: sonarr.example.com
    service: http://sonarr:8989
  - hostname: radarr.example.com
    service: http://radarr:7878
  - hostname: prowlarr.example.com
    service: http://prowlarr:9696
  - hostname: sabnzbd.example.com
    service: http://sabnzbd:8080
  - hostname: qbittorrent.example.com
    service: http://qbittorrent:8080
  - service: http_status:404
```

**Cloudflare Access**: Zero Trust authentication layer configured per hostname in Cloudflare dashboard

### Setup Requirements

1. Cloudflare account with domain
2. Tunnel created in Cloudflare dashboard
3. Tunnel token obtained
4. DNS CNAME records pointing hostnames to tunnel
5. Cloudflare Access policies created for authentication

## Service Health Checks

### Health Check Endpoints

| Service | Health Check | Command |
|---------|-------------|---------|
| Sonarr | GET /ping | `curl -f http://localhost:8989/ping` |
| Radarr | GET /ping | `curl -f http://localhost:7878/ping` |
| Prowlarr | GET /ping | `curl -f http://localhost:9696/ping` |
| Sabnzbd | GET /api?mode=version | `curl -f http://localhost:8080/api?mode=version` |
| qBittorrent | GET /api/v2/app/version | `curl -f http://localhost:8080/api/v2/app/version` |
| Flaresolverr | GET /health | `curl -f http://localhost:8191/health` |
| Unpackerr | Process running | `pgrep unpackerr` |
| Recyclarr | N/A (periodic) | N/A |
| Cloudflared | Process running | `pgrep cloudflared` |

### Health Check Configuration

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:<port>/<endpoint>"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

## Startup Order Dependencies

### Dependency Graph

```
Prowlarr (indexers)
    ↓
    ├── Sonarr (TV) ──┐
    │                 │
    └── Radarr (Movies)──┘
            ↓
    ┌───────┴───────┐
    │               │
Sabnzbd       qBittorrent
(Usenet)      (Torrents)
    │               │
    └───────┬───────┘
            ↓
        Unpackerr
      (Extraction)

Flaresolverr (independent, used by Prowlarr)
Recyclarr (periodic, depends on Sonarr/Radarr APIs)
Cloudflared (independent, routes to all)
```

### Compose Dependencies

```yaml
depends_on:
  sonarr:
    prowlarr:
      condition: service_healthy
  radarr:
    prowlarr:
      condition: service_healthy
  unpackerr:
    sabnzbd:
      condition: service_started
    qbittorrent:
      condition: service_started
```

## Key Findings Summary

### Decisions Made

1. **Container Registry**: Use `ghcr.io/hotio` for all Starr apps and download clients
2. **Network**: Single bridge network `starr_net` with Docker DNS resolution
3. **Version Strategy**: Semantic tags inline in compose file (no env vars for versions)
4. **Port Exposure**: Only qBittorrent peer ports 6881 published; all web UIs via tunnel
5. **Volume Strategy**: Consistent paths matching existing Plex library structure
6. **Permission Handling**: PUID/PGID environment variables for all services
7. **Health Checks**: HTTP endpoint checks for services with web UIs
8. **Startup Order**: Prowlarr → Sonarr/Radarr → Download Clients → Unpackerr

### Rationale

- **Hotio Images**: Community-trusted, optimized for media automation, consistent PUID/PGID support
- **Single Network**: Simplifies service discovery, no need for external networking
- **Inline Versions**: Enables automated dependency update detection by Dependabot
- **Minimal Port Exposure**: Security best practice, only essential peer ports published
- **Existing Path Reuse**: Seamless integration with existing Plex media library
- **Health-Based Dependencies**: Ensures services fully ready before dependent services start

### Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| linuxserver.io images | Hotio images have better Starr app integration and update frequency |
| Multiple networks | Unnecessary complexity for internal-only communication |
| `latest` tags | Breaks automated update detection, unpredictable deployments |
| VPN for remote access | Cloudflare Tunnel provides Zero Trust auth without VPN overhead |
| Direct host port exposure | Security risk, violates requirement for tunnel-only access |

---

**Status**: Research complete. Ready for Phase 1 design.

