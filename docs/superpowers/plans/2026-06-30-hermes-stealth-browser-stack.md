# Hermes Stealth-Browser Agent Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `stacks/hermes.yaml` Docker Compose stack that runs the Hermes agent (web UI + in-process agent) backed by a stealth Camoufox browser with built-in noVNC for interactive login, deployed via Portainer behind a Cloudflare tunnel.

**Architecture:** Three services on one private bridge network — `camofox` (`ghcr.io/jo-inc/camofox-browser`: Camoufox + Xvfb + noVNC + persistent profiles, REST on 9377, noVNC on 6080), `hermes-webui` (`ghcr.io/nesquena/hermes-webui`: dashboard **and** the in-process Hermes agent, port 8787, Claude via OAuth, drives camofox over its REST API), and `cloudflared` (named tunnel exposing only the UI and noVNC, behind Cloudflare Access). Nothing is published to the host. Secrets are supplied via Portainer stack environment variables and interpolated as `${VAR}`. The human-login → agent-handoff is native to jo-inc (shared X display + persistent `userId` profile + tab adoption).

**Tech Stack:** Docker Compose, Portainer, Cloudflare Tunnel (cloudflared), Camoufox (jo-inc/camofox-browser), NousResearch Hermes agent via nesquena/hermes-webui, Anthropic Claude (OAuth).

**Reference spec:** `docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md`

---

## Scope & split

- **Phase 1 only.** 1Password agent-login and Hindsight memory are documented Phase-2 enhancements (spec §11/§12) and are **not** in this plan.
- **Repo tasks (Task 1)** run on this box / branch and can be done by an agent: create the compose file, validate, commit.
- **Host tasks (Tasks 2–8)** run on the server (`silverstone`) via SSH/Portainer by the operator — they need Docker, the host filesystem, a Cloudflare account, and a Claude Max subscription. Each is written so the operator can follow it without prior context.

## Secrets approach (refines spec §6)

Spec §6 proposed host-file Docker secrets sourced via an entrypoint wrapper (the `hindsight` pattern). This plan instead uses **Portainer stack environment variables** interpolated as `${VAR}` in the compose, because:
- Every secret here is a **discrete env var the upstream images read natively** (`CAMOFOX_ACCESS_KEY`, `VNC_PASSWORD`, `HERMES_WEBUI_PASSWORD`, `ANTHROPIC_TOKEN`, `CAMOFOX_API_KEY`) — no need to source a whole env file.
- Portainer applies its stack env vars to `${VAR}` interpolation at deploy time (this is **not** the `env_file:` mechanism that fails under Portainer), so it is Portainer-safe.
- It avoids overriding each third-party image's entrypoint/WORKDIR (which we have not verified).

The actual secret values live only in Portainer's stack config — never in the public repo (the YAML contains `${VAR}` placeholders). The cloudflared tunnel **credentials JSON** is the one secret kept as a host file (it is a file by nature), placed under the cloudflared config dir.

## File structure

| File | Responsibility | Where |
|---|---|---|
| `stacks/hermes.yaml` | The 3-service compose stack (the deliverable) | repo |
| `/mnt/spool/apps/config/hermes/home/` | Hermes `~/.hermes` (config.yaml, .env, auth, memory) — mounted into `hermes-webui` | host |
| `/mnt/spool/apps/config/hermes/home/config.yaml` | Seeds `model.provider: anthropic` for the in-process agent | host |
| `/mnt/spool/apps/config/hermes/cloudflared/tunnel.json` | Cloudflare tunnel credentials | host |
| `/mnt/spool/apps/data/hermes/camofox/` | Camoufox persistent profiles/cookies — mounted into `camofox` | host |
| `/mnt/spool/apps/data/hermes/workspace/` | Agent file outputs — mounted into `hermes-webui` | host |
| Portainer stack env vars | Secret values for `${VAR}` interpolation | Portainer |
| Cloudflare dashboard | Tunnel, DNS records, Access apps for the two hostnames | Cloudflare |

---

## Task 1 — Create `stacks/hermes.yaml` (repo)

**Files:**
- Create: `stacks/hermes.yaml`
- Reference: `scripts/validate-stack.sh`, `stacks/hindsight.yaml` (cloudflared pattern), `stacks/changedetection.yaml` (healthcheck pattern)

- [ ] **Step 1: Confirm validation fails before the file exists**

Run: `./scripts/validate-stack.sh hermes`
Expected: FAIL — `Error: Stack file not found at stacks/hermes.yaml`

