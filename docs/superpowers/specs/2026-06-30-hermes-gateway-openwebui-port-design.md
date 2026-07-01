# Hermes Gateway + Open WebUI + Dashboard Port — Design Spec

- **Date:** 2026-06-30
- **Status:** Approved (brainstorm) — supersedes `2026-06-30-hermes-stealth-browser-stack-design.md` for the UI/agent-runtime topology
- **Stack file:** `stacks/hermes.yaml` (to be rewritten)
- **Author:** brainstormed with Claude Code (ultracode)
- **Supersedes:** the `hermes-webui` + `hermes-agent-src` two-container topology (§1/§4/§5.2 of the prior spec). Camofox, cloudflared, Cloudflare Access, and the noVNC login-handoff carry over unchanged.

---

## 1. Goal & what changes

Replace the fragile third-party UI + source-volume bridge with the **official first-party** Hermes topology:

- **Before:** a `hermes-agent` container existed only to `chmod` and populate the `hermes-agent-src` volume with agent *source*, which the third-party `nesquena/hermes-webui` `rsync`-staged and `pip install`ed to run the agent **in-process**. That source-populator container had no legitimate long-lived foreground and **crash-looped** (5 fixes deep, each surfacing a new coupling — an architectural smell, not a bug).
- **After:** a real `hermes-gateway` daemon (`nousresearch/hermes-agent`, `command: gateway run`) that (a) serves the **OpenAI-compatible API** on `:8642` and (b) runs the **first-party Hermes dashboard** on `:9119` in the *same* container (`HERMES_DASHBOARD=1`, supervised s6-rc service). **Open WebUI** is the daily chat client pointed at `:8642/v1`. The `hermes-agent-src` volume, the `chmod`/`rsync` bridge, and the whole crash-loop class are **deleted**.

