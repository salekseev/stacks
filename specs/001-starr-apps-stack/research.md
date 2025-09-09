# Research for Starr Apps Media Stack

**Date**: 2025-09-09

## Key Decisions

Based on the research of best practices for deploying Starr apps with Docker Compose, the following decisions have been made:

### 1. Directory Structure
- **Decision**: A standardized directory structure will be used to manage configuration and data, as recommended.
- **Rationale**: This promotes maintainability, simplifies backups, and prevents data loss.
- **Structure**:
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

### 2. User and Group IDs (`PUID` & `PGID`)
- **Decision**: All services will be run using `PUID` and `PGID` environment variables.
- **Rationale**: This avoids permission issues with files created by the containers on the host filesystem.

### 3. Networking
- **Decision**: A dedicated Docker network named `starr_media_network` will be created and all services will be attached to it.
- **Rationale**: This isolates the media stack from other containers and allows services to communicate with each other using their service names.

### 4. Volumes and Atomic Moves
- **Decision**: A single `/data` directory will be mapped into all relevant containers to enable atomic moves.
- **Rationale**: Atomic moves (hardlinks or instant moves) are highly efficient for media management, saving disk I/O and space.

### 5. Environment Variables
- **Decision**: A `.env` file (`.env.starr`) will be used to store common variables like `PUID`, `PGID`, timezone, and paths.
- **Rationale**: This keeps the `docker-compose.yaml` file clean, portable, and free of sensitive information.

### 6. Cloudflare Tunnel
- **Decision**: A `cloudflared` service will be included in the stack to provide secure remote access.
- **Rationale**: This eliminates the need to open ports on the router and provides a secure way to access the services from the internet.

### 7. Recyclarr
- **Decision**: `recyclarr` will be added to the stack to automate the synchronization of settings.
- **Rationale**: This ensures that Sonarr and Radarr are always up-to-date with the latest community-recommended settings.

### 8. Image Prioritization
- **Decision**: `hotio.dev` images will be prioritized over `linuxserver.io` images where available.
- **Rationale**: `hotio.dev` images are often more up-to-date and provide specific semantic version tags, allowing for better control over updates and preventing unexpected breaking changes.

### 9. Registry Prioritization
- **Decision**: `ghcr.io` images will be prioritized over Docker Hub images where available.
- **Rationale**: `ghcr.io` often has better rate limits and can provide more reliable pulls compared to Docker Hub.

## Alternatives Considered
- **Running containers as root**: Rejected due to potential permission issues.
- **Using default Docker network**: Rejected in favor of a custom network for better isolation and organization.
- **Separate data volumes for each container**: Rejected in favor of a shared data volume to enable atomic moves.
- **Configarr**: Rejected in favor of `recyclarr` as it is the active successor.
- **Using `latest` tags for all images**: Rejected in favor of pinning to specific semantic versions for better stability and predictability.