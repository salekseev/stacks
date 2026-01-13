# Tasks: Media Automation Stack with Secure Remote Access and Automated Settings Synchronization

**Input**: Design documents from `/specs/001-create-a-comprehensive/`
**Prerequisites**: plan.md (required); spec.md available; research.md, data-model.md, contracts/ (not present)

## Execution Flow (main)
```
1. Load plan.md from feature directory
   → Extract: scope = Docker Compose stack for media automation & remote access
2. Load optional design documents (none present): derive tasks from spec.md user stories & requirements
3. Generate tasks by category:
   → Setup: branch hygiene, env centralization
   → Tests: stack validation via scripts/validate-stack.sh
   → Core: compose file with services, network, volumes, env usage
   → Integration: health checks, tunnel exposure, settings sync schedule
   → Polish: docs, version pinning confirmation
4. Apply task rules:
   → Different files = mark [P] for parallel
   → Same file = sequential (no [P])
   → Tests before implementation where applicable (validate before/after)
5. Number tasks sequentially (T001, T002...)
6. Create parallel execution examples
7. Return: SUCCESS (tasks ready for execution)
```

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel (different files, no dependencies)
- Include exact file paths in descriptions

## Path Conventions
- Compose stacks live under `stacks/*.yaml`
- Central environment at `stacks/stack.env`
- Media root at `/mnt/dpool/media`, config root at `/mnt/spool/apps/config`

## Phase 3.1: Setup
- [ ] T001 Ensure feature branch `001-create-a-comprehensive` is current; pull latest `master` (no file changes)  
      Ref: `/specs/001-create-a-comprehensive/plan.md#summary`
- [ ] T002 [P] Create compose file scaffold `stacks/starr.yaml` with top-level `services:` and dedicated network `starr_net`  
      Ref: Plan → Project Structure; Example patterns in `stacks/changedetection.yaml` (schema header) and `stacks/scrypted.yaml` (restart/network)
- [ ] T003 [P] Update `stacks/stack.env` with any missing common vars keys referenced by services (keep values minimal placeholders)  
      Ref: Existing `stacks/stack.env` and Spec → Non-Functional Requirements (NFR-003)

## Phase 3.2: Tests First (Validation gates)
- [ ] T004 Create pre-check in `specs/001-create-a-comprehensive/quickstart.md` documenting `scripts/validate-stack.sh starr` run  
      Ref: `scripts/validate-stack.sh`
- [ ] T005 Run `scripts/validate-stack.sh starr` and expect failure until services are added  
      Ref: Quickstart pre-check

## Phase 3.3: Core Implementation (Compose)
- [ ] T006 Add dedicated network `starr_net` in `stacks/starr.yaml` and attach all services  
      Ref: Plan Summary; Example: declares `network_mode: host` in `plex.yaml` (we use a user network instead)
- [ ] T007 Define volumes and shared paths in `stacks/starr.yaml` using `/mnt/spool/apps/config/*` and `/mnt/dpool/media`  
      Ref: `stacks/plex.yaml` volumes; Spec → paths
- [ ] T008 Add Sonarr service using `ghcr.io/hotio/sonarr:<SEMVER>` with env from `stacks/stack.env`  
      Ref: Spec → Starr apps; Plan → Technical Context (images); Example env patterns in `stacks/changedetection.yaml`
- [ ] T009 Add Radarr service using `ghcr.io/hotio/radarr:<SEMVER>` with env from `stacks/stack.env`  
      Ref: Spec/Plan; Example: restart policies `unless-stopped`
- [ ] T010 Add Prowlarr service using `ghcr.io/hotio/prowlarr:<SEMVER>` with env from `stacks/stack.env`  
      Ref: Spec/Plan; Label/health patterns from `stacks/changedetection.yaml`
- [ ] T011 Add Sabnzbd service using `ghcr.io/hotio/sabnzbd:<SEMVER>` with env and download/incomplete paths  
      Ref: Spec → Usenet client; Paths in Plan → Summary
- [ ] T012 Add qBittorrent service using `ghcr.io/hotio/qbittorrent:<SEMVER>` with env and torrent/data paths  
      Ref: Spec → Torrent client; Volumes pattern in Plan
- [ ] T013 Add Flaresolverr service using `ghcr.io/flaresolverr/flaresolverr:<SEMVER>` and dependency for Prowlarr  
      Ref: Spec → Supporting services; `depends_on` example in `stacks/changedetection.yaml`