**Why this is not "port the agent, keep the UI":** `nesquena/hermes-webui` runs the agent in-process and does **not** consume the gateway API for chat (gateway-decoupling, webui issue #2491, is unshipped). So porting necessarily replaces the UI. Open WebUI covers daily chat; the Hermes **dashboard** (Sessions, Cron, Config, API Keys, Profiles, Skills, embedded Chat/TUI) recovers the Hermes-aware surface that plain Open WebUI lacks. Together they cover everything `hermes-webui` did, first-party.

## 2. Non-goals / out of scope (Phase 2, unchanged)

- Hindsight semantic memory provider (Hermes built-in memory covers v1).
  - **As-built update (2026-07-01):** Phase-2 Hindsight memory now implemented — see `docs/superpowers/specs/2026-07-01-hermes-hindsight-phase2-design.md`.
- 1Password agent-driven login (human noVNC login + persistent camofox profile remains the credential model).
- Messaging adapters (Telegram/Discord/Slack/WhatsApp) — the gateway runs **API-server-only**; adapters stay opt-in/off.
- Residential egress proxy for camofox.
- No custom images; no host port publishing; all external access via cloudflared + Cloudflare Access.

## 3. Key decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Agent runtime | **`hermes gateway run` daemon** | First-party, s6-supervised; the API server + dashboard are its actual purpose. Eliminates the source-populator crash-loop. |
| Chat UI | **Open WebUI** (`ghcr.io/open-webui/open-webui`) | Officially documented Hermes integration; generic OpenAI-compatible client; well-maintained. |
| Admin/Hermes-aware UI | **Hermes dashboard** (`HERMES_DASHBOARD=1`, same container) | Recovers Sessions/Cron/Config/Profiles/Skills that Open WebUI lacks; first-party. |
| Claude credential | **OAuth token `ANTHROPIC_TOKEN`** (user choice) | Uses Claude Max + extra-usage credits. Daemon caveat: static setup-token expires → silent outage; evaluate the refreshable `~/.claude/.credentials.json` variant (§9). |
| Image pin | **`nousresearch/hermes-agent@sha256:c30340ee…`** (digest) | Only published image with **both** the camofox bearer fix (#20476) and the gateway sleep/PATH crash fix (#36208). Stopgap until a tag `> v2026.6.19` (§8). |
| UI auth posture | **Cloudflare Access is the gate (lean)** | Open WebUI via trusted-header SSO (no second login); dashboard gets a strong basic-auth password as the real second factor behind Access. One identity source. |
| Dashboard exposure | **`hermes-dashboard.alekseev.us` + harden** | User choice. Dashboard is a full machine-control surface (embedded shell, edits `.env`/`config.yaml`), so Access policy must be tight and the basic-auth password strong. |
| External access | **cloudflared + Cloudflare Access, one app for all 3 hosts** | `hermes`, `hermes-dashboard`, `hermes-browser` share one Access app / audTag (`f79eba42…`, team `alekseev`); cloudflared validates the Access JWT origin-side (`access:` block). |
| Camofox | **unchanged** (`ghcr.io/redf0x1/camofox-browser:2.4.6`) | Browsing path + noVNC handoff verified working; the UI swap doesn't touch it. |

## 4. Architecture

Four services on the private `hermes-net`. Nothing published to the host; only cloudflared reaches the origins, and only via Cloudflare Access.

```
                             Internet
                                │
                    Cloudflare Access  (one app, audTag f79eba42…, team alekseev)
                                │
        ┌───────────────────────┼───────────────────────────┐   cloudflared
        ▼                       ▼                             ▼
 hermes.alekseev.us    hermes-dashboard.alekseev.us   hermes-browser.alekseev.us
        │                       │                             │
        ▼                       ▼                             ▼
  ┌───────────┐         ┌────────────────────────┐     ┌──────────────┐
  │ open-webui│  /v1    │     hermes-gateway      │     │   camofox    │
  │  :8080    │────────▶│  :8642  OpenAI API      │     │ :9377 REST   │
  │ trusted-  │         │  :9119  dashboard       │────▶│ :6080 noVNC  │
  │ header SSO│         │  gateway run + s6       │ tools│ (unchanged) │
  └───────────┘         │  HERMES_DASHBOARD=1     │     └──────────────┘
                        │  /opt/data (HERMES_HOME)│         ▲
                        │  CAMOFOX_* + ANTHROPIC  │─────────┘ server-side browser tools
                        └────────────────────────┘
                          private docker network "hermes-net"
```

## 5. Component specifications

### 5.1 `camofox` — unchanged
`ghcr.io/redf0x1/camofox-browser:2.4.6`, REST `:9377` (bearer `CAMOFOX_API_KEY` = `CAMOFOX_SHARED_KEY`, `/health` open), on-demand noVNC `:6080` (`x11vnc -nopw`, gated by Access). Env, volume (`/mnt/spool/apps/data/hermes/camofox`), and healthcheck are carried over verbatim from the current stack. The noVNC login-handoff runbook (`POST /sessions/operator/toggle-display`) is unaffected.

### 5.2 `hermes-gateway` — agent daemon (API + dashboard)
- **Image:** `nousresearch/hermes-agent@sha256:c30340ee58dde86c284864b1016f474ec48c4a70ed49d24920cab083f670f417` (see §8).
- **Command:** `gateway run` (image entrypoint `/init` s6 supervises the gateway + dashboard services).
- **Volume:** `/mnt/spool/apps/data/hermes/gateway` → `/opt/data` (`HERMES_HOME`/`HERMES_WRITE_SAFE_ROOT`; holds `config.yaml`, `.env`, `lazy-packages`, session SQLite; persists across image upgrades). **Fresh** host dir — do not reuse the old `hermes-webui` config home.
- **Ports:** none published; `:8642` and `:9119` reached over `hermes-net` (Open WebUI → `:8642`, cloudflared → `:9119`).
- **Env:**
  | Var | Value | Notes |
  |---|---|---|
  | `HERMES_UID` / `HERMES_GID` | `1000` / `1000` | Own `/opt/data` as the host dir owner (s6 init chowns HERMES_HOME). Validate at deploy. |
  | `API_SERVER_ENABLED` | `true` | Turn on the OpenAI-compatible server (default false → would 404). |
  | `API_SERVER_HOST` | `0.0.0.0` | Reachable by Open WebUI over the network. |
  | `API_SERVER_KEY` | `${HERMES_API_SERVER_KEY}` | Bearer for `:8642` (≥8 chars). **Must equal** Open WebUI's `OPENAI_API_KEY`. |
  | `HERMES_DASHBOARD` | `1` | Enable the dashboard s6 service. |
  | `HERMES_DASHBOARD_HOST` | `0.0.0.0` | Docker default; reached by cloudflared. |
  | `HERMES_DASHBOARD_PORT` | `9119` | Default. |
  | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `admin` | Activates the basic-auth provider (satisfies the fail-closed non-loopback gate). |
  | `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | `${HERMES_DASHBOARD_PASSWORD}` | Strong, unique — the real second factor behind Access. (`_PASSWORD_HASH` scrypt is preferred if we want no plaintext at rest.) |
  | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `${HERMES_DASHBOARD_SECRET}` | Token-signing key, 32+ random bytes (`openssl rand -base64 32`). |
  | `CAMOFOX_URL` | `http://camofox:9377` | Route all browser tools server-side through camofox. |
  | `CAMOFOX_API_KEY` | `${CAMOFOX_SHARED_KEY}` | Bearer camofox expects (same secret). |
  | `CAMOFOX_USER_ID` | `operator` | Externally-managed mode (no destructive cleanup). |
  | `CAMOFOX_SESSION_KEY` | `visible-tab` | Tab match key for adoption. |
  | `CAMOFOX_ADOPT_EXISTING_TAB` | `true` | Reuse the human-authenticated tab. |
  | `ANTHROPIC_TOKEN` | `${ANTHROPIC_TOKEN}` | Claude OAuth setup-token (see §9). |
  - **NEVER** set `HERMES_DASHBOARD_INSECURE` (bypasses the auth gate).
  - **Seeded `config.yaml`** on `/opt/data` (or via dashboard Config tab): `model.provider: anthropic` + a default model id (e.g. `claude-opus-4-8`; confirm the exact id Hermes' anthropic adapter accepts at deploy).
- **Healthcheck:** `python3 -c` GET on `http://localhost:9119/api/status` (python3 is in-image; avoids assuming curl). Confirm path/behavior at deploy.

### 5.3 `open-webui` — daily chat client
- **Image:** `ghcr.io/open-webui/open-webui:v0.10.1` (pin a version; `:main` is rolling and can lag releases — confirm the current stable at deploy).
- **Ports:** none published (`expose: 8080` only). **This is load-bearing:** trusted-header SSO is safe *only* because no client can reach the container directly to forge the header.
- **Volume:** `/mnt/spool/apps/data/hermes/open-webui` → `/app/backend/data`.
- **Env:**
  ```
  ENABLE_OPENAI_API=true
  OPENAI_API_BASE_URL=http://hermes-gateway:8642/v1
  OPENAI_API_KEY=${HERMES_API_SERVER_KEY}       # == gateway API_SERVER_KEY
  ENABLE_OLLAMA_API=false
  WEBUI_AUTH=true                                # MUST stay true for trusted-header SSO
  ENABLE_SIGNUP=false
  ENABLE_LOGIN_FORM=false
  WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Cf-Access-Authenticated-User-Email
  WEBUI_AUTH_TRUSTED_NAME_HEADER=Cf-Access-Authenticated-User-Email
  WEBUI_URL=https://hermes.alekseev.us
  ENABLE_WEBSOCKET_SUPPORT=true                  # required for streaming (v0.5+)
  CORS_ALLOW_ORIGIN=https://hermes.alekseev.us
  ```
- **depends_on:** `hermes-gateway` (prefer `service_healthy`).

### 5.4 `cloudflared` — tunnel + origin-side Access validation
- Image/user/creds unchanged (`cloudflare/cloudflared:2026.6.1`, user `568:568`, creds bind, inline `configs:`).
- **Ingress (all three hosts share one Access app / audTag `f79eba42…`, team `alekseev`):**
  ```
  ingress:
    - hostname: hermes.alekseev.us
      service: http://open-webui:8080
      access: { required: true, teamName: alekseev, audTag: [f79eba42…] }
    - hostname: hermes-dashboard.alekseev.us
      service: http://hermes-gateway:9119
      access: { required: true, teamName: alekseev, audTag: [f79eba42…] }
    - hostname: hermes-browser.alekseev.us
      service: http://camofox:6080
      access: { required: true, teamName: alekseev, audTag: [f79eba42…] }
    - service: http_status:404
  ```
- **depends_on:** `open-webui`, `hermes-gateway`, `camofox`.

## 6. Secrets & auth model

Portainer stack `${VAR}` interpolation (no host `.env`; every secret is a discrete env var).

| Secret | Used by | Status |
|---|---|---|
| `CAMOFOX_SHARED_KEY` | camofox `CAMOFOX_API_KEY` + gateway `CAMOFOX_API_KEY` | keep |
| `HERMES_API_SERVER_KEY` | gateway `API_SERVER_KEY` == open-webui `OPENAI_API_KEY` | **new** |
| `HERMES_DASHBOARD_PASSWORD` | gateway dashboard basic-auth | **new** |
| `HERMES_DASHBOARD_SECRET` | gateway dashboard token-signing | **new** |
| `ANTHROPIC_TOKEN` | gateway Claude credential | keep |
| `HERMES_TUNNEL_ID` + tunnel creds file | cloudflared | keep |
| `HERMES_WEBUI_PASSWORD`, `VNC_PASSWORD` | — | **dropped** |

**Auth model:** Cloudflare Access authenticates every request at the edge; cloudflared re-validates the Access JWT origin-side before proxying. Open WebUI trusts `Cf-Access-Authenticated-User-Email` (auto-provisions the first email as admin — validate). The dashboard basic-auth password is the second factor on the privileged surface. Tighten the Access policy (specific identity, short session TTL) since the dashboard grants full machine control.

## 7. Data flow (all three preserved)

1. **Chat:** `hermes.alekseev.us` → Access → open-webui → `POST hermes-gateway:8642/v1/chat/completions` → the gateway-side agent runs tools and reasons **server-side** → SSE stream back to Open WebUI.
2. **Browser tool:** the agent drives `camofox:9377` with the bearer (same `CAMOFOX_*`) — stealth browsing runs server-side on the gateway; Open WebUI just renders the conversation.
3. **noVNC login-handoff:** `hermes-browser.alekseev.us` → camofox `:6080`; operator toggles the display and logs in; camofox persists the `operator` profile; the agent adopts it. **Unchanged.**

## 8. Image pinning strategy

- No release tag carries both required fixes: `v2026.6.19` (latest tag) has the gateway sleep/PATH fix (#36208/PR#37120) but **not** the camofox bearer fix (#20476/PR#54729, merged to `main` 2026-06-29, after the tag).
- Pin the multi-arch **index digest** `sha256:c30340ee58dde86c284864b1016f474ec48c4a70ed49d24920cab083f670f417` (`:latest`/`:main` as of 2026-06-30T20:55Z; amd64 `98f7bb45…`, arm64 `c6494c76…`). It tracks unreleased `main` (~1303 commits past the tag) — treat as a **stopgap**.
- **Action:** watch `gh release list`; migrate to the first tag `> v2026.6.19` containing commit `babd916`. Re-verify with `gh api …/compare/babd916...<tag>` and `docker buildx imagetools inspect` before bumping. Bumping is no longer coupled to deleting any volume (the `hermes-agent-src` volume is gone).

## 9. Claude credential (OAuth token) — daemon caveat & runbook

The user chose the OAuth setup-token (`ANTHROPIC_TOKEN=sk-ant-oat-…`). For a long-lived daemon this expires and causes a **silent chat outage** until re-provisioned. Two mitigations to evaluate at implementation:

1. **Refreshable credentials file (preferred if supported):** drop a Claude Code `~/.claude/.credentials.json` (with `refreshToken`) onto the gateway's `/opt/data` HOME so the anthropic adapter auto-refreshes. Confirm the pinned image honors this.
2. **Re-provision runbook:** `claude setup-token` on the workstation → update the Portainer `ANTHROPIC_TOKEN` env → redeploy. Document expiry monitoring.

(Billing caveat unchanged: third-party-tool OAuth is extra-usage since 2026-04-04; Agent-SDK usage draws a separate credit pool since 2026-06-15.)

## 10. Migration (repo-side vs host-side)

- **Repo-side (assistant, on `master`):** rewrite `stacks/hermes.yaml` to the topology above; `./scripts/validate-stack.sh hermes`; commit. Update/annotate the prior spec as superseded.
- **Host-side on `silverstone` (operator, manual — assistant cannot reach host/Cloudflare):**
  1. Portainer env: add `HERMES_API_SERVER_KEY`, `HERMES_DASHBOARD_PASSWORD`, `HERMES_DASHBOARD_SECRET`; remove `HERMES_WEBUI_PASSWORD`.
  2. Create `/mnt/spool/apps/data/hermes/gateway` and `/mnt/spool/apps/data/hermes/open-webui` (owned uid 1000).
  3. Cloudflare: add `hermes-dashboard.alekseev.us` DNS/tunnel route and attach it to the existing Access app (same audTag).
  4. Redeploy (old `hermes-agent`/`hermes-webui` containers + `hermes-agent-src` volume removed; new volumes created).
  5. Seed `/opt/data/config.yaml` (`model.provider: anthropic` + model id); provision `ANTHROPIC_TOKEN`.
  6. Smoke tests (§11).

## 11. Testing & validation

1. **Static:** `./scripts/validate-stack.sh hermes` (compose parse).
2. **Gateway boot:** no crash-loop; `curl -s http://<host>:9119/api/status | jq '.auth_required,.auth_providers'` → `true` + `basic`.
3. **Open WebUI:** loads at `hermes.alekseev.us` through Access; auto-logs in via trusted header (confirm admin role); the Hermes model appears under `/v1/models`.
4. **Chat:** a prompt returns a Claude response (credential reachable, model id valid).
5. **Browser tool:** a browse task routes through camofox `:9377` (bearer, no 403) and returns rendered content.
6. **noVNC handoff:** `hermes-browser.alekseev.us` toggle-display → login → agent adopts the `operator` session.
7. **Dashboard:** `hermes-dashboard.alekseev.us` prompts basic-auth; Sessions/Cron/Config visible.

## 12. Risks / validate-at-deploy

- **Digest pin is a mutable-`main` stopgap** — less release hardening; migrate to the next tag (§8).
- **OAuth token expiry → silent outage** (§9); evaluate refreshable creds; monitor.
- **Hermes duplicate-`tool_use`-id transcript bug** (Anthropic adapter, wedges after ~50-message compaction) may bite long Open WebUI chats on this image; validate, mitigate with shorter sessions until fixed upstream.
- **Open WebUI trusted-header = full auth bypass if any host port is published** — design keeps zero published ports; verify. Also: first-user-admin/role provisioning quirks (#6548/#21016) and a past CSP-behind-Cloudflare-Tunnel bug — validate the pinned version loads end-to-end through the tunnel.
- **`HERMES_DASHBOARD_INSECURE` semantics contradict across docs** — never set it; verify the gate via `/api/status`.
- **`/opt/data` uid/permissions** on first mount — confirm the image's uid remap (`HERMES_UID`/`HERMES_GID`).
- **Health endpoint paths** (`:9119/api/status`, `:8642` liveness) — confirm against the pinned image.
- **`config.yaml` provider seeding vs env-only** — confirm whether `ANTHROPIC_TOKEN` env alone suffices or `hermes auth add anthropic` / a seeded provider block is needed.

## 13. Appendix — reference compose (design target; finalized in the implementation plan)

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
# Hermes gateway + Open WebUI + dashboard. Secrets via Portainer stack env ${VAR}.
# Required env: CAMOFOX_SHARED_KEY, HERMES_API_SERVER_KEY, HERMES_DASHBOARD_PASSWORD,
#               HERMES_DASHBOARD_SECRET, ANTHROPIC_TOKEN, HERMES_TUNNEL_ID.
services:

  camofox:
    # UNCHANGED — see current stack for full env/healthcheck (redf0x1 fork, :9377 REST, :6080 on-demand noVNC).
    restart: unless-stopped
    image: ghcr.io/redf0x1/camofox-browser:2.4.6
    container_name: camofox
    hostname: camofox
    environment:
      - CAMOFOX_HOST=0.0.0.0
      - CAMOFOX_PORT=9377
      - CAMOFOX_API_KEY=${CAMOFOX_SHARED_KEY}
      - CAMOFOX_AUTH_MODE=required
      - CAMOFOX_PROFILES_DIR=/home/node/.camofox/profiles
      - CAMOFOX_VNC_HOST=0.0.0.0
      - CAMOFOX_VNC_BASE_PORT=6080
      - CAMOFOX_VNC_RESOLUTION=1920x1080x24
      - CAMOFOX_HEADLESS=virtual
      - CAMOFOX_VNC_TIMEOUT_MS=900000
    volumes:
      - /mnt/spool/apps/data/hermes/camofox:/home/node/.camofox
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:9377/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks: [hermes-net]

  hermes-gateway:
    restart: unless-stopped
    image: nousresearch/hermes-agent@sha256:c30340ee58dde86c284864b1016f474ec48c4a70ed49d24920cab083f670f417
    container_name: hermes-gateway
    hostname: hermes-gateway
    command: gateway run
    depends_on:
      camofox:
        condition: service_healthy
    environment:
      - HERMES_UID=1000
      - HERMES_GID=1000
      # OpenAI-compatible API server (for Open WebUI)
      - API_SERVER_ENABLED=true
      - API_SERVER_HOST=0.0.0.0
      - API_SERVER_KEY=${HERMES_API_SERVER_KEY}
      # First-party dashboard (fail-closed on non-loopback -> basic-auth required)
      - HERMES_DASHBOARD=1
      - HERMES_DASHBOARD_HOST=0.0.0.0
      - HERMES_DASHBOARD_PORT=9119
      - HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
      - HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${HERMES_DASHBOARD_PASSWORD}
      - HERMES_DASHBOARD_BASIC_AUTH_SECRET=${HERMES_DASHBOARD_SECRET}
      # Camofox browser tools (server-side)
      - CAMOFOX_URL=http://camofox:9377
      - CAMOFOX_API_KEY=${CAMOFOX_SHARED_KEY}
      - CAMOFOX_USER_ID=operator
      - CAMOFOX_SESSION_KEY=visible-tab
      - CAMOFOX_ADOPT_EXISTING_TAB=true
      # Claude via OAuth setup-token
      - ANTHROPIC_TOKEN=${ANTHROPIC_TOKEN}
    volumes:
      - /mnt/spool/apps/data/hermes/gateway:/opt/data
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:9119/api/status',timeout=5).status==200 else 1)"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    networks: [hermes-net]

  open-webui:
    restart: unless-stopped
    image: ghcr.io/open-webui/open-webui:v0.10.1
    container_name: open-webui
    hostname: open-webui
    depends_on:
      hermes-gateway:
        condition: service_healthy
    environment:
      - ENABLE_OPENAI_API=true
      - OPENAI_API_BASE_URL=http://hermes-gateway:8642/v1
      - OPENAI_API_KEY=${HERMES_API_SERVER_KEY}
      - ENABLE_OLLAMA_API=false
      - WEBUI_AUTH=true
      - ENABLE_SIGNUP=false
      - ENABLE_LOGIN_FORM=false
      - WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Cf-Access-Authenticated-User-Email
      - WEBUI_AUTH_TRUSTED_NAME_HEADER=Cf-Access-Authenticated-User-Email
      - WEBUI_URL=https://hermes.alekseev.us
      - ENABLE_WEBSOCKET_SUPPORT=true
      - CORS_ALLOW_ORIGIN=https://hermes.alekseev.us
    volumes:
      - /mnt/spool/apps/data/hermes/open-webui:/app/backend/data
    networks: [hermes-net]

  cloudflared:
    restart: unless-stopped
    image: cloudflare/cloudflared:2026.6.1
    container_name: hermes-cloudflared
    hostname: hermes-cloudflared
    command: --config /etc/cloudflared/config.yml tunnel run
    user: "568:568"
    configs:
      - source: cloudflared
        target: /etc/cloudflared/config.yml
        uid: "568"
        gid: "568"
        mode: 0440
    volumes:
      - /mnt/spool/apps/config/hermes/cloudflared:/etc/cloudflared/creds
    depends_on:
      - open-webui
      - hermes-gateway
      - camofox
    networks: [hermes-net]

configs:
  cloudflared:
    content: |
      tunnel: ${HERMES_TUNNEL_ID}
      credentials-file: /etc/cloudflared/creds/tunnel.json
      ingress:
        # Origin-side Cloudflare Access JWT validation. All three hosts share ONE
        # Access app / audTag (team alekseev). cloudflared verifies Cf-Access-Jwt-Assertion
        # against the team JWKS + audTag before proxying.
        - hostname: hermes.alekseev.us
          service: http://open-webui:8080
          access:
            required: true
            teamName: alekseev
            audTag:
              - f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d
        - hostname: hermes-dashboard.alekseev.us
          service: http://hermes-gateway:9119
          access:
            required: true
            teamName: alekseev
            audTag:
              - f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d
        - hostname: hermes-browser.alekseev.us
          service: http://camofox:6080
          access:
            required: true
            teamName: alekseev
            audTag:
              - f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d
        - service: http_status:404

networks:
  hermes-net:
```
