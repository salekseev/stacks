# Conventions and Style

## Stack File Conventions
- All stack files live in `stacks/` with `.yaml` extension (not `.yml`)
- File naming: `<service-name>.yaml` (kebab-case)
- Schema comment at top of files that use it:
  `# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json`
- Always use `restart: unless-stopped` (default) unless service-specific behavior required
- Use `expose` (not `ports`) for services accessed via Cloudflare tunnel
- Use `ports` only for services that need direct host access (plex, changedetection)

## Image Versioning
- Always pin exact versions (e.g., `ghcr.io/hotio/radarr:release-6.0.4.10291`)
- For `latest`/`plexpass` rolling tags: Renovate pins digests automatically
- hotio images use `release-` prefix for versioning

## Environment Variables
- Shared vars (PUID=1000, PGID=1000, TZ=America/New_York) via `env_file: stack.env`
- Service-specific vars defined inline under `environment:`
- Sensitive vars (passwords, tokens) referenced via `${VAR_NAME}` from host env

## Networking
- Most services use a shared `cloudflare` Docker network (name: cloudflare)
- External access via Cloudflare tunnels (cloudflared container in media.yaml)
- Cloudflare Zero Trust access policies applied per hostname
- Plex uses `network_mode: host`

## Volume Conventions
- Config paths: `/mnt/spool/apps/config/<service-name>:/config`
- Media storage: `/mnt/dpool/media:/media`
- Named volumes for stateful data that doesn't need host access (e.g., changedetection-data)

## User/Permissions
- Most services: PUID/PGID via env_file
- Some services hardcode `user: 1000:1000` or `user: nobody` or `user: 568:568`
