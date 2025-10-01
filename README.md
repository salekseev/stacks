# Self-Hosted Docker Stacks

This repository contains Docker Compose configurations for self-hosting various services. Each "stack" is a collection of related services defined in a YAML file within the `stacks/` directory.

## Available Stacks

### Media Automation Stack (`stacks/starr.yaml`)

A comprehensive media automation solution for TV shows and movies, featuring:

**Services:**
- **Sonarr** - TV show monitoring and automation
- **Radarr** - Movie monitoring and automation  
- **Prowlarr** - Indexer management for Usenet/torrents
- **NZBGet** - Usenet download client (priority)
- **qBittorrent** - Torrent download client (fallback)
- **Flaresolverr** - Cloudflare bypass proxy
- **Unpackerr** - Automatic archive extraction
- **Recyclarr** - Settings synchronization (TRaSH Guides)
- **Cloudflare Tunnel** - Secure remote access with Zero Trust

**Features:**
- Automated TV show and movie discovery and downloading
- Usenet-first download strategy with torrent fallback
- Secure remote access via Cloudflare Tunnel (no VPN required)
- Automatic file extraction and organization
- Settings synchronization across services
- Complete network isolation (only BitTorrent peer ports exposed)

### Plex Media Server (`stacks/plex.yaml`)

Media streaming server with hardware transcoding support.

### Other Stacks

- `changedetection.yaml` - Website change monitoring
- `go2rtc.yaml` - Real-time video streaming
- `iperf3.yaml` - Network performance testing
- `scrypted.yaml` - Home automation platform
- `ser2net.yaml` - Serial to network proxy
- `zwave-js.yaml` - Z-Wave device integration

## Quick Start: Media Automation Stack

### Prerequisites

- **Portainer** installed and running on remote host
- Docker Engine 20.10+ on Portainer host
- Cloudflare account with domain for tunnel setup
- Access to Usenet provider and/or torrent indexers

### Deployment Steps

#### 1. Prepare Host Directories (on Portainer host)

SSH to your Portainer host and create required directories:

```bash
# SSH to Portainer host
ssh user@portainer-host

# Create media directories
sudo mkdir -p /mnt/dpool/media/{tv,movies,downloads/{usenet,torrents}}

# Create configuration directories
sudo mkdir -p /mnt/spool/apps/config/{sonarr,radarr,prowlarr,nzbget,qbittorrent,flaresolverr,unpackerr,recyclarr,cloudflared}

# Get PUID/PGID (should match Plex stack: 1000/1000)
echo "PUID: $(id -u)"
echo "PGID: $(id -g)"

# Set ownership
sudo chown -R $(id -u):$(id -g) /mnt/dpool/media
sudo chown -R $(id -u):$(id -g) /mnt/spool/apps/config
```

#### 2. Configure Environment Variables (local machine)

Copy and edit the environment template:

```bash
# Copy template
cp stacks/stack.env stacks/stack.env.local

# Edit with your values
nano stacks/stack.env.local
```

**Required values:**
- `TZ=America/New_York` (or your timezone)
- `PUID=1000` (from Portainer host)
- `PGID=1000` (from Portainer host)
- `TUNNEL_TOKEN=` (from Cloudflare Dashboard → Zero Trust → Tunnels)

#### 3. Deploy via Portainer

1. **Access Portainer**: Navigate to your Portainer web UI
2. **Create Stack**: Go to **Stacks** → **+ Add stack**
3. **Configure**:
   - **Name**: `starr-media-automation`
   - **Build method**: **Web editor** (paste contents of `stacks/starr.yaml`)
4. **Environment Variables**:
   - Load from `.env file` (upload `stacks/stack.env.local`)
   - OR manually add each variable
5. **Deploy**: Click **Deploy the stack**
6. **Wait**: 2-3 minutes for all services to initialize

#### 4. Verify Deployment

In Portainer, check that all 9 containers show:
- ✅ Status: Running or Healthy
- ❌ No containers in "Exited" or "Restarting" state

#### 5. Initial Configuration

Access services via Cloudflare Tunnel and configure:

1. **Prowlarr** (indexer management):
   - Add Usenet and/or torrent indexers
   - Configure Flaresolverr proxy if needed
   - Copy API key from Settings → General → Security

2. **Sonarr** (TV shows):
   - Add Prowlarr as indexer app (sync from Prowlarr)
   - Configure download clients (NZBGet, qBittorrent)
   - Set root folder: `/media/tv`
   - Copy API key

3. **Radarr** (movies):
   - Add Prowlarr as indexer app (sync from Prowlarr)
   - Configure download clients (NZBGet, qBittorrent)
   - Set root folder: `/media/movies`
   - Copy API key

4. **Update Environment**:
   - Add API keys to `stacks/stack.env.local`:
     ```env
     SONARR_API_KEY=<from_sonarr>
     RADARR_API_KEY=<from_radarr>
     PROWLARR_API_KEY=<from_prowlarr>
     ```
   - Re-deploy stack in Portainer to apply changes

5. **Recyclarr** (optional):
   - SSH to Portainer host
   - Edit `/mnt/spool/apps/config/recyclarr/config.yml`
   - Add Sonarr and Radarr instances with API keys
   - Restart recyclarr container

## Architecture

### Network Topology

All services communicate on an isolated Docker bridge network (`starr_net`). DNS resolution allows services to reach each other by service name (e.g., `http://prowlarr:9696`).

**Port Exposure:**
- Only qBittorrent peer ports (`6881/tcp`, `6881/udp`) are published to the host
- All web UIs are accessible ONLY via Cloudflare Tunnel

