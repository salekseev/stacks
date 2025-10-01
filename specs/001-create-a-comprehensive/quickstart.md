# Quickstart: Media Automation Stack

**Purpose**: Step-by-step guide to deploy and validate the Starr apps media automation stack

## Prerequisites

### Required Software

- **Portainer**: Installed and running on remote host
  - Access to Portainer web UI
  - Permissions to create stacks
  
- **Docker Engine** (on Portainer host): 20.10.0 or later
- **Docker Compose** (on Portainer host): v2.0.0 or later

### Required Services

- **Cloudflare Account**: With domain and Zero Trust access
- **Cloudflare Tunnel**: Created and configured in dashboard
- **Usenet Provider** (optional but recommended): With credentials
- **Torrent Trackers** (optional): Access to indexers

### Host System Requirements

- **Portainer Host**: Remote server running Docker and Portainer
- **Storage**: Sufficient space on `/mnt/dpool` and `/mnt/spool` on Portainer host
- **Network**: Internet connectivity with ports 6881/tcp and 6881/udp available
- **SSH Access**: To Portainer host for directory setup (or Portainer console access)

## Step 1: Prepare Host Directories

**IMPORTANT**: These commands must be run on the **Portainer host** (remote server), not your local machine.

Connect to the Portainer host via SSH or use Portainer's console feature:

```bash
# SSH to Portainer host
ssh user@portainer-host

# Media directories
sudo mkdir -p /mnt/dpool/media/{tv,movies,downloads/{usenet,torrents}}

# Configuration directories
sudo mkdir -p /mnt/spool/apps/config/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,flaresolverr,unpackerr,recyclarr,cloudflared}

# Get PUID/PGID on THIS host (should match existing Plex stack: 1000/1000)
echo "PUID: $(id -u)"
echo "PGID: $(id -g)"

# Set ownership with the PUID/PGID from above
sudo chown -R $(id -u):$(id -g) /mnt/dpool/media
sudo chown -R $(id -u):$(id -g) /mnt/spool/apps/config

# Verify permissions
ls -la /mnt/dpool/media
ls -la /mnt/spool/apps/config
```

**Note**: PUID and PGID should match your existing Plex stack values (typically 1000/1000). You'll use these in `stack.env` configuration.

## Step 2: Configure Environment Variables

Create the environment file from template (on your local machine):

```bash
# Copy template
cp specs/001-create-a-comprehensive/contracts/env-schema.env stacks/stack.env

# Edit configuration
nano stacks/stack.env
# OR
vim stacks/stack.env
```

**Required Variables** (defaults match existing Plex stack):
```env
# Timezone (matches Plex stack)
TZ=America/New_York

# User/Group IDs (should match existing Plex stack: 1000/1000)
PUID=1000  # Verify matches Portainer host value from Step 1
PGID=1000  # Verify matches Portainer host value from Step 1

# File creation mask
UMASK=0002

# Cloudflare Tunnel Token (from dashboard)
TUNNEL_TOKEN=your_tunnel_token_here
```

**Save and close** the file. You'll upload this to Portainer in Step 4.

## Step 3: Validate Compose Configuration (Optional)

If you have docker-compose installed locally, you can validate syntax before uploading:

```bash
# Validate syntax (optional - Portainer will also validate)
docker-compose -f stacks/starr.yaml config

# Should output valid YAML without errors
```

If validation fails, check:
- YAML syntax (indentation, colons, dashes)
- File paths in volume mounts
- Environment variable references

**Note**: You can skip this step - Portainer will validate when you deploy.

## Step 4: Deploy via Portainer

### 4.1: Access Portainer

1. Open your web browser
2. Navigate to your Portainer URL (e.g., `https://portainer.example.com`)
3. Log in with your Portainer credentials
4. Select the environment where you want to deploy (the Docker host with directories from Step 1)

### 4.2: Create New Stack

1. Click **Stacks** in the left sidebar
2. Click **+ Add stack** button
3. Enter stack name: `starr-media-automation` (or your preferred name)

### 4.3: Upload Compose File

**Method A: Web Editor** (Copy/Paste)
1. Select **Web editor** tab
2. Open `stacks/starr.yaml` on your local machine
3. Copy entire contents
4. Paste into Portainer's web editor

**Method B: Upload** (File Upload)
1. Select **Upload** tab
2. Click **Select file**
3. Choose `stacks/starr.yaml` from your local machine

### 4.4: Configure Environment Variables

Scroll down to **Environment variables** section:

**Method A: Load from .env file**
1. Click **Load variables from .env file**
2. Upload your `stacks/stack.env` file
3. Portainer will parse and populate variables