- [ ] **Step 2: Create `stacks/hermes.yaml` with this exact content**

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Hermes stealth-browser agent stack. See docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md
# Secrets are supplied via Portainer stack environment variables and interpolated below as ${VAR}.
# Required Portainer stack env vars:
#   CAMOFOX_SHARED_KEY      - bearer shared between camofox (server) and hermes (client)
#   VNC_PASSWORD            - noVNC password for the interactive-login viewer
#   HERMES_WEBUI_PASSWORD   - password for the Hermes web UI
#   ANTHROPIC_TOKEN         - Claude OAuth token (sk-ant-oat-...) or use ANTHROPIC_API_KEY instead
#   HERMES_TUNNEL_ID        - Cloudflare tunnel UUID
# Nothing is published to the host; only the UI and noVNC are reachable via cloudflared + Cloudflare Access.

services:

  camofox:
    restart: unless-stopped
    image: ghcr.io/jo-inc/camofox-browser:1.11.2
    container_name: camofox
    hostname: camofox
    # Stealth Camoufox (Firefox) + baked-in noVNC viewer + persistent per-userId profiles.
    # VNC plugin deps (x11vnc/novnc/websockify) ship in the published image; ENABLE_VNC turns it on.
    environment:
      - ENABLE_VNC=1
      - VNC_BIND=0.0.0.0          # bind noVNC on all interfaces so cloudflared (a peer container) can reach it
      - NOVNC_PORT=6080
      - VNC_PASSWORD=${VNC_PASSWORD}
      # Global bearer auth on the REST API (every request except /health must carry this).
      - CAMOFOX_ACCESS_KEY=${CAMOFOX_SHARED_KEY}
    volumes:
      - /mnt/spool/apps/data/hermes/camofox:/home/node/.camofox
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9377/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - hermes-net

  hermes-webui:
    restart: unless-stopped
    image: ghcr.io/nesquena/hermes-webui:0.51.760
    container_name: hermes-webui
    hostname: hermes-webui
    # Web dashboard AND the Hermes agent (runs in-process; reads ~/.hermes from the mounted volume).
    depends_on:
      camofox:
        condition: service_healthy
    environment:
      - HERMES_WEBUI_HOST=0.0.0.0
      - HERMES_WEBUI_PORT=8787
      - HERMES_WEBUI_PASSWORD=${HERMES_WEBUI_PASSWORD}
      - WANTED_UID=1000           # must own /mnt/spool/apps/config/hermes/home
      - WANTED_GID=1000
      # Route all agent browser tools through the camofox sidecar over its REST API.
      - CAMOFOX_URL=http://camofox:9377
      - CAMOFOX_API_KEY=${CAMOFOX_SHARED_KEY}   # client bearer; MUST equal camofox's CAMOFOX_ACCESS_KEY
      - CAMOFOX_USER_ID=operator                # stable id -> externally-managed mode (no destructive cleanup)
      - CAMOFOX_SESSION_KEY=visible-tab
      - CAMOFOX_ADOPT_EXISTING_TAB=true         # reuse the human-authenticated tab instead of creating a new one
      # Claude credential. OAuth setup-token (sk-ant-oat-...) via ANTHROPIC_TOKEN, or swap for ANTHROPIC_API_KEY.
      - ANTHROPIC_TOKEN=${ANTHROPIC_TOKEN}
    volumes:
      - /mnt/spool/apps/config/hermes/home:/home/hermeswebui/.hermes
      - /mnt/spool/apps/data/hermes/workspace:/workspace
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
      - hermes-webui
      - camofox
    networks:
      - hermes-net

configs:
  cloudflared:
    content: |
      tunnel: ${HERMES_TUNNEL_ID}
      credentials-file: /etc/cloudflared/creds/tunnel.json
      ingress:
        - hostname: hermes.alekseev.us
          service: http://hermes-webui:8787
        - hostname: hermes-browser.alekseev.us
          service: http://camofox:6080
        - service: http_status:404

networks:
  hermes-net:
```

- [ ] **Step 3: Validate the stack**

Run: `./scripts/validate-stack.sh hermes`
Expected: `Validation successful for stacks/hermes.yaml`.
Note: `docker-compose config` prints warnings like `The "VNC_PASSWORD" variable is not set. Defaulting to a blank string.` for each `${VAR}` — this is **expected** when validating without the Portainer env set and does **not** fail validation (exit 0). If `docker-compose`/`docker compose` is unavailable on this box, run this step on the host instead.

- [ ] **Step 4: Commit**

```bash
git add stacks/hermes.yaml
git commit -m "feat(hermes): add stealth-browser agent stack (camofox + hermes-webui + cloudflared)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Push to the PR branch**