### Storage Layout

```
/mnt/dpool/media/          # Shared media library (matches Plex)
├── tv/                    # Organized TV shows
├── movies/                # Organized movies
└── downloads/             # Temporary downloads
    ├── usenet/            # NZBGet downloads
    └── torrents/          # qBittorrent downloads

/mnt/spool/apps/config/    # Service configurations
├── sonarr/                # Sonarr config and database
├── radarr/                # Radarr config and database
├── prowlarr/              # Prowlarr config and database
├── nzbget/                # NZBGet config
├── qbittorrent/           # qBittorrent config
├── unpackerr/             # Unpackerr config
├── recyclarr/             # Recyclarr config
└── cloudflared/           # Cloudflare Tunnel config
```

### Service Dependencies

```
Prowlarr (indexers) → [Sonarr + Radarr] → [NZBGet + qBittorrent] → Unpackerr
                                ↓
                          Cloudflare Tunnel (secure remote access)
```

## Local Testing

Before deploying to Portainer, you can test the stack locally:

```bash
# Quick test
./scripts/test-stack.sh starr

# Keep running for inspection
./scripts/test-stack.sh starr --keep-running
```

**What it does:**
- Creates temporary directories in `/tmp/starr-test-{timestamp}/`
- Deploys all 9 services with test configuration
- Validates services reach healthy state
- Automatically cleans up containers and temp files

**See**: [Local Testing Guide](specs/001-create-a-comprehensive/local-testing.md) for details

### Environment Differences

The test environment (`stacks/stack-test.env`) differs from production (`stacks/stack.env`) in the following ways:

| Variable | Production (`stack.env`) | Test (`stack-test.env`) |
|----------|-------------------------|-------------------------|
| `STARR_CONFIG_ROOT` | `/mnt/spool/apps/config` | `/tmp/starr-test-{timestamp}/config` |
| `STARR_MEDIA_ROOT` | `/mnt/dpool/media` | `/tmp/starr-test-{timestamp}/media` |
| `STARR_NETWORK_NAME` | `starr_net` | `starr_net_test_{pid}` |
| `TUNNEL_TOKEN` | Real Cloudflare token | `test-token-not-real` |
| **Cleanup** | Manual (via Portainer) | Automatic (script) |
| **Deployment** | Portainer web UI | `docker compose` CLI |
| **Duration** | Permanent | Temporary |

**Key Benefits:**
- ✅ **Isolated Testing**: Test network and directories don't interfere with production
- ✅ **Safe Defaults**: No production secrets required
- ✅ **Automatic Cleanup**: Containers and temp files removed after testing
- ✅ **Fast Validation**: Catch configuration errors before Portainer deployment

## Troubleshooting

### Permission Errors

```bash
# On Portainer host, verify ownership:
ls -la /mnt/dpool/media
ls -la /mnt/spool/apps/config

# Verify PUID/PGID matches:
id
```

### Services Won't Start

1. Check Portainer logs for specific container
2. Verify `TUNNEL_TOKEN` is set correctly
3. Ensure host directories exist with correct ownership
4. Check for port conflicts (6881 already in use?)

### Health Checks Failing

Wait 5 minutes - some services take time to initialize, especially on first run.

### Can't Access Web UIs

- Web UIs are NOT directly accessible
- Must access via Cloudflare Tunnel hostnames
- Verify tunnel is running: Check cloudflared container status
- Verify tunnel routing configured in Cloudflare Dashboard

### Prowlarr Can't Reach Indexers

- Check if indexers use Cloudflare protection
- Configure Flaresolverr proxy in Prowlarr settings
- Verify Flaresolverr container is healthy

## Maintenance

### Backup Configurations

```bash
# On Portainer host
tar -czf starr-backup-$(date +%Y%m%d).tar.gz \
  /mnt/spool/apps/config/{sonarr,radarr,prowlarr,nzbget,qbittorrent,unpackerr,recyclarr}
```

### Update Container Versions

1. Edit `stacks/starr.yaml` and update image tags
2. Re-deploy stack in Portainer
3. Portainer will pull new images and recreate containers

### View Logs

In Portainer:
- Navigate to stack → Select container → Logs

Or via SSH:
```bash
docker logs <container-name> -f
```

## Security

- No services exposed directly to internet
- All remote access via Cloudflare Tunnel with Zero Trust authentication
- Only BitTorrent peer ports published to host for connectivity
- API keys stored in environment variables, not in compose file
- PUID/PGID ensures proper file permissions

## Environment Variables Reference

See `stacks/stack.env` for complete list with descriptions.

**Common:**
- `TZ` - Timezone (default: America/New_York)
- `PUID` - User ID (default: 1000, matches Plex)
- `PGID` - Group ID (default: 1000, matches Plex)
- `UMASK` - File creation mask (default: 0002)

**Services:**
- `SONARR_API_KEY` - Generated on first run
- `RADARR_API_KEY` - Generated on first run
- `PROWLARR_API_KEY` - Generated on first run
- `TUNNEL_TOKEN` - From Cloudflare dashboard (required)

## Additional Resources

- [Detailed Quickstart Guide](specs/001-create-a-comprehensive/quickstart.md)
- [Service Port Allocation](specs/001-create-a-comprehensive/contracts/service-ports.md)
- [Data Model Documentation](specs/001-create-a-comprehensive/data-model.md)
- [Research and Design Decisions](specs/001-create-a-comprehensive/research.md)

## Contributing

To add a new stack:

1. Create YAML file in `stacks/`
2. Test deployment
3. Document configuration and usage
4. Update this README

## License

See [LICENSE](LICENSE) file for details.