**Method B: Manual entry**
1. Click **+ Add an environment variable** for each:
   - `TZ` = `America/New_York` (matches Plex stack)
   - `PUID` = `1000` (matches Plex stack, verify on Portainer host)
   - `PGID` = `1000` (matches Plex stack, verify on Portainer host)
   - `UMASK` = `0002`
   - `TUNNEL_TOKEN` = (from Cloudflare dashboard)
   - `SONARR_API_KEY` = (leave empty initially)
   - `RADARR_API_KEY` = (leave empty initially)
   - `PROWLARR_API_KEY` = (leave empty initially)

### 4.5: Deploy the Stack

1. Scroll to bottom
2. Click **Deploy the stack** button
3. Portainer will:
   - Validate compose syntax
   - Create network `starr_net`
   - Pull container images
   - Start all 9 services

**Expected Result**: 
- Stack status: ✅ Active
- All containers: 🟢 Running or 🟢 Healthy

## Step 5: Verify Service Startup

Monitor services as they start in Portainer:

### Via Portainer UI

1. **View Stack Status**:
   - Click on your stack name (`starr-media-automation`)
   - See all 9 containers listed
   - Wait 2-3 minutes for health checks to pass

2. **Check Container Status**:
   All services should show:
   - 🟢 **running** or 🟢 **healthy**
   
   Expected statuses:
   - `prowlarr` → 🟢 healthy
   - `sonarr` → 🟢 healthy
   - `radarr` → 🟢 healthy
   - `sabnzbd` → 🟢 healthy
   - `qbittorrent` → 🟢 healthy
   - `flaresolverr` → 🟢 healthy
   - `unpackerr` → 🟢 running
   - `recyclarr` → 🟢 running
   - `cloudflared` → 🟢 running

3. **View Logs**:
   - Click on any container name
   - Click **Logs** tab
   - Select **Auto-refresh** to watch in real-time
   - Check for errors or startup messages

### Via SSH (Alternative)

If you need command-line access:

```bash
# SSH to Portainer host
ssh user@portainer-host

# Check container status
docker ps --filter "label=com.docker.compose.project=starr-media-automation"

# View logs for specific service
docker logs prowlarr
docker logs sonarr
docker logs radarr
```

**Troubleshooting Unhealthy Services**:

1. **In Portainer**:
   - Click unhealthy container
   - Check **Logs** tab for errors
   - Check **Inspect** tab for configuration issues

2. **Common Issues**:
   - ❌ Permission denied: Check PUID/PGID match Portainer host
   - ❌ Port 6881 conflict: Check if port already in use
   - ❌ Health check timeout: Wait 5 minutes, some services are slow to start
   - ❌ Volume mount errors: Verify directories exist on Portainer host

## Step 6: Configure Cloudflare Tunnel

### Access Services

Services are now accessible via Cloudflare Tunnel:

| Service      | URL                                  |
|--------------|--------------------------------------|
| Prowlarr     | `https://prowlarr.example.com`       |
| Sonarr       | `https://sonarr.example.com`         |
| Radarr       | `https://radarr.example.com`         |
| Sabnzbd      | `https://sabnzbd.example.com`        |
| qBittorrent  | `https://qbittorrent.example.com`    |

Replace `example.com` with your actual domain.

### Cloudflare Access Policies

Ensure Cloudflare Access policies are configured for authentication:

1. **Cloudflare Dashboard** → **Zero Trust** → **Access** → **Applications**
2. **Create policies** for each hostname
3. **Authentication methods**:
   - One-time PIN (email)
   - Identity provider (Google, GitHub, etc.)
   - Per clarifications: Email verification or SSO

## Step 7: Initial Service Configuration

### 7.1 Configure Prowlarr (Indexer Management)

1. **Access**: `https://prowlarr.example.com`
2. **First Run Setup**:
   - Accept wizard prompts
   - Set authentication (recommended)
3. **Retrieve API Key**:
   - Settings → General → Security → API Key
   - Copy the generated key
4. **Add Indexers**:
   - Indexers → Add Indexer
   - Search for your indexers (e.g., NZBgeek, DrunkenSlug for Usenet)
   - Configure credentials
5. **Configure Flaresolverr** (for Cloudflare-protected indexers):
   - Settings → Indexers → Flaresolverr
   - URL: `http://flaresolverr:8191`
