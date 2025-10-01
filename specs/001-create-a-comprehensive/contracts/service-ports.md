# Service Port Allocation

**Purpose**: Document all network ports used by services in the media automation stack

## Port Assignment Table

| Service      | Internal Port | Host Published | Protocol | Exposure  | Purpose                          | Access Method            |
|--------------|---------------|----------------|----------|-----------|----------------------------------|--------------------------|
| Sonarr       | 8989          | -              | TCP      | Internal  | Web UI                           | Cloudflare Tunnel        |
| Radarr       | 7878          | -              | TCP      | Internal  | Web UI                           | Cloudflare Tunnel        |
| Prowlarr     | 9696          | -              | TCP      | Internal  | Web UI                           | Cloudflare Tunnel        |
| Sabnzbd      | 8080          | -              | TCP      | Internal  | Web UI                           | Cloudflare Tunnel        |
| qBittorrent  | 8080          | -              | TCP      | Internal  | Web UI                           | Cloudflare Tunnel        |
| qBittorrent  | 6881          | 6881           | TCP      | Published | BitTorrent peer connections      | Direct (external peers)  |
| qBittorrent  | 6881          | 6881           | UDP      | Published | BitTorrent DHT                   | Direct (external peers)  |
| Flaresolverr | 8191          | -              | TCP      | Internal  | Proxy API                        | Prowlarr (internal)      |
| Unpackerr    | -             | -              | -        | N/A       | No network service               | N/A                      |
| Recyclarr    | -             | -              | -        | N/A       | No network service (periodic)    | N/A                      |
| Cloudflared  | -             | -              | -        | N/A       | Outbound tunnel only             | N/A                      |

## Port Details

### Web UI Ports (Internal Only)

All service web interfaces are **not published** to the host network. Access is provided exclusively via Cloudflare Tunnel with Zero Trust authentication.

**Sonarr - 8989/tcp**
- URL: `http://sonarr.example.com` (via tunnel)
- Purpose: TV show management interface
- API: `http://sonarr:8989/api/v3/`
- Health check: `GET http://sonarr:8989/ping`

**Radarr - 7878/tcp**
- URL: `http://radarr.example.com` (via tunnel)
- Purpose: Movie management interface
- API: `http://radarr:7878/api/v3/`
- Health check: `GET http://radarr:7878/ping`

**Prowlarr - 9696/tcp**
- URL: `http://prowlarr.example.com` (via tunnel)
- Purpose: Indexer management interface
- API: `http://prowlarr:9696/api/v1/`
- Health check: `GET http://prowlarr:9696/ping`

**Sabnzbd - 8080/tcp**
- URL: `http://sabnzbd.example.com` (via tunnel)
- Purpose: Usenet download client interface
- API: `http://sabnzbd:8080/api`
- Health check: `GET http://sabnzbd:8080/api?mode=version`
- **Note**: Port conflict with qBittorrent on same port (both internal only, no issue)

**qBittorrent Web UI - 8080/tcp**
- URL: `http://qbittorrent.example.com` (via tunnel)
- Purpose: Torrent client interface
- API: `http://qbittorrent:8080/api/v2/`
- Health check: `GET http://qbittorrent:8080/api/v2/app/version`
- **Note**: Port conflict with Sabnzbd on same port (both internal only, no issue)

**Flaresolverr - 8191/tcp**
- URL: Internal only (no external access needed)
- Purpose: Cloudflare bypass proxy for Prowlarr
- API: `http://flaresolverr:8191/v1`
- Health check: `GET http://flaresolverr:8191/health`
- Used by: Prowlarr for protected indexers

### Published Ports (Host Network)

Only qBittorrent peer communication ports are published to enable external BitTorrent connectivity.

**qBittorrent Peers - 6881/tcp**
- Purpose: Incoming BitTorrent peer connections
- Published: `0.0.0.0:6881 → container:6881/tcp`
- Required: Yes (for torrent protocol functionality)
- Security: Standard BitTorrent protocol, no authentication

**qBittorrent DHT - 6881/udp**
- Purpose: Distributed Hash Table for peer discovery
- Published: `0.0.0.0:6881 → container:6881/udp`
- Required: Yes (for torrent protocol functionality)
- Security: Standard BitTorrent DHT protocol

**Why only these ports?**
- BitTorrent requires inbound connections from external peers
- Web UIs accessed via secure Cloudflare Tunnel (no direct exposure)
- Reduces attack surface (principle of least privilege)

## Service-to-Service Communication

All inter-service communication occurs on the `starr_net` Docker bridge network using internal ports and Docker DNS.

### Communication Patterns

