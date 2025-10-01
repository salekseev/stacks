# Feature Specification: Media Automation Stack

**Feature Branch**: `001-create-a-comprehensive`  
**Created**: September 29, 2025  
**Status**: Draft  
**Input**: User description: "Create a comprehensive media automation stack using Starr apps, download clients, a Cloudflare tunnel for secure remote access, and recyclarr for automated settings synchronization. The implementation will be a single Docker Compose file with a dedicated network, and all environment variables will be managed in the central stacks/stack.env file. Container images will be sourced primarily from official images or hotio.dev (where available) and ghcr.io (prioritized over Docker Hub) and pinned to specific semantic versions for stability. The stack will use shared media and configuration paths consistent with the existing plex stack (/mnt/dpool/media and /mnt/spool/apps/config). Starr applications: Sonarr, Radarr, and Prowlarr. Usenet download client: Sabnzbd. Torrent download client: qBittorrent. Supporting services: Flaresolverr and Unpackerr."

## Execution Flow (main)
```
1. Parse user description from Input
   → Feature description provided ✓
2. Extract key concepts from description
   → Identified: media automation, indexers, downloaders, access security, settings sync
3. For each unclear aspect:
   → Marked with [NEEDS CLARIFICATION: specific question]
4. Fill User Scenarios & Testing section
   → User flow defined ✓
5. Generate Functional Requirements
   → Each requirement is testable ✓
6. Identify Key Entities (if data involved)
   → Media entities and configuration entities identified ✓
7. Run Review Checklist
   → All checks pass ✓
8. Return: SUCCESS (spec ready for planning)
```

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT users need and WHY
- ❌ Avoid HOW to implement (no tech stack, APIs, code structure)
- 👥 Written for business stakeholders, not developers

### Section Requirements
- **Mandatory sections**: Must be completed for every feature
- **Optional sections**: Include only when relevant to the feature
- When a section doesn't apply, remove it entirely (don't leave as "N/A")

### For AI Generation
When creating this spec from a user prompt:
1. **Mark all ambiguities**: Use [NEEDS CLARIFICATION: specific question] for any assumption you'd need to make
2. **Don't guess**: If the prompt doesn't specify something (e.g., "login system" without auth method), mark it
3. **Think like a tester**: Every vague requirement should fail the "testable and unambiguous" checklist item
4. **Common underspecified areas**:
   - User types and permissions
   - Data retention/deletion policies  
   - Performance targets and scale
   - Error handling behaviors
   - Integration requirements
   - Security/compliance needs

---

## Clarifications

### Session 2025-09-29
- Q: When both Usenet and torrent sources are available for the same media, which should be preferred? → A: Usenet first - Always prefer Usenet, fall back to torrents only if Usenet unavailable
- Q: What authentication mechanism should be used for remote access through the Cloudflare tunnel? → A: Cloudflare Access - Use Cloudflare's Zero Trust authentication layer with email verification or SSO
- Q: How should the system handle failed downloads or corrupted files? → A: Auto-retry only - Automatically retry failed downloads up to 3 times, no notifications
- Q: How long should download history be retained? → A: 1 year
- Q: What happens when disk space runs low during active downloads? → A: Pause all downloads - Automatically pause all active downloads until space is freed
- Q: What is the deployment method and default timezone? → A: Portainer on remote host, timezone America/New_York (matching existing Plex stack), PUID=1000/PGID=1000 (matching existing Plex stack values)

### Technical Constraints (Session 2025-09-29)
- Deployment artifact: Single compose file `stacks/starr.yaml`
- Deployment method: Portainer on remote host (not direct docker-compose)
- Network isolation: Dedicated network `starr_net` for all services
- Container registry: Prefer `ghcr.io/hotio` images, fallback to `ghcr.io`, avoid Docker Hub
- Version management: Container image tags must be specified inline (not via environment variables) to enable automated dependency updates
- Port exposure: Only torrent peer ports (6881/tcp, 6881/udp) should be published to host; all web interfaces accessible via Cloudflare Tunnel only
- Configuration paths: Use `/mnt/spool/apps/config/<service>` for each service configuration
- Media paths: Use `/mnt/dpool/media` matching existing Plex stack conventions
- Environment variables: Centralize all variables in `stacks/stack.env` with defaults matching Plex stack (TZ=America/New_York, PUID=1000, PGID=1000, UMASK=0002)

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
As a media consumer and self-hoster, I need a fully automated system that discovers, downloads, organizes, and manages my media library. The system should automatically search for new TV episodes and movies based on my preferences, download them via both Usenet and torrent protocols, extract and organize files into the correct directory structure, and synchronize application settings automatically. I need secure remote access to manage all these services without exposing them directly to the internet.