6. **Add Apps** (Sonarr and Radarr):
   - Settings → Apps → Add Application
   - **For Sonarr**:
     - Prowlarr Server: `http://prowlarr:9696`
     - Sonarr Server: `http://sonarr:8989`
     - API Key: (will get from Sonarr in next step)
   - **For Radarr**:
     - Prowlarr Server: `http://prowlarr:9696`
     - Radarr Server: `http://radarr:7878`
     - API Key: (will get from Radarr in next step)
   - **Save** (will sync indexers automatically)

### 7.2 Configure Sonarr (TV Shows)

1. **Access**: `https://sonarr.example.com`
2. **First Run Setup**:
   - Accept wizard prompts
   - Set authentication (recommended)
3. **Retrieve API Key**:
   - Settings → General → Security → API Key
   - Copy the generated key
   - **Update Prowlarr** app connection with this key
4. **Add Root Folder**:
   - Settings → Media Management → Root Folders
   - Add `/media/tv`
5. **Configure Download Clients**:
   - Settings → Download Clients → Add
   - **Sabnzbd** (Usenet - Priority 1):
     - Name: Sabnzbd
     - Host: `sabnzbd`
     - Port: `8080`
     - API Key: (from Sabnzbd - see step 7.4)
     - Category: `sonarr`
     - Priority: `1`
   - **qBittorrent** (Torrents - Priority 2):
     - Name: qBittorrent
     - Host: `qbittorrent`
     - Port: `8080`
     - Username/Password: (from qBittorrent - see step 7.5)
     - Category: `sonarr`
     - Priority: `2`
6. **Sync Prowlarr Indexers**:
   - Should happen automatically
   - Verify: Settings → Indexers (should show synced indexers)

### 7.3 Configure Radarr (Movies)

1. **Access**: `https://radarr.example.com`
2. **First Run Setup**:
   - Accept wizard prompts
   - Set authentication (recommended)
3. **Retrieve API Key**:
   - Settings → General → Security → API Key
   - Copy the generated key
   - **Update Prowlarr** app connection with this key
4. **Add Root Folder**:
   - Settings → Media Management → Root Folders
   - Add `/media/movies`
5. **Configure Download Clients**:
   - Settings → Download Clients → Add
   - **Sabnzbd** (Usenet - Priority 1):
     - Name: Sabnzbd
     - Host: `sabnzbd`
     - Port: `8080`
     - API Key: (from Sabnzbd)
     - Category: `radarr`
     - Priority: `1`
   - **qBittorrent** (Torrents - Priority 2):
     - Name: qBittorrent
     - Host: `qbittorrent`
     - Port: `8080`
     - Username/Password: (from qBittorrent)
     - Category: `radarr`
     - Priority: `2`
6. **Sync Prowlarr Indexers**:
   - Should happen automatically
   - Verify: Settings → Indexers

### 7.4 Configure Sabnzbd (Usenet Client)

1. **Access**: `https://sabnzbd.example.com`
2. **First Run Wizard**:
   - Language: English
   - Add Usenet server:
     - Host: (your provider)
     - Port: `563` (SSL) or `119` (non-SSL)
     - Username/Password: (your credentials)
     - Connections: `10` (or provider limit)
   - Folders:
     - Temporary: `/downloads/incomplete`
     - Completed: `/downloads/usenet`
3. **Retrieve API Keys**:
   - Config → General → Security
   - API Key: Copy for Sonarr/Radarr configuration
   - NZB Key: Copy if needed
4. **Configure Categories**:
   - Config → Categories
   - **sonarr**:
     - Folder: `/downloads/usenet/sonarr`
   - **radarr**:
     - Folder: `/downloads/usenet/radarr`
5. **Save Changes**

### 7.5 Configure qBittorrent (Torrent Client)

1. **Access**: `https://qbittorrent.example.com`
2. **Default Login**:
   - Username: `admin`
   - Password: Check logs: `docker logs qbittorrent | grep password`
3. **Change Password**:
   - Tools → Options → Web UI → Authentication
   - Set new password
4. **Configure Downloads**:
   - Tools → Options → Downloads
   - Default Save Path: `/downloads/torrents`
   - Keep incomplete torrents in: `/downloads/torrents/incomplete`
5. **Configure Categories** (if supported):
   - Add `sonarr` category → `/downloads/torrents/sonarr`
   - Add `radarr` category → `/downloads/torrents/radarr`
6. **Save Settings**

### 7.6 Update Environment Variables

Add retrieved API keys to `stacks/stack.env`:

```env
# Add API keys
SONARR_API_KEY=xxx
RADARR_API_KEY=xxx
PROWLARR_API_KEY=xxx
```

**Restart Unpackerr** to pick up API keys:
```bash
docker-compose -f stacks/starr.yaml restart unpackerr
```

