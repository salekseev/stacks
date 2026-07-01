# Hermes Gateway + Open WebUI + Dashboard Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the crash-looping `hermes-agent` source-populator + third-party `hermes-webui` with the first-party topology — a real `hermes gateway run` daemon (OpenAI API `:8642` + dashboard `:9119`) fronted by Open WebUI, keeping camofox + noVNC + cloudflared.

**Architecture:** One `stacks/hermes.yaml` rewrite (4 services on `hermes-net`, no published ports, all access via cloudflared + one Cloudflare Access app). Repo-side work is a single compose rewrite validated with `validate-stack.sh`; runtime deploy + smoke tests are host-side on `silverstone` (the assistant cannot reach the host or Cloudflare).

**Tech Stack:** Docker Compose, `nousresearch/hermes-agent` (gateway+dashboard), `open-webui`, `cloudflare/cloudflared`, `redf0x1/camofox-browser`, Portainer stack env-var interpolation.

**Spec:** `docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md`

---

## File Structure

- **Modify (full rewrite):** `stacks/hermes.yaml` — the 4-service target topology.
- **Modify (1-line status note):** `docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md` — mark superseded, point to the new spec.
- **No tests/scripts created** — verification is `./scripts/validate-stack.sh hermes` (static parse) + host-side smoke tests (Tasks 3–6).

**Split of responsibility:** Tasks 1–2 are **repo-side, assistant-executable** on `master`. Tasks 3–6 are a **host-side operator runbook** run manually on `silverstone` via Portainer/Cloudflare — they are NOT assistant-executable and are written as action+verify checklists.

---

## Task 1: Rewrite `stacks/hermes.yaml` to the gateway + Open WebUI + dashboard topology

**Files:**
- Modify (replace entire contents): `stacks/hermes.yaml`
- Verify with: `./scripts/validate-stack.sh hermes`

- [ ] **Step 1: Replace the entire contents of `stacks/hermes.yaml` with:**

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Hermes agent stack — first-party gateway + Open WebUI + dashboard.
# See docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md
# Secrets supplied via Portainer stack environment variables interpolated below ${VAR}.
# Required Portainer stack env vars:
#   CAMOFOX_SHARED_KEY        - camofox REST bearer (same secret on camofox + gateway)
#   HERMES_API_SERVER_KEY     - bearer for the gateway OpenAI API :8642 (== Open WebUI OPENAI_API_KEY); >=8 chars
#   HERMES_DASHBOARD_PASSWORD - dashboard basic-auth password (real 2nd factor behind Access)
#   HERMES_DASHBOARD_SECRET   - dashboard token-signing key (openssl rand -base64 32)
#   ANTHROPIC_TOKEN           - Claude OAuth setup-token (sk-ant-oat-...)
#   HERMES_TUNNEL_ID          - Cloudflare tunnel UUID
# Nothing published to host; only cloudflared reaches origins, gated by one Cloudflare Access app.