### Acceptance Scenarios
1. **Given** I have added a TV show to my library, **When** a new episode is released, **Then** the system automatically searches for it, downloads it via the best available source (Usenet or torrent), unpacks it if compressed, and places it in the correct media directory organized by show name and season.

2. **Given** I have configured indexers in my indexer management service, **When** I need to search for media across multiple indexers, **Then** the system aggregates results from all configured sources and bypasses any Cloudflare-protected sites automatically.

3. **Given** I want to manage my media services from outside my home network, **When** I access the services via the secure tunnel, **Then** I can reach all service web interfaces without requiring VPN or port forwarding, and without exposing services directly to the internet.

4. **Given** I have configured settings and custom formats in my media management applications, **When** settings synchronization runs, **Then** my configurations remain consistent with community best practices and any manual customizations are preserved.

5. **Given** media files are downloaded as compressed archives, **When** downloads complete, **Then** the system automatically extracts the archives, validates the contents, and moves the media to the appropriate directory for library consumption.

### Edge Cases
- What happens when both Usenet and torrent sources are available for the same media? System prioritizes Usenet sources first and falls back to torrents only if Usenet is unavailable.
- How does the system handle failed downloads or corrupted files? System automatically retries failed downloads up to 3 times without sending notifications.
- What happens when disk space runs low during active downloads? System automatically pauses all active downloads until sufficient disk space is freed.
- How should the system behave when indexers are temporarily unavailable? System relies on built-in retry logic of indexer management service (configurable per service).
- What happens if the secure tunnel connection fails? Services become inaccessible remotely until tunnel reconnects; monitoring and alerting are operational concerns configured separately.

## Requirements *(mandatory)*

### Functional Requirements

#### Media Discovery & Management
- **FR-001**: System MUST provide automated TV show episode discovery and tracking capabilities
- **FR-002**: System MUST provide automated movie discovery and tracking capabilities  
- **FR-003**: System MUST manage and aggregate multiple indexers for media search
- **FR-004**: System MUST automatically search indexers when new media becomes available
- **FR-005**: System MUST support both Usenet and torrent protocol downloads
- **FR-006**: System MUST bypass Cloudflare protection when accessing indexers

#### Download Management
- **FR-007**: System MUST queue and manage Usenet downloads with configurable priority
- **FR-008**: System MUST queue and manage torrent downloads with configurable priority
- **FR-008a**: System MUST prioritize Usenet sources over torrent sources when both are available for the same media
- **FR-008b**: System MUST automatically retry failed downloads up to 3 times before marking as permanently failed
- **FR-008c**: System MUST monitor disk space and automatically pause all downloads when space runs low
- **FR-008d**: System MUST resume paused downloads automatically when sufficient disk space becomes available
- **FR-009**: System MUST automatically extract compressed archives after download completion
- **FR-010**: System MUST validate downloaded media files for completeness and quality
- **FR-011**: System MUST organize completed downloads into structured media directories

#### File Organization
- **FR-012**: System MUST organize TV shows by show name, season, and episode number
- **FR-013**: System MUST organize movies by title and year
- **FR-014**: System MUST rename media files according to configurable naming conventions
- **FR-015**: System MUST maintain consistent directory structure with existing media library at `/mnt/dpool/media`
- **FR-016**: System MUST store application configurations in `/mnt/spool/apps/config`