### 7.7 Configure Recyclarr (Settings Sync)

1. **Create config file**:
```bash
nano /mnt/spool/apps/config/recyclarr/recyclarr.yml
```

2. **Add configuration**:
```yaml
sonarr:
  main:
    base_url: http://sonarr:8989
    api_key: YOUR_SONARR_API_KEY
    
    quality_definition:
      type: series
      
    custom_formats:
      - trash_ids:
          # TRaSH Guides recommended formats
          - EBC725268D687D588A20CBC5F97E538B  # Example: x265 (HD)
          - 9c11cd3f07101cdba90a2d81cf0e56b4  # Example: x265 (no HDR/DV)

radarr:
  main:
    base_url: http://radarr:7878
    api_key: YOUR_RADARR_API_KEY
    
    quality_definition:
      type: movie
      
    custom_formats:
      - trash_ids:
          # TRaSH Guides recommended formats
          - b6832f586342ef70d9c128d40c07b872  # Example: Bad Dual Groups
          - 90cedc1fea7ea5d11298bebd3d1d3223  # Example: EVO (no WEBDL)
```

3. **Run initial sync**:
```bash
docker exec recyclarr recyclarr sync
```

4. **Schedule periodic sync** (optional - via cron on host):
```bash
# Run every 6 hours
0 */6 * * * docker exec recyclarr recyclarr sync
```

## Step 8: Integration Testing

### Test 1: Indexer Search

1. **Prowlarr**: Search → Enter test query (e.g., "Ubuntu")
2. **Verify**: Results appear from configured indexers
3. **Expected**: Multiple results from different indexers

### Test 2: Add TV Show

1. **Sonarr**: Series → Add Series
2. **Search**: Enter show name (e.g., "The Office")
3. **Select**: Choose correct series
4. **Configure**:
   - Root Folder: `/media/tv`
   - Quality Profile: Any
   - Monitor: All Episodes (for testing)
5. **Add**: Click "Add"
6. **Wait**: Sonarr searches for episodes
7. **Verify**: Activity tab shows searches and downloads

### Test 3: Verify Download Priority

1. **Check**: Which download client was used (should be Sabnzbd if available)
2. **Expected**: Per clarifications, Usenet (Sabnzbd) should be tried first
3. **Fallback**: If Usenet fails, qBittorrent should be used

### Test 4: Monitor Download Progress

**Sabnzbd**:
```bash
# Watch download queue
# Access UI: https://sabnzbd.example.com
# Or check logs:
docker logs -f sabnzbd
```

**qBittorrent**:
```bash
# Watch torrent progress
# Access UI: https://qbittorrent.example.com  
# Or check logs:
docker logs -f qbittorrent
```

### Test 5: Verify Extraction

1. **Wait**: For download to complete
2. **Unpackerr**: Should detect completed download
3. **Check logs**:
```bash
docker logs -f unpackerr
# Should show: "Extracting: <filename>"
# Then: "Extraction complete"
```
4. **Verify**: Extracted files in `/mnt/dpool/media/downloads/`

### Test 6: Verify Organization

1. **Wait**: For Sonarr to detect completed download
2. **Check**: `/mnt/dpool/media/tv/` for organized episodes
3. **Expected**: 
   ```
   /media/tv/The Office (US)/Season 01/The Office (US) - S01E01 - Pilot.mkv
   ```
4. **Verify**: Sonarr Activity → Completed shows "Import Successful"

### Test 7: Test Failed Download Retry

1. **Stop download client** temporarily:
```bash
docker-compose -f stacks/starr.yaml stop sabnzbd
```
2. **Trigger search** in Sonarr/Radarr
3. **Expected**: Download should fail
4. **Start client**:
```bash
docker-compose -f stacks/starr.yaml start sabnzbd
```
5. **Verify**: Per clarifications, download should auto-retry up to 3 times
6. **Check**: Sonarr/Radarr Activity → Queue for retry count

### Test 8: Verify Disk Space Monitoring

**Note**: This test requires actual low disk space condition. To simulate:

1. **Create large test file** (if disk has space):
```bash
# Create 10GB file (adjust size based on available space)
fallocate -l 10G /mnt/dpool/media/test-file.bin
```
2. **Monitor**: Download queue behavior when disk space is low
3. **Expected**: Per clarifications, downloads should pause automatically
4. **Clean up**:
```bash
rm /mnt/dpool/media/test-file.bin
```
5. **Verify**: Downloads resume automatically

## Step 9: Verify Remote Access

### Test Cloudflare Tunnel