services:

  camofox:
    restart: unless-stopped
    # redf0x1 fork of jo-inc/camofox-browser: same REST API, but ships the noVNC stack.
    # Server bearer = CAMOFOX_API_KEY (== CAMOFOX_SHARED_KEY). noVNC is on-demand via
    # POST /sessions/<userId>/toggle-display; x11vnc -nopw, gated only by Cloudflare Access.
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
    networks:
      - hermes-net

  hermes-gateway:
    restart: unless-stopped
    # First-party agent daemon. `gateway run` serves the OpenAI-compatible API on :8642 and
    # (HERMES_DASHBOARD=1) the dashboard on :9119 as a co-resident s6-rc service. s6 supervises
    # both, so a mis-start restarts in-container (no Docker crash-loop).
    #
    # Image pinned by digest: the ONLY published image carrying BOTH the camofox bearer-auth fix
    # (#20476, merged to main 2026-06-29) and the gateway sleep/PATH crash fix (#36208). No release
    # tag has both yet. STOPGAP — migrate to the first tag > v2026.6.19 containing commit babd916:
    #   gh api repos/NousResearch/hermes-agent/compare/babd916...<tag> --jq '{status,behind_by}'
    #   docker buildx imagetools inspect docker.io/nousresearch/hermes-agent:<tag> --format '{{.Manifest.Digest}}'
    image: nousresearch/hermes-agent@sha256:c30340ee58dde86c284864b1016f474ec48c4a70ed49d24920cab083f670f417
    container_name: hermes-gateway
    hostname: hermes-gateway
    command: gateway run
    depends_on:
      camofox:
        condition: service_healthy
    environment:
      # /opt/data (HERMES_HOME) is chowned to this uid/gid by the image's s6 init.
      - HERMES_UID=1000
      - HERMES_GID=1000
      # OpenAI-compatible API server (consumed by Open WebUI)
      - API_SERVER_ENABLED=true
      - API_SERVER_HOST=0.0.0.0
      - API_SERVER_KEY=${HERMES_API_SERVER_KEY}
      # First-party dashboard — fail-closed on a non-loopback bind, so basic-auth is REQUIRED.
      - HERMES_DASHBOARD=1
      - HERMES_DASHBOARD_HOST=0.0.0.0
      - HERMES_DASHBOARD_PORT=9119
      - HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
      - HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${HERMES_DASHBOARD_PASSWORD}
      - HERMES_DASHBOARD_BASIC_AUTH_SECRET=${HERMES_DASHBOARD_SECRET}
      # NEVER set HERMES_DASHBOARD_INSECURE (bypasses the auth gate).
      # Route all browser tools server-side through the camofox sidecar (same vars as before).
      - CAMOFOX_URL=http://camofox:9377
      - CAMOFOX_API_KEY=${CAMOFOX_SHARED_KEY}
      - CAMOFOX_USER_ID=operator
      - CAMOFOX_SESSION_KEY=visible-tab
      - CAMOFOX_ADOPT_EXISTING_TAB=true
      # Claude via OAuth setup-token (see spec §9 for the daemon-expiry runbook).
      - ANTHROPIC_TOKEN=${ANTHROPIC_TOKEN}
    volumes:
      - /mnt/spool/apps/data/hermes/gateway:/opt/data
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:9119/api/status',timeout=5).status==200 else 1)"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    networks:
      - hermes-net

  open-webui:
    restart: unless-stopped
    # Daily chat client -> gateway /v1. No published ports: trusted-header SSO is only safe
    # because nothing but cloudflared can reach :8080 to forge Cf-Access-Authenticated-User-Email.
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
    networks:
      - hermes-net

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
    networks:
      - hermes-net

configs:
  cloudflared:
    content: |
      tunnel: ${HERMES_TUNNEL_ID}
      credentials-file: /etc/cloudflared/creds/tunnel.json
      ingress:
        # Origin-side Cloudflare Access JWT validation. All three hosts share ONE Access app /
        # audTag (team alekseev); cloudflared verifies Cf-Access-Jwt-Assertion against the team
        # JWKS + audTag before proxying.
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

- [ ] **Step 2: Validate the rewritten stack parses**

Run: `./scripts/validate-stack.sh hermes`
Expected: `Validation successful for stacks/hermes.yaml`. Unset-variable warnings (e.g. `The "HERMES_API_SERVER_KEY" variable is not set. Defaulting to a blank string.`) are printed to stderr and are **expected** — they don't fail validation (same behavior as the current file).

- [ ] **Step 3: Confirm the rendered topology wiring**

Run: `docker-compose -f stacks/hermes.yaml config 2>/dev/null | grep -E 'container_name|image:|8642|9119|8080|hermes-gateway:8642|camofox:9377'`
Expected: shows `hermes-gateway`, `open-webui`, `camofox`, `hermes-cloudflared`; the `nousresearch/hermes-agent@sha256:c30340ee…` digest; `OPENAI_API_BASE_URL` = `http://hermes-gateway:8642/v1`; `CAMOFOX_URL` = `http://camofox:9377`. Confirm **no** `hermes-webui`, `hermes-agent`, or `hermes-agent-src` remain.

- [ ] **Step 4: Commit**