#### Configuration & Synchronization
- **FR-017**: System MUST automatically synchronize application settings based on community best practices
- **FR-018**: System MUST preserve custom user configurations during synchronization
- **FR-019**: System MUST synchronize custom formats and quality profiles
- **FR-020**: System MUST store all environment variables in centralized configuration file

#### Remote Access & Security
- **FR-021**: System MUST provide secure remote access to all service web interfaces via Cloudflare Tunnel
- **FR-022**: System MUST NOT expose service web interfaces to the host network
- **FR-022a**: System MUST expose torrent client peer communication ports (6881/tcp and 6881/udp) to the host for BitTorrent protocol functionality
- **FR-023**: System MUST maintain connectivity for remote access (monitoring and uptime requirements are operational concerns configured separately)
- **FR-024**: System MUST authenticate remote access requests using Cloudflare Access with Zero Trust authentication (email verification or SSO)
- **FR-024a**: System MUST integrate with Cloudflare's authentication layer before allowing access to service interfaces

#### Service Integration & Networking
- **FR-025**: System MUST enable communication between all services via dedicated network
- **FR-026**: System MUST allow media management services to control download clients
- **FR-027**: System MUST allow settings synchronization service to access media management APIs
- **FR-028**: System MUST use semantic versioning for all container images to ensure stability
- **FR-028a**: System MUST specify container image versions explicitly (not via environment variable indirection) to enable automated dependency update detection

#### Data Persistence
- **FR-029**: System MUST persist all service configurations across container restarts
- **FR-030**: System MUST persist download queue state across service restarts
- **FR-031**: System MUST persist media library metadata across service restarts
- **FR-032**: System MUST retain download history for 1 year before automatic cleanup

### Key Entities *(include if feature involves data)*

- **TV Show**: Represents a television series being tracked; includes metadata (title, year, network), monitored seasons and episodes, quality profile, and root folder path
- **Movie**: Represents a film being tracked; includes metadata (title, year, studio), monitored status, quality profile, and root folder path
- **Indexer**: Represents a search source for media; includes connection details, categories supported, priority level, and capabilities (Usenet/torrent)
- **Download**: Represents an active or completed download job; includes source file, destination path, download client used, status, priority, and completion percentage
- **Quality Profile**: Defines acceptable quality levels and preferences for media; includes resolution preferences, codec preferences, and size limits
- **Custom Format**: Defines specific media characteristics to prefer or avoid; includes scoring rules and matching patterns
- **Configuration**: Represents application settings; includes service-specific parameters, API keys, paths, and synchronization status

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain (all resolved or deferred to implementation)
- [x] Requirements are testable and unambiguous  
- [x] Success criteria are measurable
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

---

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed
- [x] Technical constraints documented
- [x] All clarifications resolved or deferred

---

## Notes

### Clarifications Deferred to Implementation
The following aspects have sensible defaults and can be configured during implementation:

1. **Indexer Availability**: Retry strategy for temporarily unavailable indexers → Can use service default behavior (Prowlarr/Starr app built-in retry logic)
2. **Tunnel Failure**: Fallback access and alerting for tunnel downtime → Operational monitoring concern; can be configured post-deployment using Cloudflare monitoring tools

### Dependencies
- Existing Plex stack configuration at `/mnt/dpool/media` and `/mnt/spool/apps/config`
- Cloudflare account with tunnel configuration and Cloudflare Access (Zero Trust) setup
- Central environment variable file at `stacks/stack.env`
- Network storage availability at specified mount points

### Assumptions
- User has existing Plex media library and wants to automate content acquisition
- User has access to both Usenet providers (with credentials) and torrent trackers
- User has Cloudflare account with tunnel and Cloudflare Access (Zero Trust) capability
- User wants community-recommended quality profiles and custom formats as baseline
- System will be deployed as single Docker Compose stack with services: Sonarr, Radarr, Prowlarr, Sabnzbd, qBittorrent, Flaresolverr, Unpackerr, and Recyclarr
- Deployment is managed via Portainer on a remote host (not direct docker-compose CLI)
- Host directories and PUID/PGID values are configured on the remote Portainer host
- Timezone is set to America/New_York
- Automated dependency update tools (e.g., Dependabot) are used for version management