1. **From external network** (mobile data, different location):
2. **Access**: `https://sonarr.example.com`
3. **Expected**: Cloudflare Access authentication page
4. **Authenticate**: Using configured method (email/SSO)
5. **Verify**: Sonarr web UI loads
6. **Repeat**: For all services

### Test Service Isolation

1. **Attempt direct access**: `http://<host-ip>:8989`
2. **Expected**: Connection refused (ports not published)
3. **Verify**: Only qBittorrent peer ports accessible:
```bash
# From external machine
telnet <host-ip> 6881  # Should connect
telnet <host-ip> 8989  # Should fail (Sonarr)
```

## Step 10: Monitoring and Maintenance

### Health Checks

```bash
# Check all services
docker-compose -f stacks/starr.yaml ps

# Check specific service health
docker inspect --format='{{.State.Health.Status}}' sonarr

# View health check logs
docker inspect sonarr | jq '.[0].State.Health.Log'
```

### Log Monitoring

```bash
# All services
docker-compose -f stacks/starr.yaml logs -f

# Specific service
docker logs -f sonarr

# Last 100 lines
docker logs --tail 100 sonarr

# Since timestamp
docker logs --since 2h sonarr
```

### Resource Usage

```bash
# Container stats (CPU, memory, network)
docker stats

# Disk usage
docker system df

# Specific container disk usage
docker exec sonarr du -sh /config
```

### Updates

```bash
# Pull latest images (respecting semantic tags)
docker-compose -f stacks/starr.yaml pull

# Restart with new images
docker-compose -f stacks/starr.yaml up -d

# Remove old images
docker image prune -f
```

### Backups

**Configuration Backup**:
```bash
# Backup all service configs
tar -czf starr-config-$(date +%Y%m%d).tar.gz \
  /mnt/spool/apps/config/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,unpackerr,recyclarr}

# Backup environment file
cp stacks/stack.env stack.env.backup
```

**Restore**:
```bash
# Stop services
docker-compose -f stacks/starr.yaml down

# Restore configs
tar -xzf starr-config-YYYYMMDD.tar.gz -C /

# Start services
docker-compose -f stacks/starr.yaml up -d
```

## Troubleshooting

### Common Issues

**Services won't start**:
- Check directory permissions: `ls -la /mnt/spool/apps/config`
- Verify PUID/PGID match: `id`
- Check Docker logs: `docker logs <service>`

**Health checks failing**:
- Wait 5 minutes for services to fully initialize
- Check service logs for errors
- Verify network connectivity: `docker network inspect starr_net`

**Can't access via tunnel**:
- Verify tunnel token is correct
- Check cloudflared logs: `docker logs cloudflared`
- Confirm DNS records point to tunnel
- Verify Cloudflare Access policies configured

**Indexers not syncing**:
- Verify Prowlarr → Apps configured with correct API keys
- Check Prowlarr logs: `docker logs prowlarr`
- Manually trigger sync: Prowlarr → Settings → Apps → Test

**Downloads not starting**:
- Verify download clients configured in Sonarr/Radarr
- Test download client connections: Settings → Download Clients → Test
- Check API keys are correct
- Verify download paths are accessible

**Extraction not working**:
- Check Unpackerr logs: `docker logs unpackerr`
- Verify API keys updated in stack.env
- Confirm Unpackerr has access to download directories

## Success Criteria

✅ All services show "Up (healthy)" status  
✅ Prowlarr indexers configured and searching  
✅ Sonarr/Radarr can search via Prowlarr  
✅ Download clients configured and responding  
✅ Test TV show downloads successfully  
✅ Usenet prioritized over torrents (when both available)  
✅ Failed downloads retry up to 3 times  
✅ Unpackerr extracts archived downloads  
✅ Media organized to correct directories  
✅ Remote access via Cloudflare Tunnel works  
✅ Cloudflare Access authentication required  
✅ No web UIs accessible directly from host  
✅ qBittorrent peer ports accessible (6881)  
✅ Recyclarr syncs settings successfully

## Next Steps

After validation complete:

1. **Add Content**: Add your TV shows and movies to Sonarr/Radarr
2. **Configure Quality**: Set quality profiles per your preferences
3. **Setup Notifications**: Configure Discord/Slack/email notifications in services
4. **Schedule Backups**: Automate configuration backups
5. **Monitor Metrics**: Consider adding monitoring (Grafana, Prometheus)
6. **Optimize Settings**: Tune download client settings for your connection

---

**Deployment Time**: ~30-45 minutes (including configuration)  
**Last Updated**: 2025-09-29