```bash
git add stacks/hermes.yaml
git commit -m "$(cat <<'EOF'
feat(hermes): port stack to gateway + Open WebUI + dashboard

Replace the crash-looping hermes-agent source-populator and third-party
hermes-webui (+ hermes-agent-src volume) with a first-party hermes gateway
daemon: OpenAI API :8642 + dashboard :9119 in one container, Open WebUI as
the chat client (trusted-header SSO behind Cloudflare Access), camofox and
noVNC unchanged. Image digest-pinned (only build with both #20476 + #36208
fixes). Ref docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Mark the prior spec superseded

**Files:**
- Modify: `docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md:5`

- [ ] **Step 1: Insert a superseded pointer immediately under the `- **Status:**` line (line 5)**

Add this line right after the existing `- **Status:** …` bullet at the top of the file:

```markdown
- **Superseded (UI/agent-runtime topology):** by `2026-06-30-hermes-gateway-openwebui-port-design.md` — the `hermes-webui` + `hermes-agent-src` in-process topology is replaced by `hermes gateway run` (API :8642 + dashboard :9119) + Open WebUI. Camofox / noVNC / cloudflared sections below still apply.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md
git commit -m "$(cat <<'EOF'
docs(hermes): mark webui-topology spec superseded by the gateway port

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 (OPERATOR, on `silverstone`): Provision secrets, dirs, and prune old state

> Not assistant-executable. Run these on the host / in Portainer.

- [ ] **Step 1: Create the new host data dirs (owned by uid/gid 1000)**

```bash
sudo mkdir -p /mnt/spool/apps/data/hermes/gateway /mnt/spool/apps/data/hermes/open-webui
sudo chown -R 1000:1000 /mnt/spool/apps/data/hermes/gateway /mnt/spool/apps/data/hermes/open-webui
```

- [ ] **Step 2: Set/adjust Portainer stack environment variables**

Add: `HERMES_API_SERVER_KEY` (≥8 chars random), `HERMES_DASHBOARD_PASSWORD` (strong, unique), `HERMES_DASHBOARD_SECRET` (`openssl rand -base64 32`).
Keep: `CAMOFOX_SHARED_KEY`, `ANTHROPIC_TOKEN`, `HERMES_TUNNEL_ID`.
Remove: `HERMES_WEBUI_PASSWORD` (and `VNC_PASSWORD` if still present).

Generate the two new random secrets:
```bash
echo "HERMES_API_SERVER_KEY=$(openssl rand -hex 24)"
echo "HERMES_DASHBOARD_SECRET=$(openssl rand -base64 32)"
```
Verify: the Portainer stack env list shows all six required vars and no `HERMES_WEBUI_PASSWORD`.

---

## Task 4 (OPERATOR): Cloudflare route + Access for `hermes-dashboard`

> Not assistant-executable. Done in the Cloudflare dashboard.

- [ ] **Step 1: Add the DNS/tunnel hostname**

In the tunnel config, `hermes-dashboard.alekseev.us` is already routed by the inline cloudflared `ingress:` (Task 1) to `http://hermes-gateway:9119`. Create the corresponding **public hostname / CNAME** for `hermes-dashboard.alekseev.us` pointing at the tunnel (same as `hermes` / `hermes-browser`).

- [ ] **Step 2: Attach it to the existing Access application**

Add `hermes-dashboard.alekseev.us` to the **same** Cloudflare Access application already protecting `hermes` and `hermes-browser` (audTag `f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d`, team `alekseev`).
Verify: `curl -sI https://hermes-dashboard.alekseev.us` returns the Access login redirect (302 to the Access team domain), not a direct 200/404.

- [ ] **Step 3 (hardening): tighten the Access policy**

Because the dashboard grants full machine control (embedded shell, edits `.env`/API keys), set the Access policy to a specific identity/email and a short session TTL. Verify the policy lists only intended identities.

---

## Task 5 (OPERATOR): Deploy and seed model config

> Not assistant-executable.

- [ ] **Step 1: Redeploy the stack in Portainer (pull image)**

Update the `hermes` stack from the new `stacks/hermes.yaml`, with "Re-pull image" enabled. The old `hermes-agent` and `hermes-webui` containers are removed; `hermes-gateway` and `open-webui` are created.

- [ ] **Step 2: Verify the gateway started cleanly (no crash-loop)**

