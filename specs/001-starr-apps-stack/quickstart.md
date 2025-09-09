# Quickstart Guide for Starr Apps Media Stack

**Date**: 2025-09-09

This guide provides the steps to deploy and test the Starr Apps Media Stack.

## Prerequisites
- Docker and Docker Compose installed.
- A Cloudflare account with a registered domain.
- Your `PUID` and `PGID` (find with the `id` command).

## 1. Directory Structure
Ensure the following directories exist on your host system:
```
/mnt/dpool/media/
  ├── usenet/
  └── torrents/
/mnt/spool/apps/config/
  ├── sonarr/
  ├── radarr/
  ├── prowlarr/
  ├── sabnzbd/
  ├── qbittorrent/
  ├── flaresolverr/
  ├── unpackerr/
  └── recyclarr/
```

## 2. Environment Variables
Ensure the following variables are set in your `stacks/stack.env` file:
```
PUID=1000
PGID=1000
TZ=America/New_York
CLOUDFLARE_TUNNEL_TOKEN=your_cloudflare_tunnel_token
```

## 3. Docker Compose File
Create a `starr-apps.yaml` file in the `stacks` directory with the content for all the services, as defined in the research and data model.

## 4. Deployment
Navigate to the `stacks` directory and run the following command:
```
docker-compose -f starr-apps.yaml up -d
```

## 5. Verification
- Run `docker-compose -f starr-apps.yaml ps` to ensure all containers are running.
- Access the web UI of each service via its port (e.g., Sonarr at `http://localhost:8989`).
- Configure the services to work together (e.g., connect Sonarr to Sabnzbd).
- Access the services via the Cloudflare tunnel URL.

## 6. Shutdown
To stop the stacks, run the following command:
```
docker-compose -f starr-apps.yaml down
```