```
Sonarr (8989) ──HTTP API──> Prowlarr (9696)  [indexer search]
Sonarr (8989) ──HTTP API──> Sabnzbd (8080)   [add NZB download]
Sonarr (8989) ──HTTP API──> qBittorrent (8080) [add torrent]

Radarr (7878) ──HTTP API──> Prowlarr (9696)  [indexer search]
Radarr (7878) ──HTTP API──> Sabnzbd (8080)   [add NZB download]
Radarr (7878) ──HTTP API──> qBittorrent (8080) [add torrent]

Prowlarr (9696) ──HTTP API──> Flaresolverr (8191) [Cloudflare bypass]

Unpackerr ──HTTP API──> Sabnzbd (8080)       [monitor downloads]
Unpackerr ──HTTP API──> qBittorrent (8080)   [monitor downloads]
Unpackerr ──HTTP API──> Sonarr (8989)        [notify extraction complete]
Unpackerr ──HTTP API──> Radarr (7878)        [notify extraction complete]

Recyclarr ──HTTP API──> Sonarr (8989)        [sync settings]
Recyclarr ──HTTP API──> Radarr (7878)        [sync settings]

Cloudflared ──HTTP──> All Web UIs             [tunnel routing]
```

### DNS Resolution

Services resolve each other by container name on the `starr_net` network:
- `prowlarr` → `172.28.x.x:9696`
- `sonarr` → `172.28.x.x:8989`
- `radarr` → `172.28.x.x:7878`
- `sabnzbd` → `172.28.x.x:8080`
- `qbittorrent` → `172.28.x.x:8080`
- `flaresolverr` → `172.28.x.x:8191`

## Port Conflict Resolution

### Potential Conflicts

**Sabnzbd and qBittorrent both use 8080/tcp**
- **Resolution**: Both services only expose ports internally on `starr_net`
- No conflict because Docker assigns unique internal IPs
- External access via Cloudflare Tunnel uses different hostnames
- Example: `sabnzbd.example.com` → `http://sabnzbd:8080`
- Example: `qbittorrent.example.com` → `http://qbittorrent:8080`

### Host Port Availability

Before deployment, verify host ports are available:

```bash
# Check if 6881/tcp is in use
sudo netstat -tlnp | grep 6881

# Check if 6881/udp is in use  
sudo netstat -ulnp | grep 6881
```

If ports are in use, either:
1. Stop the conflicting service
2. Modify qBittorrent port in `stacks/starr.yaml` (change both host and container ports)

## Cloudflare Tunnel Routing

Cloudflared container routes external requests to internal services:

| External Hostname          | Internal Target          | Port |
|----------------------------|--------------------------|------|
| `sonarr.example.com`       | `http://sonarr:8989`     | 8989 |
| `radarr.example.com`       | `http://radarr:7878`     | 7878 |
| `prowlarr.example.com`     | `http://prowlarr:9696`   | 9696 |
| `sabnzbd.example.com`      | `http://sabnzbd:8080`    | 8080 |
| `qbittorrent.example.com`  | `http://qbittorrent:8080`| 8080 |

**Authentication**: Cloudflare Access Zero Trust policies enforce authentication before reaching services.

## Firewall Configuration

### Required Firewall Rules

**Inbound**:
- `6881/tcp` - Allow from internet (BitTorrent peers)
- `6881/udp` - Allow from internet (BitTorrent DHT)

**Outbound**:
- `443/tcp` - Allow to Cloudflare (tunnel connectivity)
- `119/tcp`, `563/tcp` - Allow to Usenet providers (Sabnzbd)
- `6881/tcp`, `6881/udp` - Allow to internet (BitTorrent peers)

**No rules needed for**:
- Service web UIs (not published to host)
- Internal service communication (Docker network handles)

### Example iptables Rules

```bash
# Allow qBittorrent peer connections
iptables -A INPUT -p tcp --dport 6881 -j ACCEPT
iptables -A INPUT -p udp --dport 6881 -j ACCEPT

# Allow Cloudflare Tunnel outbound
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# Allow Usenet connections
iptables -A OUTPUT -p tcp --dport 119 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 563 -j ACCEPT
```

## Security Considerations

### Attack Surface

**Minimized Exposure**:
- Only 2 ports published to host (6881/tcp, 6881/udp)
- Both ports are standard BitTorrent protocol (widely understood security profile)
- No authentication required for BitTorrent (by design)
- All management interfaces protected by Cloudflare Zero Trust

**Defense in Depth**:
1. Cloudflare Tunnel encrypts all web UI traffic
2. Cloudflare Access enforces authentication
3. Services run in isolated Docker network
4. Services run as non-root user (PUID/PGID)
5. No direct internet exposure for management interfaces

### Monitoring

**Port Activity Monitoring**:
```bash
# Monitor qBittorrent peer connections
watch -n 1 'netstat -an | grep 6881'

# Monitor Cloudflare Tunnel connectivity
docker logs -f cloudflared

# Monitor service health
docker-compose -f stacks/starr.yaml ps
```

---

**Last Updated**: 2025-09-29  
**Schema Version**: 1.0.0