```bash
docker ps --filter name=hermes-gateway --format '{{.Status}}'   # expect: Up ... (healthy) after ~1 min
docker logs --tail 50 hermes-gateway                            # expect: gateway + dashboard services up; NO restart loop, NO FileNotFoundError
```

- [ ] **Step 3: Seed the model provider config (if not already set)**

```bash
docker exec hermes-gateway sh -c 'cat >> /opt/data/config.yaml <<"YAML"
model:
  provider: anthropic
  default: claude-opus-4-8   # confirm the exact id the anthropic adapter accepts
YAML'
docker restart hermes-gateway
```
Verify: `docker exec hermes-gateway cat /opt/data/config.yaml` shows the `model:` block.

- [ ] **Step 4: Prune the orphaned old volume (after confirming the new stack works)**

```bash
docker volume ls | grep hermes-agent-src   # if present and orphaned:
docker volume rm hermes-agent-src
```

---

## Task 6 (OPERATOR): Smoke tests

> Not assistant-executable. Run after Task 5.

- [ ] **Step 1: Dashboard auth gate is engaged**

```bash
docker exec hermes-gateway python3 -c "import urllib.request,json; print(json.load(urllib.request.urlopen('http://localhost:9119/api/status',timeout=5)))"
```
Expected: JSON with `auth_required: true` and `basic` among `auth_providers`.

- [ ] **Step 2: Gateway API exposes the model**

```bash
docker exec hermes-gateway python3 -c "import os,urllib.request; r=urllib.request.Request('http://localhost:8642/v1/models',headers={'Authorization':'Bearer '+os.environ['API_SERVER_KEY']}); print(urllib.request.urlopen(r,timeout=5).read().decode())"
```
Expected: a JSON model list (200), not 401/404.

- [ ] **Step 3: Open WebUI loads and auto-logs-in**

Browse `https://hermes.alekseev.us` → Cloudflare Access → Open WebUI loads without a second login (trusted-header SSO); the Hermes model appears in the model picker. Confirm the first auto-provisioned user has the **admin** role (Admin → Users).

- [ ] **Step 4: Chat reaches Claude**

Send a plain prompt in Open WebUI. Expected: a streamed Claude response (validates `ANTHROPIC_TOKEN` + model id).

- [ ] **Step 5: Browser tool runs server-side through camofox**

Ask the agent to open a benign page (e.g. "what's on example.com"). Expected: it returns real rendered content; `docker logs --tail 30 camofox` shows an authenticated REST hit on `:9377` (no 403).

- [ ] **Step 6: noVNC login-handoff still works**

Follow the existing runbook: `POST /sessions/operator/toggle-display` → open `https://hermes-browser.alekseev.us/vnc.html?autoconnect=true&resize=scale` through Access → log in by hand → the agent's next browse reuses the `operator` profile.

- [ ] **Step 7: Dashboard is reachable and authenticated**

Browse `https://hermes-dashboard.alekseev.us` → Access → basic-auth prompt (user `admin` / `HERMES_DASHBOARD_PASSWORD`) → Sessions / Cron / Config tabs load.

---

## Self-Review (completed by planner)

- **Spec coverage:** §4 topology → Task 1 compose; §5.2 gateway env → Task 1; §5.3 open-webui env → Task 1; §5.4 cloudflared ingress → Task 1; §6 secrets → Task 3; §8 image pin → Task 1 (digest + migration note); §9 OAuth → Task 5 seed + spec runbook; §10 migration split → Tasks 1–2 (repo) / 3–6 (host); §11 validation → Task 6; §12 risks → surfaced in Task 5 (crash-loop check) and Task 6.
- **Placeholder scan:** none — the full compose, exact env, and exact verify commands are inline. The only deferred item is the model id (explicitly flagged "confirm the exact id").
- **Type/name consistency:** `HERMES_API_SERVER_KEY` is the single source used by both `API_SERVER_KEY` (gateway) and `OPENAI_API_KEY` (open-webui); `CAMOFOX_SHARED_KEY` used by both camofox and gateway; audTag identical across all three ingress rules; no dangling `hermes-webui`/`hermes-agent-src` references.
```
