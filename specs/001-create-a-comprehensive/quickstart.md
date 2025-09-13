# Quickstart: Media Automation Stack (Starr)

## Prerequisites
- Docker and docker-compose installed
- Host directories exist:
  - `/mnt/spool/apps/config/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,unpackerr,recyclarr}`
  - `/mnt/dpool/media`
  - `/mnt/dpool/media/downloads/{usenet,torrents}`
- Environment: `stacks/stack.env` with `PUID`, `PGID`, `TZ` and Unpackerr API keys

## Validate Compose
```bash
bash scripts/validate-stack.sh starr
```
- Expect success once all services are defined

## Bring Up
```bash
docker compose -f stacks/starr.yaml --env-file stacks/stack.env up -d
```

## Verify
- Sonarr, Radarr, Prowlarr UIs (via local network or Cloudflare Tunnel)
- SABnzbd and qBittorrent queues
- Unpackerr logs show connected apps
- Recyclarr runs on start; check logs under `/mnt/spool/apps/config/recyclarr`

## Tear Down
```bash
docker compose -f stacks/starr.yaml --env-file stacks/stack.env down
```