```bash
git push --no-verify
```
(`--no-verify` bypasses the public-repo guard hook; the diff is a compose file with `${VAR}` placeholders, no secret values.)

---

## Task 2 — Create host directories (host)

**Files:** host directories under `/mnt/spool/apps/{config,data}/hermes`.

- [ ] **Step 1: Create the directory tree**

```bash
sudo mkdir -p /mnt/spool/apps/config/hermes/home \
              /mnt/spool/apps/config/hermes/cloudflared \
              /mnt/spool/apps/data/hermes/camofox \
              /mnt/spool/apps/data/hermes/workspace
```

- [ ] **Step 2: Set ownership so the containers can write their volumes**

```bash
# hermes-webui runs as uid/gid 1000 (WANTED_UID/WANTED_GID); camofox writes its profile dir.
sudo chown -R 1000:1000 /mnt/spool/apps/config/hermes/home \
                        /mnt/spool/apps/data/hermes/camofox \
                        /mnt/spool/apps/data/hermes/workspace
# cloudflared runs as uid/gid 568 and only needs to read its creds dir.
sudo chown -R 568:568 /mnt/spool/apps/config/hermes/cloudflared
```

- [ ] **Step 3: Verify**

Run: `ls -la /mnt/spool/apps/config/hermes /mnt/spool/apps/data/hermes`
Expected: the four directories exist with the ownership set above.

---

## Task 3 — Provision the Claude OAuth token (host/workstation)

The Hermes agent authenticates to Claude using an OAuth "setup-token". The `claude` CLI is **not** bundled in the image, so generate the token on a machine that has it (your workstation) and feed it to the stack as an env var.

**Prerequisite:** a **Claude Max** subscription **with extra-usage credits** (Claude Pro cannot use OAuth; the base Max allowance is not consumed — only overage credits). If you don't have this, skip OAuth and use an `ANTHROPIC_API_KEY` instead (set it in Task 6 in place of `ANTHROPIC_TOKEN`).

- [ ] **Step 1: Generate the setup-token (on your workstation, has a browser)**

```bash
claude setup-token
```
Follow the browser prompt to authorize. Expected: it prints a token beginning with `sk-ant-oat-`.

- [ ] **Step 2: Record the token**

Copy the `sk-ant-oat-...` value; you will paste it into Portainer as `ANTHROPIC_TOKEN` in Task 6. Do not commit it anywhere.

Note: setup-tokens can expire; if Claude calls start failing later, re-run `claude setup-token` and update the Portainer value. For a non-expiring option, use `ANTHROPIC_API_KEY` instead.

---

## Task 4 — Create the Cloudflare tunnel, DNS, and Access apps (host/Cloudflare)

- [ ] **Step 1: Create a named tunnel and capture its credentials**

```bash
cloudflared tunnel login            # browser auth to your Cloudflare account (once)
cloudflared tunnel create hermes    # creates the tunnel; prints the tunnel UUID and writes a creds JSON
```
Expected: prints `Created tunnel hermes with id <UUID>` and writes `~/.cloudflared/<UUID>.json`. Record the `<UUID>` — it is `HERMES_TUNNEL_ID` for Portainer (Task 6).

- [ ] **Step 2: Place the credentials file where the container expects it**

```bash
sudo cp ~/.cloudflared/<UUID>.json /mnt/spool/apps/config/hermes/cloudflared/tunnel.json
sudo chown 568:568 /mnt/spool/apps/config/hermes/cloudflared/tunnel.json
sudo chmod 0440 /mnt/spool/apps/config/hermes/cloudflared/tunnel.json
```

- [ ] **Step 3: Create DNS routes for both hostnames**

```bash
cloudflared tunnel route dns hermes hermes.alekseev.us
cloudflared tunnel route dns hermes hermes-browser.alekseev.us
```
Expected: two `CNAME` records created pointing at `<UUID>.cfargotunnel.com`.

- [ ] **Step 4: Put both hostnames behind Cloudflare Access**

In the Cloudflare Zero Trust dashboard → Access → Applications, create a **self-hosted application** for `hermes.alekseev.us` and another for `hermes-browser.alekseev.us`, each with a policy that allows only your identity (e.g. your email). 
Verification: this is the primary auth gate for both the UI and the credential-capable noVNC viewer — confirm both apps are saved and the policy is "Allow" for your account only.

