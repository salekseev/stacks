# Research: Image Versions, Health, and Remote Access

## Image Version Pinning (semantic)
- ghcr.io/hotio/sonarr: 4.0.7 (Sonarr v4 stable)
- ghcr.io/hotio/radarr: 5.8.3 (Radarr v5 stable)
- ghcr.io/hotio/prowlarr: 1.28.2 (Prowlarr v1 stable)
- ghcr.io/hotio/sabnzbd: 4.3.3 (SABnzbd v4 stable)
- ghcr.io/hotio/qbittorrent: 4.6.7 (qBittorrent v4.6 line)
- ghcr.io/flaresolverr/flaresolverr: v3.3.21
- ghcr.io/hotio/unpackerr: 0.14.10
- ghcr.io/recyclarr/recyclarr: 7.3.1

Rationale: Prefer GHCR/hotio for consistency and timely updates; choose latest stable semver as of 2025-09-13.

## Health & Restart Strategy
- Use `restart: unless-stopped` for all long-running services.
- Where supported, add HTTP healthchecks (future enhancement).

## Remote Access via Cloudflare Tunnel
- Constraint: No host port publishing; all remote UI access flows through Cloudflare Tunnel.
- Implementation note: Either sidecar per service or central tunnel mapping to internal service ports on `starr_net`.
- Decision deferred to infrastructure layer; compose remains tunnel-agnostic.

