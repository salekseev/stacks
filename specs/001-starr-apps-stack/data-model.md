# Data Model for Starr Apps Media Stack

**Date**: 2025-09-09

This document defines the configuration "data model" for each service in the Starr Apps Media Stack. The model consists of the image, version, environment variables, volumes, and ports for each service.

## Entities (Services)

### Sonarr
- **Description**: TV series management.
- **Image**: `hotio/sonarr`
- **Version**: `4.0.15.2941`
- **Attributes**:
  - `PUID`, `PGID`, `TZ` (environment variables)
  - `/mnt/spool/apps/config/sonarr:/config` (volume for configuration)
  - `/mnt/dpool/media:/media` (volume for media)
  - `8989` (port)

### Radarr
- **Description**: Movie management.
- **Image**: `hotio/radarr`
- **Version**: `release-5.27.5.10198`
- **Attributes**:
  - `PUID`, `PGID`, `TZ` (environment variables)
  - `/mnt/spool/apps/config/radarr:/config` (volume for configuration)
  - `/mnt/dpool/media:/media` (volume for media)
  - `7878` (port)

### Prowlarr
- **Description**: Indexer management.
- **Image**: `hotio/prowlarr`
- **Version**: `2.0.5.5160`
- **Attributes**:
  - `PUID`, `PGID`, `TZ` (environment variables)
  - `/mnt/spool/apps/config/prowlarr:/config` (volume for configuration)
  - `9696` (port)

### Sabnzbd
- **Description**: Usenet download client.
- **Image**: `ghcr.io/hotio/sabnzbd`
- **Version**: `4.5.3`
- **Attributes**:
  - `PUID`, `PGID`, `TZ` (environment variables)
  - `/mnt/spool/apps/config/sabnzbd:/config` (volume for configuration)
  - `/mnt/dpool/media/usenet:/downloads` (volume for downloads)
  - `8080` (port)

### qBittorrent
- **Description**: Torrent download client.
- **Image**: `hotio/qbittorrent`
- **Version**: `4.6.7`
- **Attributes**:
  - `PUID`, `PGID`, `TZ`, `WEBUI_PORT` (environment variables)
  - `/mnt/spool/apps/config/qbittorrent:/config` (volume for configuration)
  - `/mnt/dpool/media/torrents:/downloads` (volume for downloads)
  - `8081`, `6881` (ports)

### Flaresolverr
- **Description**: Bypasses Cloudflare challenges for indexers.
- **Image**: `ghcr.io/flaresolverr/flaresolverr`
- **Version**: `v3.4.0`
- **Attributes**:
  - `LOG_LEVEL` (environment variable)
  - `/mnt/spool/apps/config/flaresolverr:/config` (volume for configuration)
  - `8191` (port)

### Unpackerr
- **Description**: Extracts downloaded files.
- **Image**: `ghcr.io/unpackerr/unpackerr`
- **Version**: `v0.14.5`
- **Attributes**:
  - `UN_SONARR_URL`, `UN_RADARR_URL` (environment variables)
  - `/mnt/spool/apps/config/unpackerr:/config` (volume for configuration)
  - `/mnt/dpool/media:/media` (volume for media)

### Cloudflared
- **Description**: Secure remote access tunnel.
- **Image**: `cloudflare/cloudflared`
- **Version**: `2025.8.1`
- **Attributes**:
  - `CLOUDFLARE_TUNNEL_TOKEN` (environment variable)
  - `/mnt/spool/apps/config/cloudflared:/config` (volume for configuration)

### Recyclarr
- **Description**: Automates synchronization of settings.
- **Image**: `ghcr.io/recyclarr/recyclarr`
- **Version**: `v7.4.1`
- **Attributes**:
  - `TZ` (environment variable)
  - `/mnt/spool/apps/config/recyclarr:/config` (volume for configuration)