# Hermes Stealth-Browser Agent Stack — Design Spec

- **Date:** 2026-06-30
- **Branch:** `hermes-stealth-browser-stack`
- **Status:** Draft for review
- **Stack file (to be created):** `stacks/hermes.yaml`
- **Author:** brainstormed with Claude Code (ultracode)

---

## 1. Goal

Deploy a new self-hosted stack that runs the **Hermes agent** (NousResearch/hermes-agent)
for agentic web browsing, backed by a **stealth browser** sidecar for anti-bot evasion, with
a way for the operator to **remotely connect to a live browser session to authenticate to
websites** (log in, solve MFA/challenges) and hand that authenticated session to the agent.

Hermes is driven from a **web UI** (browser dashboard), uses **Claude via OAuth** as its
reasoning model initially (model-agnostic, swappable later), and the stealth browser is
**Camoufox** (anti-detect Firefox).

## 2. Non-goals

- Not building any custom container image — every service uses a pinned upstream image.
- Not using cloud browser services (Browserbase / Browser Use cloud). Fully self-hosted.
- Not exposing any browser/REST/debug port directly on the host or public internet.
- Not multi-tenant or horizontally scaled — single operator, single shared browser profile to
  start (the chosen components support more later without redesign).
- Not solving Anthropic billing — OAuth billing behavior is Anthropic's; documented as a caveat.
- Not passing a GPU into the browser container — rejected on stealth grounds (see §10).
- Agent-driven credential access (1Password) is **optional / Phase 2**, not part of the initial build (see §11).

## 3. Key decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Agent | **NousResearch/hermes-agent** | Confirmed by the user (link to `hermes-agent.nousresearch.com`). MIT, model-agnostic, ships a **native Camofox browser backend** that names `jo-inc/camofox-browser` explicitly. |
| Reasoning model | **Claude via OAuth** (initial) | User's choice. Hermes is model-agnostic, so this is swappable via config later. |
| Web UI | **`nesquena/hermes-webui`, single container** | User chose "Web UI + agent". It runs the agent **in-process**, so a separate agent container adds complexity with **no** isolation benefit (its "2-container" mode does **not** route chat to the separate agent — that container is only a status-pill health probe). Polished, mobile-friendly, multi-arch image, very active. |
| Stealth browser | **`jo-inc/camofox-browser`** (Camoufox) | User chose Camoufox. jo-inc is purpose-built "stealth browser for AI agents", is Hermes' **native** backend, and **bundles** the exact remote-login assembly (Camoufox + Xvfb + x11vnc + noVNC + persistent profiles) that we would otherwise hand-build. |
| Stealth packaging | **Official image `ghcr.io/jo-inc/camofox-browser:1.11.2`** (pin by digest) | Verified: the published multi-arch (amd64/arm64) image is built from `Dockerfile.ci` which copies `camofox.config.json` + `plugins/` and runs `install-plugin-deps.sh`; that script installs apt deps for **every** listed plugin via `Object.keys(plugins)` and never checks the `enabled` flag — so **x11vnc + noVNC + websockify are baked in**. VNC is a runtime toggle (`ENABLE_VNC=1`). No custom build needed; matches the repo's pinned-image convention. |
| Remote login → handoff | **Native to jo-inc**: shared X display (noVNC) + persistent per-`userId` profile + Hermes tab adoption | jo-inc's VNC plugin attaches `x11vnc -shared` to the **same** Xvfb display the agent's browser renders on, and Hermes supports `CAMOFOX_USER_ID` + `CAMOFOX_ADOPT_EXISTING_TAB` to reuse (not destroy) the human-authenticated tab/profile. |
| External access | **`cloudflared` tunnel + Cloudflare Access** | Matches the existing `hindsight` stack pattern. No host port publishing for sensitive services. |
| GPU for stealth | **No GPU passthrough** | Camoufox spoofs WebGL from common-consumer-GPU presets and renders via software (llvmpipe); a real A400 causes a string-vs-pixel mismatch and is a rare/suspicious fingerprint. See §10. |
| Agent credentials | **Human noVNC login + persistent sessions (default); 1Password optional (Phase 2)** | Default exposes no secrets to the agent. For unattended agent-driven login, the official Hermes 1Password skill + `op` CLI + a scoped read-only Service Account. See §11. |

### Rejected alternatives