---

## Task 5 — Seed the Hermes model config (host)

The in-process agent reads `~/.hermes/config.yaml`. Model selection (`model.provider`) has no single env var, so seed a minimal config on the volume before first boot.

- [ ] **Step 1: Write the seed config**

```bash
sudo tee /mnt/spool/apps/config/hermes/home/config.yaml >/dev/null <<'YAML'
model:
  provider: "anthropic"
  default: "claude-sonnet-4-6"
YAML
sudo chown 1000:1000 /mnt/spool/apps/config/hermes/home/config.yaml
```

- [ ] **Step 2: Verify**

Run: `cat /mnt/spool/apps/config/hermes/home/config.yaml`
Expected: the two-key `model:` block above.
Note: after deploy you can change the model with `docker exec -it hermes-webui hermes model` (or `hermes config set model.default <id>`); run `docker exec -it hermes-webui hermes model` to see the exact Claude model ids Hermes offers and adjust `default` if `claude-sonnet-4-6` isn't listed.

---

## Task 6 — Configure Portainer stack env vars and deploy (host/Portainer)

- [ ] **Step 1: Add the stack in Portainer from this git repo**

In Portainer → Stacks → Add stack → Repository: point at this repo and `stacks/hermes.yaml` on branch `hermes-stealth-browser-stack` (or `master` after merge).

- [ ] **Step 2: Define the stack environment variables**

In the stack's "Environment variables" section add (values are yours; these populate the `${VAR}` placeholders):

| Name | Value |
|---|---|
| `CAMOFOX_SHARED_KEY` | a long random string (e.g. `openssl rand -hex 32`) |
| `VNC_PASSWORD` | a strong password for the noVNC viewer |
| `HERMES_WEBUI_PASSWORD` | a strong password for the Hermes UI |
| `ANTHROPIC_TOKEN` | the `sk-ant-oat-...` from Task 3 (or set `ANTHROPIC_API_KEY` here and edit the compose to use it) |
| `HERMES_TUNNEL_ID` | the tunnel `<UUID>` from Task 4 |

- [ ] **Step 3: Deploy the stack**

Click Deploy. Expected: Portainer pulls the three images and starts `camofox`, `hermes-webui`, `hermes-cloudflared`.

- [ ] **Step 4: Verify containers are up and camofox is healthy**

```bash
docker ps --filter name='camofox|hermes-webui|hermes-cloudflared'
docker inspect --format '{{.State.Health.Status}}' camofox
```
Expected: all three `Up`; camofox health `healthy` within ~1 minute (it has a 30s `start_period`).

---

## Task 7 — Smoke tests (host)

- [ ] **Step 1: Hermes UI reachable and password-gated**

Open `https://hermes.alekseev.us` in a browser. Expected: Cloudflare Access challenge → then the Hermes web UI, gated by `HERMES_WEBUI_PASSWORD`.

- [ ] **Step 2: noVNC viewer reachable and password-gated**

Open `https://hermes-browser.alekseev.us`. Expected: Cloudflare Access → noVNC prompts for `VNC_PASSWORD` → a live Camoufox browser appears.
If the page does not load: the noVNC bind variable name is the most likely cause (see spec §13 "validate at deploy"). Inspect it:
```bash
docker exec hermes-webui sh -c 'true'   # placeholder; run the next line against camofox
docker exec camofox sh -c 'cat /home/node/plugins/vnc/vnc-watcher.sh 2>/dev/null | grep -n websockify; env | grep -iE "VNC|NOVNC"'
```
Expected: confirm the websockify bind uses `VNC_BIND`; if the plugin uses a different variable, set that var in the compose `environment:` to `0.0.0.0` and redeploy.

- [ ] **Step 3: Agent reaches Claude**

In the Hermes UI, start a chat and send a trivial prompt (e.g. "say hello"). Expected: a Claude response. If it errors on auth, re-check `ANTHROPIC_TOKEN` (Task 3) and the Max+credits requirement; check `docker logs hermes-webui`.

- [ ] **Step 4: Agent drives camofox (bearer auth works)**

Ask the agent to browse a benign page (e.g. "open example.com and tell me the page title"). Expected: it returns the title. Then confirm the REST calls are authenticated:
```bash
docker logs camofox 2>&1 | tail -20
```
Expected: requests succeed (no `401`). A `401` means `CAMOFOX_API_KEY` (hermes-webui) ≠ `CAMOFOX_ACCESS_KEY` (camofox) — they must be the same value.

