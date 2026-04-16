# Project Overview

## Purpose
A collection of Docker Compose configurations for self-hosting various services. Each service or group of services ("stack") is defined in a YAML file under the `stacks/` directory.

## Tech Stack
- Docker Compose (YAML)
- Shell Scripts (bash)
- Renovate bot for automated dependency updates
- Cloudflare tunnels for external service access (Zero Trust)

## Hosted Services
- **media.yaml**: Full *arr stack (sabnzbd, qbittorrent+PIA VPN, qui, autobrr, prowlarr, byparr, radarr, sonarr, unpackerr, recyclarr, seerr, tautulli) + cloudflared
- **plex.yaml**: Plex Media Server with Nvidia GPU transcoding
- **changedetection.yaml**: changedetection.io + playwright-chrome browser
- **cli-proxy-api.yaml**: CLI proxy API service
- **go2rtc.yaml**: go2rtc streaming
- **iperf3.yaml**: iperf3 network testing
- **scrypted.yaml**: Scrypted home automation
- **ser2net.yaml**: Serial-to-network bridge

## Repository Structure
```
/
├── stacks/           # Docker Compose YAML files + stack.env
├── scripts/          # Automation scripts (validate-stack.sh)
├── AGENTS.md         # AI agent context file
└── renovate.json     # Renovate bot configuration
```