- **HeadlessX (`saifyxpro/HeadlessX`)** — Camoufox-backed *scraping platform* (REST/MCP only).
  No attachable browser endpoint (no CDP / Playwright-WS) and **no live remote viewer**. Fails
  both make-or-break requirements; also drags in Postgres + Redis + Go + Python + Next.js.
- **DIY Camoufox + Xvfb + x11vnc + noVNC** — works, but re-implements exactly what jo-inc ships
  and would require a custom in-repo image (against the repo's pinned-upstream-image convention).
- **CloakBrowser (stealth Chromium / CDP)** — already trusted in the `changedetection` stack, but
  the user chose Camoufox; its latest stealth build is paid Pro and it publishes only a mutable
  `latest` tag. Documented here as the fallback engine if Camoufox underperforms on a target.

## 4. Architecture

Three services in `stacks/hermes.yaml`, on a private bridge network. Only the Hermes UI and the
noVNC viewer are reachable from outside — through cloudflared, gated by Cloudflare Access.

```
                       Internet
                          │
                 Cloudflare Access (auth)
                          │
                ┌─────────┴──────────┐  cloudflared (tunnel sidecar)
                ▼                    ▼
        hermes.alekseev.us   hermes-browser.alekseev.us
                │                    │
        ┌───────▼────────┐    ┌──────▼───────────────────────────────┐
        │ hermes-webui   │    │ camofox  (jo-inc/camofox-browser)     │
        │  :8787         │    │  noVNC :6080  ← human logs in / MFA   │
        │  = web UI +    │    │  REST  :9377  ← agent drives (bearer) │
        │    Hermes      │    │  Camoufox headful in Xvfb (shared X)  │
        │    agent       │    │  persistent profiles  /home/node/.camofox
        │  (in-process)  │    └──────────────────────────────────────┘
        │  Claude OAuth  │              ▲
        │  ~/.hermes vol │              │ REST + Bearer (CAMOFOX_API_KEY → CAMOFOX_ACCESS_KEY)
        └───────┬────────┘              │ userId + adopt-existing-tab
                └───────────────────────┘
                   private docker network "hermes-net"
```

**Control/data flow**

1. Operator opens `hermes.alekseev.us` → Cloudflare Access → `hermes-webui:8787`. Drives the
   agent from the browser dashboard (password-protected).
2. For sites needing login, operator opens `hermes-browser.alekseev.us` → Cloudflare Access →
   `camofox:6080` (noVNC) → sees and controls the **live** Camoufox browser, logs in / solves MFA.
   Cookies persist to the per-`userId` profile on the camofox data volume.
3. The Hermes agent (running inside `hermes-webui`) routes **all** browser tools through Camoufox
   because `CAMOFOX_URL` is set. With a stable `CAMOFOX_USER_ID` + `CAMOFOX_ADOPT_EXISTING_TAB=true`,
   it adopts the operator's authenticated tab/profile instead of creating a fresh one, and does
   **not** destroy it at task end. The agent inherits the authenticated session.

## 5. Component specifications

> Image tags below are the current pinned targets; pin by **digest** in the final compose and let
> Renovate track upstream (consistent with the repo's other stacks).

### 5.1 `camofox` — stealth browser + remote login viewer

- **Image:** `ghcr.io/jo-inc/camofox-browser:1.11.2` (multi-arch amd64/arm64).
- **Role:** Camoufox (anti-detect Firefox) as a REST-driven browser server, plus a noVNC viewer
  attached to the live browser display for interactive human login; persistent per-`userId`
  profiles.
- **Ports (internal only — never published to host):**
  | Port | Purpose | Reached by |
  |---|---|---|
  | `9377` | REST API (CAMOFOX) | `hermes-webui` over the docker network |
  | `6080` | noVNC web viewer | `cloudflared` → Cloudflare Access |
  | `5900` | raw VNC (x11vnc) | not exposed; internal to the viewer plumbing |
- **Key env:**
  | Var | Value | Notes |
  |---|---|---|
  | `ENABLE_VNC` | `1` | Turns on the VNC plugin (deps are already baked into the image). |
  | `VNC_BIND` | `0.0.0.0` | So `cloudflared` (separate container) can reach noVNC. Confirmed from the VNC plugin's `vnc-watcher.sh` (`websockify "$VNC_BIND:$NOVNC_PORT" ...`). |
  | `NOVNC_PORT` | `6080` | noVNC web port. |
  | `VNC_PASSWORD` | *(secret)* | **Required** when binding beyond loopback. Defense-in-depth behind Cloudflare Access. |
  | `CAMOFOX_ACCESS_KEY` | *(secret)* | **Server-side** global bearer auth: every REST request must carry `Authorization: Bearer <key>`; `/health` is exempt. Must equal the value Hermes sends via `CAMOFOX_API_KEY`. |
- **Volume:** `/mnt/spool/apps/data/hermes/camofox` → `/home/node/.camofox` (profiles, cookies,
  storage_state, traces).
- **Healthcheck:** `GET http://localhost:9377/health` (unauthenticated by design).
- **Capabilities:** none. No `--shm-size`, `--cap-add`, `privileged`, or seccomp changes (it's
  Firefox under Xvfb). Smoke-test shm under load during validation.

### 5.2 `hermes-webui` — web dashboard + Hermes agent (in-process)

- **Image:** `ghcr.io/nesquena/hermes-webui:<pinned>` (latest stable observed: `v0.51.760`,
  ~2026-06-30; multi-arch amd64/arm64). Pin a concrete version/digest, not `latest`.
- **Role:** Browser UI to drive Hermes; the Hermes agent runs **in-process** inside this
  container and reads its config/credentials from the mounted `~/.hermes` (`HERMES_HOME`).
- **Port (internal only):** `8787` → reached by `cloudflared` → Cloudflare Access.
- **Key env:**
  | Var | Value | Notes |
  |---|---|---|
  | `HERMES_WEBUI_HOST` | `0.0.0.0` | Bind so cloudflared can reach it. |
  | `HERMES_WEBUI_PORT` | `8787` | UI port. |
  | `HERMES_WEBUI_PASSWORD` | *(secret)* | **Mandatory.** UI executes shell/file/browser tools with access to `~/.hermes` secrets — treat as a privileged surface (Cloudflare Access in front + this password). |
  | `WANTED_UID` / `WANTED_GID` | host owner of `~/.hermes` | Avoids permission errors / startup crash on the mounted volume. |
  | `CAMOFOX_URL` | `http://camofox:9377` | Routes **all** agent browser tools through Camoufox. |
  | `CAMOFOX_API_KEY` | *(secret, = `CAMOFOX_ACCESS_KEY`)* | **Client-side** bearer Hermes sends to Camofox. Same value as camofox's `CAMOFOX_ACCESS_KEY`. ⚠️ Note the deliberate name mismatch. |
  | `CAMOFOX_USER_ID` | e.g. `operator` | Stable id → "externally managed" mode (skips destructive cleanup; never `DELETE /sessions/<id>`). |
  | `CAMOFOX_SESSION_KEY` | e.g. `visible-tab` | Stable session key used to match the tab during adoption. |
  | `CAMOFOX_ADOPT_EXISTING_TAB` | `true` | `GET /tabs?userId=<id>` and reuse the operator's tab. |
  | `ANTHROPIC_TOKEN` *or* `ANTHROPIC_API_KEY` | *(secret)* | Claude credential — OAuth setup-token (`sk-ant-oat-…`) or API key. Env wins over `.env`; image-agnostic (sidesteps HOME-path questions). |
  - **Not** set: `CAMOFOX_REWRITE_LOOPBACK_URLS` (only needed for non-Docker/loopback Camofox;
    here `camofox` is a Docker DNS name, not loopback).
- **Volumes:**
  - `/mnt/spool/apps/config/hermes/home` → `/home/hermeswebui/.hermes` (Hermes config + auth).
  - `/mnt/spool/apps/data/hermes/workspace` → `/workspace` (agent file outputs; optional).
- **Seeded config** (`~/.hermes/config.yaml`, created once on the volume):
  ```yaml
  model:
    provider: "anthropic"
    default: "claude-sonnet-4-6"   # confirm exact model id at deploy
  ```
  Rationale: model selection has no single env var; provider goes in `config.yaml`. Everything
  else (Claude credential, all `CAMOFOX_*`) is env-settable and env overrides the file.
- **Healthcheck:** HTTP GET on `:8787` (confirm a health path at deploy; fall back to a TCP check).

### 5.3 `cloudflared` — tunnel + access gateway

- **Image:** `cloudflare/cloudflared:<pinned>` (match the version pattern used in `hindsight.yaml`).
- **Role:** Named tunnel routing two hostnames to internal services; Cloudflare Access (configured
  out-of-band in the Cloudflare dashboard) enforces operator authentication.
- **Ingress:**
  | Hostname | → service |
  |---|---|
  | `hermes.alekseev.us` | `http://hermes-webui:8787` |
  | `hermes-browser.alekseev.us` | `http://camofox:6080` |
  | (catch-all) | `http_status:404` |
- **Config + creds:** follow the `hindsight` pattern — inline `configs:` for the tunnel config and
  a mounted creds file under `/mnt/spool/apps/config/hermes/cloudflared`.
- **User:** run as a non-root uid consistent with the other stacks.

## 6. Secrets & configuration strategy

**Constraint (from the `hindsight` stack):** this repo is deployed via **Portainer**, which parses
the compose file inside its own container without the host config dir mounted. Therefore
`env_file:` and host-bind-mounted `.env` files **do not work** for resolving values at deploy time.

**Approach:** follow the established `hindsight` pattern — **Docker secrets via host files**,
sourced into the process environment at container start, e.g. an entrypoint wrapper
`set -a; . /run/secrets/hermes_env; set +a; exec <original-cmd>`. Non-secret settings stay inline in
`environment:`.

**Values that are secrets** (live in host files under `/mnt/spool/apps/config/hermes/secrets/`,
referenced via `secrets:`):

- `HERMES_WEBUI_PASSWORD`
- `ANTHROPIC_TOKEN` (or `ANTHROPIC_API_KEY`)
- `CAMOFOX_API_KEY` (hermes-webui side) and `CAMOFOX_ACCESS_KEY` (camofox side) — **same value**
- `VNC_PASSWORD`
- cloudflared tunnel credentials file

> The exact per-image entrypoint wrap (camofox's CMD is `sh -c "node … server.js"`; hermes-webui's
> entrypoint is to be confirmed) is an **implementation-plan** detail. If an image natively supports
> `*_FILE` secret conventions, prefer that over wrapping its entrypoint.

### Claude OAuth provisioning (headless)

The `claude` CLI is **not** bundled in these images, so `claude setup-token` cannot run in-container.
Provision the credential from outside, in order of preference:

1. **OAuth setup-token via env (recommended initial):** run `claude setup-token` on your workstation
   (browser flow), then set `ANTHROPIC_TOKEN=sk-ant-oat-…` as a stack secret. Re-provision when it
   expires. Requires **Claude Max + extra-usage credits** (Pro cannot use this path).
2. **API key:** set `ANTHROPIC_API_KEY` instead (no expiry, pay-per-token). Good fallback / for testing.
3. **Refreshable credentials file (optional):** drop a Claude Code `~/.claude/.credentials.json`
   (with `refreshToken`) into the agent's HOME on the mounted volume. The exact HOME path inside
   `hermes-webui` must be confirmed at deploy; option 1/2 (env) avoids this entirely.

> **Anthropic billing caveat:** since 2026-04-04 third-party-tool OAuth traffic is billed as extra
> usage (not the base Max allowance); since 2026-06-15 Agent-SDK usage draws a separate credit pool.
> Do **not** use header-spoofing "bypass" tools — ToS gray area and brittle.

## 7. Networking & security

- All services on a private bridge network (`hermes-net`). **No host port publishing** for `8787`,
  `6080`, `9377`, `5900`.
- Only `hermes.alekseev.us` and `hermes-browser.alekseev.us` are reachable externally, via
  cloudflared, **gated by Cloudflare Access**.
- **Defense in depth:** Cloudflare Access **and** `HERMES_WEBUI_PASSWORD` (UI) / `VNC_PASSWORD`
  (noVNC). The camofox REST hop is additionally bearer-authenticated
  (`CAMOFOX_ACCESS_KEY` ⇄ `CAMOFOX_API_KEY`), with `/health` left open so Hermes' (unauthenticated)
  health probe still works.
- **Crown-jewel warning:** the noVNC viewer can log into *your* personal accounts, and the Hermes UI
  can run tools with access to your credentials. These are the most sensitive surfaces in the stack —
  Access policies should be tight (specific identities, short sessions).

## 8. Persistence (host paths)

| Path (host) | Mount | Contents |
|---|---|---|
| `/mnt/spool/apps/config/hermes/home` | hermes-webui `~/.hermes` | Hermes config.yaml, .env, auth.json, OAuth creds |
| `/mnt/spool/apps/config/hermes/secrets/` | docker secrets | secret files |
| `/mnt/spool/apps/config/hermes/cloudflared/` | cloudflared | tunnel config + creds |
| `/mnt/spool/apps/data/hermes/camofox` | camofox `/home/node/.camofox` | per-`userId` Firefox profiles, cookies, storage_state |
| `/mnt/spool/apps/data/hermes/workspace` | hermes-webui `/workspace` | agent file outputs (optional) |

## 9. The human-login → agent-handoff mechanism (detail + residual risk)

**Mechanism (all confirmed to exist):**
- jo-inc's VNC plugin runs `x11vnc -display <live-display> -shared` against the **same** Xvfb display
  the automation browser renders on, served via websockify/noVNC at `:6080`. So the operator sees and
  controls the *same* browser the agent uses.
- Profiles persist per `userId` under `~/.camofox/profiles/<hashed userId>`, so an authenticated
  session survives and is reused.
- Hermes' `CAMOFOX_USER_ID` + `CAMOFOX_SESSION_KEY` + `CAMOFOX_ADOPT_EXISTING_TAB=true` make the agent
  adopt the operator's existing tab and skip destructive cleanup.

**Residual risk (validate at deploy):** there is no published end-to-end "log in via noVNC, then the
agent adopts that exact live tab" recipe. The pieces are present and coherent, but the precise
operating procedure (who creates the initial tab for `userId`, ordering of human-login vs agent
adoption, profile-lock behavior) must be validated with a smoke test before relying on it. Fallback
if live tab-adoption proves flaky: rely on the **persistent per-`userId` profile** (log in once, the
agent's next task for that `userId` inherits cookies) and/or jo-inc's `GET /sessions/:userId/storage_state`
export — both lower-coupling and confirmed.

## 10. Stealth tuning & the GPU decision

**Do NOT pass the NVIDIA A400 (or any GPU) into the `camofox` container.** It would reduce stealth,
not improve it:

- Camoufox **spoofs** WebGL vendor/renderer strings from a database of *common consumer* GPUs and is
  designed around **software (Mesa/llvmpipe) rendering** — jo-inc deliberately ships llvmpipe and
  masks the "no-GPU / SwiftShader / llvmpipe" headless tell behind a realistic spoofed string.
- A real GPU creates a **string-vs-pixel mismatch**: the spoofed renderer string would not match the
  A400's actual hardware-rendered canvas/WebGL pixel hashes, and modern anti-bot systems cross-check
  those for internal consistency. That mismatch is a *stronger* detection signal than the thing it
  would "fix".
- An **A400 is a rare workstation GPU** (April-2024 Ampere pro card) — high-entropy, reads as
  non-consumer/datacenter hardware, the opposite of blending in.
- GPU-accelerated WebGL in a headless Firefox container (nvidia-container-toolkit + VirtualGL +
  EGL/GLX, then forcing HW WebGL) is fragile and **unsupported** by Camoufox / jo-inc.

**Out of scope (noted for the host):** the A400 is useful for a *separate* container — local LLM
inference, NVENC transcode, or CUDA — never the browser. Not part of this stack.

**The levers that actually move canvas/WebGL stealth** (Camoufox config to set/validate at deploy via
jo-inc's `camofox.config.json` / env and Hermes' Camofox options — exact keys confirmed against the
pinned image):

- `webgl_config` (vendor, renderer) **matching the spoofed OS** — and **never randomize** values
  (WAFs hash the WebGL fingerprint; random = instant mismatch).
- `geoip=true` for timezone/locale/geo coherence with the egress IP.
- **WebRTC leak prevention** (`block_webrtc` / proxy) — STUN-over-UDP can leak the real WAN IP behind
  an HTTP/TCP proxy.
- `humanize` for human-like cursor/scroll motion.
- A **quality residential egress / proxy** — IP reputation is decisive; datacenter IPs get blocked
  regardless of fingerprint (consistent with the residential-IP lesson from the `changedetection` stack).
- Canvas noise is **off by default**; if enabled, prefer consistent / content-aware noise.

## 11. Credential management for the agent (1Password) — optional, Phase 2

**Default (Phase 1): no agent credentials, no 1Password.** The stack's primary auth model is the
**human logging in via noVNC**, after which Camofox **persists the session** (cookies survive) and the
agent reuses it per `userId`. For most use this covers logins with **zero secret exposure to the
agent**. Start here.

**Add 1Password only for unattended, agent-driven login** — when the agent must log in itself (fresh
sessions, fast-expiring cookies, TOTP-gated sites) with no human at the noVNC console. This is the only
scenario that justifies the added trust surface.

**Recommended wiring (if/when added):**

- **Approach:** the **official Hermes 1Password skill** (`hermes skills install official/security/1password`)
  + the **`op` CLI** + a scoped **Service Account**. No Connect server, no MCP server — the official
  skill supports TOTP (`op read "op://…/one-time password?attribute=otp"`); Connect can't compute TOTP
  and only pays off at high request volume; and there is **no production-grade headless 1Password MCP**
  (1Password's own position is that secrets should not flow through an LLM/MCP channel).
- **Containers:** **none new** — bake the binary into the Hermes image:
  `COPY --from=1password/op:2 /usr/local/bin/op /usr/local/bin/op`.
- **Vault scoping:** a **dedicated, read-only** vault containing *only* the site logins the agent needs
  (never the personal vault): `op service-account create hermes-agent --expires-in 4w --vault hermes-agent-logins:read_items`.
- **Token delivery:** `OP_SERVICE_ACCOUNT_TOKEN` as a **host-file Docker secret** (same pattern as the
  rest of the stack), sourced in the entrypoint.
- **Hermes gotcha:** Hermes scrubs env vars containing `KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL/AUTH` from
  tool subprocesses, so re-allow it via `terminal.env_passthrough: [OP_SERVICE_ACCOUNT_TOKEN]` in
  `config.yaml`.

**Plan-tier note:** 1Password **Service Accounts are available on Individual, Families, Teams, and
Business** plans (per 1Password's service-account rate-limits docs, which list Individual/Families at
1,000 reads/hr and 100 writes/hr). The operator is on a **Families** plan, which supports this path.
Caveat: the finest-grained per-item **read-only** permission is a **Business** feature — on Families a
service account is scoped at the **vault** level, so achieve least-privilege by creating a dedicated,
minimal vault for the agent (rather than relying on a read-only grant).

**Security (load-bearing):** an LLM-driven browser agent is **prompt-injectable** — a hostile page may
try to coax it into exfiltrating whatever it can read. Blast radius = everything in that one vault, so
keep the vault tiny, read-only, service-account-scoped, `--expires-in`-rotated, token-as-secret, and
audited via 1Password's service-account usage report. Keep the agent off the open internet (behind
Cloudflare Access, as designed).

**Do NOT use 1Password for the stack's own secrets** (`ANTHROPIC_*`, `VNC_PASSWORD`, camofox key,
`HERMES_WEBUI_PASSWORD`): under Portainer, host-shell `op inject` / `op run` cannot run, and a
container-side fetch still needs a bootstrap token that itself becomes a Docker secret — strictly more
complex than the §6 host-file Docker-secrets approach, with no security gain. Keep §6 as-is.

## 12. Testing & validation

1. **Static:** `./scripts/validate-stack.sh hermes` (docker-compose config parse).
2. **Bring-up:** deploy; confirm all three containers healthy; camofox `/health` returns 200.
3. **noVNC reachability:** `hermes-browser.alekseev.us` loads the live Camoufox browser through
   Cloudflare Access; `VNC_PASSWORD` is enforced.
4. **Agent ↔ camofox:** from the Hermes UI, run a browse task on a benign site; confirm it routes
   through Camofox (REST traffic on `:9377` with bearer) and returns content.
5. **Stealth sanity:** browse a fingerprint/anti-bot check page; confirm Camoufox stealth behaves.
6. **Auth handoff (the spike):** log into a test account via noVNC, then have the agent operate in the
   authenticated context using `CAMOFOX_USER_ID` + `ADOPT_EXISTING_TAB`. Record the working procedure.
7. **Claude:** confirm the agent reaches Claude via the provisioned credential; verify model id.

## 13. Confirmed vs. validate-at-deploy

**Confirmed (code/docs verified):**
- jo-inc published multi-arch image includes the VNC plugin (build-chain traced); `ENABLE_VNC=1`.
- Hermes routes all browser tools through Camofox when `CAMOFOX_URL` is set.
- Hermes authenticates to a key-protected Camofox via `CAMOFOX_API_KEY` → `Authorization: Bearer …`;
  `/health` probe sends no auth (so keep `/health` open).
- Exact `CAMOFOX_*` client env names (only `CAMOFOX_ACCESS_KEY` was wrong → it's `CAMOFOX_API_KEY`).
- `nesquena/hermes-webui` runs the agent in-process; single container is the right topology.
- Claude OAuth supported (`hermes auth add anthropic --type oauth` / `hermes model`), Max+credits required.

**Validate at deploy (flagged honestly):**
- End-to-end noVNC-login → live tab-adoption procedure (§9).
- `hermes-webui` container HOME path (only matters for the optional credentials-file OAuth path; the
  env path avoids it).
- Exact camofox VNC env names beyond `ENABLE_VNC`/`VNC_PASSWORD`/`NOVNC_PORT` (`VNC_BIND` taken from
  plugin source `vnc-watcher.sh`; confirm against the running image).
- `hermes-webui` health endpoint path; the entrypoint to wrap for secret-sourcing.
- Exact pinned digests for all three images; Cloudflare version pin.
- Exact Camoufox stealth keys exposed by the pinned jo-inc image (`webgl_config`, `geoip`,
  `block_webrtc`, `humanize`, proxy) and how Hermes passes them through (§10).
- (If Phase 2) exact 1Password service-account vault scoping on a Families plan (vault-level;
  per-item read-only is Business-only); the official Hermes 1Password skill name/path and
  `terminal.env_passthrough` behavior on the pinned image (§11).

## 14. Open questions / future

- Swap the reasoning model later (Nous Portal one-OAuth-many-models, OpenRouter, or your `litellm`).
- Multiple isolated profiles (per-site `userId`s) if one shared profile becomes limiting.
- Optional: expose Hermes' OpenAI-compatible API (`:8642`) to other internal tools later.
- **Phase 2 — 1Password agent-driven login** (§11): enable once you've confirmed the Teams/Business
  plan and want unattended logins; needs the `op` binary in the Hermes image + a scoped service account.
- **Residential egress / proxy** for the browser if target sites block your server's IP reputation
  (Camoufox handles fingerprint, not IP) — wire via Camoufox proxy/GeoIP.
- Put the A400 to use in a *separate* stack (local LLM inference / NVENC), not this one.

## 15. Appendix — reference compose (design target, finalized in the implementation plan)

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
# NOTE: reference topology only. Secret-sourcing entrypoints, pinned digests, exact healthcheck
# paths, and cloudflared config are finalized in the implementation plan.
services:

  camofox:
    image: ghcr.io/jo-inc/camofox-browser:1.11.2   # pin by digest
    container_name: camofox
    hostname: camofox
    restart: unless-stopped
    environment:
      - ENABLE_VNC=1
      - VNC_BIND=0.0.0.0
      - NOVNC_PORT=6080
      # VNC_PASSWORD, CAMOFOX_ACCESS_KEY via secrets (sourced at entrypoint)
    volumes:
      - /mnt/spool/apps/data/hermes/camofox:/home/node/.camofox
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9377/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks: [hermes-net]

  hermes-webui:
    image: ghcr.io/nesquena/hermes-webui:v0.51.760  # pin by digest
    container_name: hermes-webui
    hostname: hermes-webui
    restart: unless-stopped
    depends_on:
      camofox:
        condition: service_healthy
    environment:
      - HERMES_WEBUI_HOST=0.0.0.0
      - HERMES_WEBUI_PORT=8787
      - WANTED_UID=1000
      - WANTED_GID=1000
      - CAMOFOX_URL=http://camofox:9377
      - CAMOFOX_USER_ID=operator
      - CAMOFOX_SESSION_KEY=visible-tab
      - CAMOFOX_ADOPT_EXISTING_TAB=true
      # HERMES_WEBUI_PASSWORD, CAMOFOX_API_KEY (== camofox CAMOFOX_ACCESS_KEY),
      # ANTHROPIC_TOKEN|ANTHROPIC_API_KEY via secrets (sourced at entrypoint)
    volumes:
      - /mnt/spool/apps/config/hermes/home:/home/hermeswebui/.hermes
      - /mnt/spool/apps/data/hermes/workspace:/workspace
    networks: [hermes-net]

  cloudflared:
    image: cloudflare/cloudflared:2026.6.1   # match hindsight; pin
    container_name: hermes-cloudflared
    command: --config /etc/cloudflared/config.yml tunnel run
    restart: unless-stopped
    volumes:
      - /mnt/spool/apps/config/hermes/cloudflared:/etc/cloudflared
    depends_on:
      - hermes-webui
      - camofox
    networks: [hermes-net]

networks:
  hermes-net:

# secrets: { ... } finalized in the implementation plan (hindsight-style host files)
```