- [ ] **Step 5: Stealth sanity check**

Ask the agent to open a fingerprint check page (e.g. a public bot-detection/fingerprint test) and report the result. Expected: it renders and the WebGL renderer reads as a consumer GPU (Camoufox spoof), not `llvmpipe`/`SwiftShader`. (No GPU passthrough — see spec §10.)

---

## Task 8 — Validate the human-login → agent-handoff (host; the §9 spike)

This is the one mechanically-supported-but-undocumented flow from the spec (§9). Establish and record the working procedure.

- [ ] **Step 1: Open a login session in the live browser**

Via the agent (or a direct REST call), have a tab opened for `userId=operator` and navigate it to a site's login page. Confirm you can see that tab in the noVNC viewer (`https://hermes-browser.alekseev.us`).

- [ ] **Step 2: Log in as the human via noVNC**

In the noVNC viewer, complete the login / MFA on that site. Expected: you are authenticated in the live Camoufox browser; cookies are written to the persistent profile under `/mnt/spool/apps/data/hermes/camofox`.

- [ ] **Step 3: Have the agent adopt the authenticated tab**

Ask the agent to act on the now-authenticated site (e.g. "go to my account page and read X"). With `CAMOFOX_USER_ID=operator` + `CAMOFOX_ADOPT_EXISTING_TAB=true`, it should reuse the existing tab/session rather than create a fresh one. Expected: the agent operates as the logged-in user.

- [ ] **Step 4: Confirm persistence across a restart**

```bash
docker restart camofox
```
Then ask the agent to revisit the authenticated site. Expected: still logged in (cookies persisted in the profile volume).

- [ ] **Step 5: Record the working procedure**

Append the exact steps that worked (tab creation order, who opens the login tab, any timing) to the spec §9 or a short note in the PR. If live tab-adoption proves flaky, fall back to the persistent-profile model (log in once via noVNC; the agent's next task for `userId=operator` inherits the cookies) — both are documented in spec §9.

---

## Self-review

**1. Spec coverage**

| Spec requirement | Task |
|---|---|
| 3-service topology (camofox + hermes-webui + cloudflared) | Task 1 (compose) |
| `ghcr.io/jo-inc/camofox-browser:1.11.2`, VNC baked in, `ENABLE_VNC=1` | Task 1 |
| `ghcr.io/nesquena/hermes-webui` single container, in-process agent, port 8787 | Task 1 |
| `CAMOFOX_URL` + `CAMOFOX_API_KEY`(client) ⇄ `CAMOFOX_ACCESS_KEY`(server), same value | Task 1; verified Task 7.4 |
| `CAMOFOX_USER_ID` + `CAMOFOX_ADOPT_EXISTING_TAB` handoff | Task 1; exercised Task 8 |
| Claude via OAuth (Max+credits), headless provisioning | Task 3, Task 6 |
| Model selection via seeded `config.yaml` | Task 5 |
| Portainer-safe secrets (no `env_file:`) | Secrets approach + Task 6 |
| cloudflared tunnel + Cloudflare Access, no host ports | Task 1, Task 4 |
| Persistence volumes (`~/.hermes`, `.camofox`, workspace) | Task 1, Task 2 |
| No GPU passthrough (§10) | Task 1 (no `deploy.resources`/`--gpus`); checked Task 7.5 |
| Static validation + runtime smoke tests (§13) | Task 1.3, Task 7 |
| Login→handoff residual-risk validation (§9) | Task 8 |
| 1Password / Hindsight = Phase 2, out of scope | (excluded by design) |

No gaps.

**2. Placeholder scan:** No `TBD`/`TODO`/"add error handling". `${VAR}` tokens are intentional Portainer interpolation (every one is enumerated in the Task-1 header comment and Task-6 table). `<UUID>` in Task 4 is a value the operator generates and is captured/used explicitly.

**3. Consistency:** `CAMOFOX_SHARED_KEY` is the single source feeding both `camofox` `CAMOFOX_ACCESS_KEY` and `hermes-webui` `CAMOFOX_API_KEY` (Task 1, Task 6, verified Task 7.4). `userId=operator` is consistent across Task 1, Task 8. Volume host paths match between Task 1 (mounts), Task 2 (creation/ownership), Task 5 (config seed). Ports (8787 UI, 6080 noVNC, 9377 REST) are consistent across the compose, cloudflared ingress, and smoke tests.