- [ ] T014 Add Unpackerr service using `ghcr.io/hotio/unpackerr:<SEMVER>` with watch paths and api keys via env  
      Ref: Spec; Env centralization per NFR-003
- [ ] T015 Add `recyclarr` sync service using `ghcr.io/recyclarr/recyclarr:<SEMVER>` with config mount and schedule  
      Ref: Spec → automated settings synchronization; Plan → Research outputs
- [ ] T016 Define common labels and restart policies; ensure all containers `restart: unless-stopped`  
      Ref: `stacks/changedetection.yaml` and `stacks/scrypted.yaml`
- [ ] T017 Define healthchecks where images support it (simple curl/HTTP check)  
      Ref: `playwright-chrome` health flags and patterns in `stacks/changedetection.yaml`

## Phase 3.4: Integration
- [ ] T018 Wire service dependencies (`depends_on`) to reflect startup order (indexers → apps → recyclarr)  
      Ref: `stacks/changedetection.yaml` uses `depends_on`
- [ ] T019 Configure environment variable references: `PUID`, `PGID`, `TZ`, plus app-specific `*_API_KEY`, `*_BASE_URL`, etc., only as keys in `stacks/stack.env`  
      Ref: Current `stacks/stack.env`; Spec NFR-003
- [ ] T020 Configure volumes:
  - `/mnt/spool/apps/config/{sonarr,radarr,prowlarr,sabnzbd,qbittorrent,recyclarr,unpackerr}` → `/config`
  - `/mnt/dpool/media` → `/media`
  - Dedicated downloads dirs for usenet/torrents under `/mnt/dpool/media/downloads/{usenet,torrents}`  
      Ref: `stacks/plex.yaml` volume style; Spec paths
- [ ] T021 Add Cloudflare Tunnel sidecar or document external tunnel mapping for service UIs via labels/env; centralize entrypoint hostnames [PENDING DESIGN]  
      Ref: Plan Summary (tunnel) → research.md TODO
- [ ] T022 Expose necessary service ports on `starr_net` only; avoid host-level port publishing (remote access goes through tunnel)  
      Ref: Spec NFR-002; Example host exposure in `stacks/iperf3.yaml` (avoid publishing here)
- [ ] T023 Re-run `scripts/validate-stack.sh starr` and ensure success  
      Ref: Quickstart

## Phase 3.5: Polish
- [ ] T024 Pin all images to specific semantic versions; record chosen tags in `specs/001-create-a-comprehensive/research.md`  
      Ref: Spec → version pinning; Plan → Phase 0 output
- [ ] T025 Add brief `specs/001-create-a-comprehensive/quickstart.md` with docker-compose up/down and validation commands  
      Ref: `scripts/validate-stack.sh`
- [ ] T026 Add comments in `stacks/starr.yaml` for volumes and required env keys (concise)  
      Ref: `stacks/plex.yaml` comment style
- [ ] T027 Add minimal health/readiness notes in quickstart for each service  
      Ref: Health patterns in existing stacks

## Dependencies
- T002 before any compose service tasks (T006-T017)
- T003 before env-referencing tasks (T008-T015, T019)
- T004 before T005; T005 expected to fail until core is implemented
- T006-T017 before validation T023
- T021 depends on tunnel design decision; placeholder until defined

## Parallel Example
```
# After T006 network and T007 volumes are in place, run in parallel:
Task: "Add Sonarr service in stacks/starr.yaml" (T008)
Task: "Add Radarr service in stacks/starr.yaml" (T009)
Task: "Add Prowlarr service in stacks/starr.yaml" (T010)
# In parallel once downloads dirs defined:
Task: "Add Sabnzbd service in stacks/starr.yaml" (T011)
Task: "Add qBittorrent service in stacks/starr.yaml" (T012)
```

## Notes
- Prefer `ghcr.io` and `hotio.dev` images where available; pin to semver tags.
- Centralize all environment variables in `stacks/stack.env` with keys only; actual secrets to be populated out-of-band.
- Do not publish host ports; remote access handled by Cloudflare Tunnel.
- Keep paths consistent with `plex` stack: `/mnt/dpool/media`, `/mnt/spool/apps/config`.

## Validation Checklist
- [ ] Tasks reference exact file paths
- [ ] Parallel tasks modify different sections/files
- [ ] Validation script is run before and after core implementation
- [ ] Environment variables are centralized and referenced, not duplicated
- [ ] Images are version-pinned


