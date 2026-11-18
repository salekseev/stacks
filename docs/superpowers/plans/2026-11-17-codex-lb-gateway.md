# Shared ChatGPT/Codex Subscription Gateway (codex-lb) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run codex-lb on silverstone as a pooled, per-key-authenticated OpenAI-compatible front for several ChatGPT/Codex subscriptions, then cut hindsight's primary LLM over to it.

**Architecture:** New `stacks/codex-lb.yaml` (codex-lb + its own cloudflared) on the external `shared-services` network, with the dashboard behind Cloudflare Access and codex-lb trusting the Access identity header only from a dedicated `/29`. Hindsight's primary chain member changes from the native `openai-codex` provider to the `openai` provider pointed at `http://codex-lb:2455/v1`. vLLM member 1 is unchanged. No code is involved: Compose changes, host-side setup, and dashboard configuration.

**Tech Stack:** Docker Compose (compose-spec), Portainer git-backed stacks, `ghcr.io/soju06/codex-lb:1.24.0`, `cloudflare/cloudflared:2026.11.1`, Cloudflare Zero Trust Access, TrueNAS SCALE 26 ZFS, `ghcr.io/vectorize-io/hindsight:1.2.1-slim`.

**Spec:** `docs/superpowers/specs/2026-11-17-codex-lb-gateway-design.md`

**Working branches:**
- Phase A (gateway): `worktree-llm-gateway`, worktree at `.claude/worktrees/llm-gateway`. It already holds the spec commit `aefc4c0`.
- Phase B (hindsight cutover): `feat/hindsight-codex-lb`, branched from `master` after the Phase A PR merges.

Two PRs are needed because Portainer deploys from `master`: the gateway must be running and have minted hindsight's key before hindsight can point at it.

---

## Environment notes for the implementer

- **Host:** `silverstone.local` (TrueNAS SCALE `26.0.0-BETA.3`). Your ssh user is `salekseev`. It has passwordless `sudo` but is **not** in the `docker` group, so every docker command needs `sudo docker ...`.
- **Ownership:** the `apps` user/group is uid/gid **568**. Stack containers run as `568:568`.
- **Deployment:** Portainer (`ix-portainer-portainer-1`) deploys git-backed stacks from `master`. Creating a new Portainer stack is a UI step for the user.
- **Local validation:** only the Compose v2 plugin exists locally, so `./scripts/validate-stack.sh` fails with `docker-compose: command not found`. Use `docker compose -f stacks/<name>.yaml config >/dev/null` as the equivalent check (same precedent as the 2026-08-23 hindsight plan).
- **Do not run the codex-lb image on the workstation.** Running it locally was refused during planning. Every runtime check happens on silverstone.
- **`[USER]` steps** need a browser, a Cloudflare login or an interactive secret. Hand them to the user, and suggest the `! <command>` prefix for anything that must run in their shell.
- **Docker address pool on silverstone:** `172.17.0.0/12` in `/24`s, allocated so far as `172.16.0.0/24`–`172.16.18.0/24`. `shared-services` is `172.16.14.0/24`. The daemon enables IPv6 on every new bridge by default (`default-network-opts`). `codex-lb-edge` uses `172.31.255.248/29`, the top of the pool, far from where sequential allocation is, and the daemon will not allocate a network overlapping it.
- **Secrets hygiene:** never `cat` key files or `.env` secrets into the transcript. To check them, print key names only (`sed 's/=.*//'`) or lengths.

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `stacks/codex-lb.yaml` | Create | codex-lb service, its cloudflared, `codex-lb-edge` network, cloudflared ingress config |
| `stacks/hindsight.yaml` | Modify (Phase B) | primary LLM → codex-lb; drop `CODEX_HOME` and the `/codex` mount |
| `docs/superpowers/plans/2026-11-17-codex-lb-gateway.md` | Create | this plan |

Host only, never in git:

| Path | Holds |
|---|---|
| `/mnt/spool/apps/data/codex-lb/` | SQLite DB (dataset exists) |
| `/mnt/spool/apps/config/codex-lb/codex-lb/` | `encryption.key`, auto-created 0600 by codex-lb on first start |
| `/mnt/spool/apps/config/codex-lb/cloudflared/tunnel.json` | tunnel credentials |
| `/mnt/spool/apps/config/hindsight/env` | gains `HINDSIGHT_API_LLM_API_KEY` (Phase B) |

---

# Phase A — gateway

## Task 1: Create the per-container subdirectories on the config dataset

Both ZFS datasets were created on 2026-11-17 (spec §5.2). This task only adds the two subdirectories, so each container mounts just its own.

**Files:** host only.

- [ ] **Step 1: Create the subdirectories**

```bash
ssh silverstone.local 'set -e; for d in codex-lb cloudflared; do sudo install -d -o 568 -g 568 -m 0770 /mnt/spool/apps/config/codex-lb/$d; done; ls -ln /mnt/spool/apps/config/codex-lb /mnt/spool/apps/data/codex-lb'
```
Expected: `codex-lb` and `cloudflared` listed, both `drwxrwx--- 568 568`. The data dataset is empty and owned `568 568`.

- [ ] **Step 2: Confirm both are datasets, not plain directories**

```bash
ssh silverstone.local 'zfs list -H -o name,mountpoint spool/apps/config/codex-lb spool/apps/data/codex-lb'
```
Expected: two lines, mounted at `/mnt/spool/apps/config/codex-lb` and `/mnt/spool/apps/data/codex-lb`.

---

## Task 2: Create the Cloudflare tunnel and DNS route `[USER]`

The workstation has no `cloudflared`, so it runs as a one-off container on silverstone. `tunnel login` writes `cert.pem`, an **account-wide** Cloudflare credential. It lives only in a temporary setup directory and is shredded at the end of this task.

**Files:** host only → `/mnt/spool/apps/config/codex-lb/cloudflared/tunnel.json`.

- [ ] **Step 1: Make a temporary setup directory**

```bash
ssh silverstone.local 'sudo install -d -o 568 -g 568 -m 0700 /mnt/spool/apps/config/codex-lb/cloudflared/.setup'
```

- [ ] **Step 2: Log in to Cloudflare `[USER]`**

Run this in your own shell (it is interactive and prints a URL to open in a browser):
```bash
! ssh -t silverstone.local 'sudo docker run --rm -it --user 568:568 -e HOME=/work -v /mnt/spool/apps/config/codex-lb/cloudflared/.setup:/work cloudflare/cloudflared:2026.11.1 tunnel login'
```
Open the printed URL, then pick the `alekseev.us` zone.
Expected: `You have successfully logged in.` and `/work/.cloudflared/cert.pem` written.

- [ ] **Step 3: Create the tunnel, writing credentials straight to their final name**

```bash
ssh silverstone.local 'sudo docker run --rm --user 568:568 -e HOME=/work -v /mnt/spool/apps/config/codex-lb/cloudflared/.setup:/work cloudflare/cloudflared:2026.11.1 tunnel create --credentials-file /work/tunnel.json codex-lb'
```
Expected: `Created tunnel codex-lb with id <UUID>`. **Record the UUID**, Task 4 needs it.

- [ ] **Step 4: Route DNS**

```bash
ssh silverstone.local 'sudo docker run --rm --user 568:568 -e HOME=/work -v /mnt/spool/apps/config/codex-lb/cloudflared/.setup:/work cloudflare/cloudflared:2026.11.1 tunnel route dns codex-lb codex-lb.alekseev.us'
```
Expected: `Added CNAME codex-lb.alekseev.us which will route to this tunnel`.

- [ ] **Step 5: Move the credentials into place and destroy the login cert**

```bash
ssh silverstone.local 'set -e; D=/mnt/spool/apps/config/codex-lb/cloudflared; sudo mv $D/.setup/tunnel.json $D/tunnel.json; sudo chown 568:568 $D/tunnel.json; sudo chmod 0440 $D/tunnel.json; sudo shred -u $D/.setup/.cloudflared/cert.pem; sudo rm -rf $D/.setup; ls -ln $D'
```
Expected: only `tunnel.json`, `-r--r----- 568 568`, about 175 bytes. No `.setup`.

---

## Task 3: Create the Cloudflare Access application `[USER]`

**Files:** none (Cloudflare Zero Trust dashboard).

- [ ] **Step 1: Create the app `[USER]`**

In Zero Trust → Access → Applications → Add → **Self-hosted**:
- Name `codex-lb`, domain `codex-lb.alekseev.us`.
- One policy, **Allow**, include only your own email.
- Session duration: whatever you use for `hermes`.

- [ ] **Step 2: Record the Application Audience (AUD) tag `[USER]`**

App → Overview → **Application Audience (AUD) Tag**, a 64-char hex string. **Record it**, Task 4 needs it. The team name is `alekseev`, same as hermes.

---

## Task 4: Write `stacks/codex-lb.yaml`

**Files:**
- Create: `stacks/codex-lb.yaml`

- [ ] **Step 1: Write the file**

Substitute the two values recorded earlier: `<TUNNEL_UUID>` from Task 2 Step 3, and `<AUD_TAG>` from Task 3 Step 2. They are the only substitutions. Neither is a secret: hermes and hindsight inline theirs in this public repo too.

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Shared ChatGPT/Codex subscription pool (codex-lb).
# See docs/superpowers/specs/2026-11-17-codex-lb-gateway-design.md
#
# Consumers on the external shared-services network call
#   http://codex-lb:2455/v1   (OpenAI-compatible; Bearer = that stack's own codex-lb API key)
# codex-lb sends the Codex originator upstream, which gpt-5.6-luna requires
# (openai/codex#31967 — the reason LiteLLM's chatgpt/ provider was dropped).
#
# Host state (ZFS datasets, apps 568:568 — back up BOTH together; the DB is
# useless without the key):
#   /mnt/spool/apps/data/codex-lb                 -> SQLite DB (CODEX_LB_DATA_DIR default)
#   /mnt/spool/apps/config/codex-lb/codex-lb/     -> encryption.key (auto-created 0600 on first start)
#   /mnt/spool/apps/config/codex-lb/cloudflared/  -> tunnel.json (tunnel credentials)
# Nothing published to host. SSO identity (the Cf-Access header) is honoured only
# from cloudflared, which validates the Access JWT. Port 2455 is also reachable
# from shared-services; there the dashboard offers only the break-glass local
# login (local sign-in policy `break_glass_only`, TOTP-enrolled admin, set in the
# dashboard after bootstrap). Upstream accounts are added via device-code OAuth,
# so the 1455 OAuth callback port is never exposed.

services:

  codex-lb:
    image: ghcr.io/soju06/codex-lb:1.24.0
    container_name: codex-lb
    hostname: codex-lb
    user: "568:568"
    environment:
      # Key kept off the data dataset: a copy of the DB alone decrypts nothing.
      CODEX_LB_ENCRYPTION_KEY_FILE: /etc/codex-lb/encryption.key
      # Default sends an anonymous snapshot to a third-party collector at start
      # and every 24 h. Applies until a decision is saved in the dashboard.
      CODEX_LB_TELEMETRY_ENABLED: "false"
      # Dashboard SSO = Cloudflare Access identity header, trusted ONLY from
      # codex-lb-edge (cloudflared's net). A container on shared-services that
      # forges the header is not a trusted proxy. Proxy routes (/v1/*,
      # /backend-api/codex/*) are unaffected: they require a per-stack API key.
      CODEX_LB_DASHBOARD_AUTH_MODE: trusted_header
      CODEX_LB_DASHBOARD_AUTH_PROXY_HEADER: Cf-Access-Authenticated-User-Email
      CODEX_LB_FIREWALL_TRUST_PROXY_HEADERS: "true"
      CODEX_LB_FIREWALL_TRUSTED_PROXY_CIDRS: 172.31.255.248/29
    volumes:
      - /mnt/spool/apps/data/codex-lb:/var/lib/codex-lb
      - /mnt/spool/apps/config/codex-lb/codex-lb:/etc/codex-lb
    expose:
      - "2455"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:2455/health/ready')"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    restart: unless-stopped
    networks:
      - shared-services
      - codex-lb-edge

  cloudflared:
    image: cloudflare/cloudflared:2026.11.1
    container_name: codex-lb-cloudflared
    hostname: codex-lb-cloudflared
    command: --config /etc/cloudflared/config.yml tunnel run
    user: "568:568"
    configs:
      - source: cloudflared
        target: /etc/cloudflared/config.yml
        uid: "568"
        gid: "568"
        mode: 0440
    volumes:
      - /mnt/spool/apps/config/codex-lb/cloudflared:/etc/cloudflared/creds
    depends_on:
      codex-lb:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - codex-lb-edge

configs:
  cloudflared:
    content: |
      tunnel: <TUNNEL_UUID>
      credentials-file: /etc/cloudflared/creds/tunnel.json
      ingress:
        # Origin-side Cloudflare Access JWT validation (same as hermes): cloudflared
        # verifies Cf-Access-Jwt-Assertion against team JWKS + this app's audTag
        # before proxying, so the identity header codex-lb trusts is always genuine.
        - hostname: codex-lb.alekseev.us
          service: http://codex-lb:2455
          originRequest:
            access:
              required: true
              teamName: alekseev
              audTag:
                - <AUD_TAG>
        - service: http_status:404

networks:
  # Created out-of-band on the host: `docker network create shared-services`.
  # Consumers (hindsight, yandex-station processor) reach codex-lb by name here.
  shared-services:
    external: true
  # cloudflared <-> codex-lb only. Fixed IPv4 /29 because it IS the trusted-proxy
  # CIDR above. IPv6 off: the daemon enables v6 on new bridges by default, and a
  # v6 hop would not match the v4 CIDR (dashboard would fail closed).
  # The /29 sits at the top of the daemon pool (172.17.0.0/12, allocated
  # sequentially from 172.16.0.0/24); the daemon refuses to allocate a network
  # overlapping it while it exists, and ranges outside the pool risk colliding
  # with routes this host cannot see.
  codex-lb-edge:
    enable_ipv6: false
    ipam:
      config:
        - subnet: 172.31.255.248/29
```

- [ ] **Step 2: Confirm no placeholder survived**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
grep -nE '<TUNNEL_UUID>|<AUD_TAG>' stacks/codex-lb.yaml || echo "no placeholders"
grep -nE '^      tunnel: [0-9a-f-]{36}$' stacks/codex-lb.yaml && grep -nE '^                - [0-9a-f]{64}$' stacks/codex-lb.yaml
```
Expected: `no placeholders`, then one matching line for the UUID and one for the AUD tag.

- [ ] **Step 3: Validate**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
docker compose -f stacks/codex-lb.yaml config >/dev/null && echo "Validation successful"
```
Expected: `Validation successful`.

- [ ] **Step 4: Assert the security-relevant values rendered as intended**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
docker compose -f stacks/codex-lb.yaml config | grep -nE 'CODEX_LB_|subnet|enable_ipv6|published|ports:'
```
Expected: the six `CODEX_LB_*` values exactly as written, `subnet: 172.31.255.248/29`, `enable_ipv6: false`, and **no** `ports:` or `published` lines.

- [ ] **Step 5: Commit**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
git add stacks/codex-lb.yaml
git commit -m "feat(codex-lb): add shared ChatGPT/Codex subscription gateway stack

codex-lb pools ChatGPT/Codex subscriptions behind one OpenAI-compatible
endpoint on shared-services with per-stack API keys. Dashboard via its
own cloudflared behind Cloudflare Access (origin-side JWT check); the
Access identity header is trusted only from the codex-lb-edge /29.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 5: Commit the plan and open the Phase A PR

**Files:**
- Create: `docs/superpowers/plans/2026-11-17-codex-lb-gateway.md` (this file)

- [ ] **Step 1: Confirm the spec and plan are committed**

They were committed during planning.
```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
git status --short docs/ && git log --oneline -- docs/superpowers/plans/2026-11-17-codex-lb-gateway.md | head -1
```
Expected: no `docs/` changes pending, and one `docs(codex-lb): implementation plan ...` commit. If you edited the plan while executing it, commit those edits here.

- [ ] **Step 2: Push and open the PR**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
git push -u origin worktree-llm-gateway
gh pr create --base master --title "feat(codex-lb): shared ChatGPT/Codex subscription gateway" --body "$(cat <<'BODY'
## Summary

New `stacks/codex-lb.yaml`: codex-lb pools several ChatGPT/Codex subscriptions behind one OpenAI-compatible endpoint (`http://codex-lb:2455/v1` on `shared-services`), with a separate API key per consuming stack.

- Chosen over apache/casbin-gateway (workstation-oriented, no published image) and CLIProxyAPI (multi-vendor scope, weaker client auth). codex-lb sends the Codex originator, which `gpt-5.6-luna` requires (openai/codex#31967).
- No host ports. Dashboard at `codex-lb.alekseev.us` through its own cloudflared, behind Cloudflare Access with origin-side JWT validation. codex-lb trusts the Access identity header only from the `codex-lb-edge` /29.
- State is on ZFS datasets `spool/apps/{data,config}/codex-lb`. The encryption key is kept apart from the DB.
- Telemetry is off.

Hindsight's cutover follows in a separate PR, once this stack is deployed and has minted hindsight's key.

Design: `docs/superpowers/specs/2026-11-17-codex-lb-gateway-design.md`
Plan: `docs/superpowers/plans/2026-11-17-codex-lb-gateway.md`

## Accepted risk

ChatGPT plans are licensed for individual use. Pooling automated traffic across subscriptions can get accounts flagged.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
Expected: PR URL printed.

---

## Task 6: Deploy and verify the container boots as 568 `[USER]` for the Portainer step

- [ ] **Step 1: Merge and create the Portainer stack `[USER]`**

Merge the Phase A PR. In Portainer → Stacks → Add stack → **Repository**:
- Repository: this repo, reference `refs/heads/master`.
- Compose path: `stacks/codex-lb.yaml`.
- Stack name: `codex-lb`.
- No environment variables needed.
- Enable the same auto-update/GitOps setting the other stacks use.

Deploy.

- [ ] **Step 2: Containers are up and healthy**

```bash
ssh silverstone.local 'sudo docker ps --filter name=codex-lb --format "{{.Names}}\t{{.Status}}"'
```
Expected: `codex-lb   Up ... (healthy)` and `codex-lb-cloudflared   Up ...`.

**If `codex-lb` is restarting or unhealthy**, read the logs:
```bash
ssh silverstone.local 'sudo docker logs --tail 50 codex-lb 2>&1 | grep -viE "token"'
```
A `PermissionError` on a path outside `/var/lib/codex-lb` and `/etc/codex-lb` means the image can't run as 568 (spec §5.1). In that case:
1. Change `user: "568:568"` to `user: "1000:1000"` (the image's `app` uid; confirm it with `sudo docker run --rm --entrypoint id ghcr.io/soju06/codex-lb:1.24.0`).
2. `sudo chown -R 1000:1000` both codex-lb directories (`data/codex-lb`, `config/codex-lb/codex-lb`).
3. Add a YAML comment saying why, commit as `fix(codex-lb): run as image uid`, and redeploy.

- [ ] **Step 3: State landed on the right datasets with the right owner**

```bash
ssh silverstone.local 'sudo ls -ln /mnt/spool/apps/data/codex-lb /mnt/spool/apps/config/codex-lb/codex-lb'
```
Expected: an SQLite DB file in `data/codex-lb`, and `encryption.key` mode `-rw-------` in `config/codex-lb/codex-lb`, all owned by the container uid. **No** `encryption.key` in `data/codex-lb`.

- [ ] **Step 4: Edge network is IPv4-only on the expected subnet**

```bash
ssh silverstone.local 'sudo docker network inspect codex-lb_codex-lb-edge -f "{{.EnableIPv6}} {{range .IPAM.Config}}{{.Subnet}} {{end}}"; sudo docker inspect codex-lb-cloudflared -f "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{.GlobalIPv6Address}}{{end}}"'
```
Expected: `false 172.31.255.248/29`, and cloudflared's address inside `172.31.255.249`–`.254` with an empty IPv6.
If `EnableIPv6` is `true`, the daemon default won. Add `driver_opts: {com.docker.network.enable_ipv6: "false"}` under `codex-lb-edge`, commit, and redeploy.

- [ ] **Step 5: Tunnel connected**

```bash
ssh silverstone.local 'sudo docker logs --tail 20 codex-lb-cloudflared 2>&1 | grep -E "Registered tunnel connection|ERR"'
```
Expected: `Registered tunnel connection` lines (usually 4), and no `ERR`.

- [ ] **Step 6: Telemetry not sent**

```bash
ssh silverstone.local 'sudo docker logs codex-lb 2>&1 | grep -i telemetry | tail -5'
```
Expected: nothing, or a line saying telemetry is disabled. A line about a successful send to `telemetry.tokmaxxing.com` means the env var was ignored. Stop and fix that before going further.

---

## Task 7: Bootstrap the dashboard `[USER]`

In `trusted_header` mode, the first identity that arrives through Cloudflare Access becomes **Admin** by default (spec §5.3). This task locks that down.

- [ ] **Step 1: Get the bootstrap token**

```bash
ssh silverstone.local 'sudo docker logs codex-lb 2>&1 | grep -A1 "bootstrap token"'
```
Expected: the token on the line below the header. Hand it to the user directly. Do not paste it anywhere else.

- [ ] **Step 2: First login `[USER]`**

Open `https://codex-lb.alekseev.us`. Cloudflare Access prompts for login, then the codex-lb dashboard loads, signed in as your Access identity (Admin).

- [ ] **Step 3: Set the break-glass local admin password `[USER]`**

From the setup screen, create the local `admin` account with the bootstrap token and a strong password (store it in 1Password), and enrol TOTP on it. Then in Settings → Organisation settings → local sign-in:
1. Designate `admin` as the **break-glass** account.
2. Set the policy to **`break_glass_only`**.

The API answers `409 break_glass_requires_totp` if TOTP isn't enrolled yet. This matters because port 2455 is reachable from every `shared-services` container. Under this policy the password form admits only the TOTP-enrolled emergency account, at `/login?local=1`.

Verify `[USER]`: in a private browser window (through Cloudflare Access), `/login` shows no password form, and `/login?local=1` shows it. The policy is enforced server-side by codex-lb, and the dashboard only reflects it. Lockout recovery: `sudo docker exec -it codex-lb codex-lb admin reset-password admin`.

Exposure window, deliberate: between Task 6 and this step the policy is still `enabled`, but no account has a password yet. Setting the first one from anywhere but localhost requires the bootstrap token, which is printed only in the container logs (Step 1). Keep it out of anywhere but this step.

- [ ] **Step 4: Refuse unknown identities `[USER]`**

Settings → Organisation settings → **Reverse proxy**: set the default role for unknown identities to **none / refuse**. From now on, only identities you add explicitly get in, even if the Access policy is widened later.

- [ ] **Step 5: Turn on proxy API-key auth `[USER]`**

Settings → **API Key Auth** → enable.

- [ ] **Step 6: Routing `[USER]`**

Settings → Routing:
- Strategy **Capacity weighted**.
- **Sticky threads** on.
- Conversation archive stays **off**.
- If a telemetry consent prompt appears, decline it.

---

## Task 8: Verify the trust boundaries

**Files:** none.

- [ ] **Step 1: The proxy rejects unauthenticated calls from shared-services**

```bash
ssh silverstone.local 'sudo docker run --rm --network shared-services curlimages/curl:8.17.0 -s -o /dev/null -w "%{http_code}\n" http://codex-lb:2455/v1/models'
```
Expected: `401`.

- [ ] **Step 2: A forged identity header from shared-services is not trusted**

```bash
ssh silverstone.local 'sudo docker run --rm --network shared-services curlimages/curl:8.17.0 -s -o /dev/null -w "%{http_code}\n" -H "Cf-Access-Authenticated-User-Email: attacker@example.com" -H "Remote-User: admin" http://codex-lb:2455/api/accounts'
```
Expected: `401` or `403`. **Not** `200`. `/api/accounts` is a real dashboard route (`app/modules/accounts/api.py`, prefix `/api/accounts`, gated by `validate_dashboard_session`), so a `404` means the request didn't reach codex-lb as expected, and the test is inconclusive rather than passed. A `200` means the trusted-proxy CIDR doesn't restrict the header. In that case stop, set `CODEX_LB_DASHBOARD_AUTH_MODE: standard`, redeploy, and investigate before continuing.

- [ ] **Step 3: The edge path without Cloudflare Access is refused**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://codex-lb.alekseev.us/api/accounts
```
Expected: `302` or `403` from Cloudflare Access (redirect to login), never codex-lb JSON.

---

## Task 9: Add the subscription accounts `[USER]`

Each account gets a fresh login, which gives it its own refresh-token chain (spec §6). **Do not** import or copy any `auth.json`, including hindsight's `/mnt/spool/apps/config/hindsight/codex/auth.json`.

- [ ] **Step 1: Add each account via device code `[USER]`**

Accounts → Add account → **device code**. Open the shown URL in a browser signed in to that ChatGPT account and enter the code. Repeat for every subscription, including the account hindsight uses today.

- [ ] **Step 2: Confirm accounts are active and models are synced**

Accounts page: every account `Active`, with 5h/weekly quota shown. The model catalogue includes `gpt-5.6-luna`.

---

## Task 10: Mint the hindsight key and prove luna through the gateway

- [ ] **Step 1: Create the key `[USER]`**

API Keys → Create:
- Name `hindsight`.
- Model restriction: `gpt-5.6-luna` only.
- No expiry. Leave token caps empty for now.

Copy the key. It is shown once.

- [ ] **Step 2: Write it into hindsight's secret file `[USER]`**

The running hindsight container is unaffected: the file is only read at container start. Phase B is merged right after this task, so the window where the file holds a key the config doesn't yet use is short.
```bash
! ssh -t silverstone.local 'read -rs -p "hindsight codex-lb key: " K; echo; sudo sh -c "printf \"HINDSIGHT_API_LLM_API_KEY=%s\n\" \"$K\" >> /mnt/spool/apps/config/hindsight/env"; unset K; sudo sed "s/=.*//" /mnt/spool/apps/config/hindsight/env'
```
Expected: the key-name list now ends with `HINDSIGHT_API_LLM_API_KEY`, and that name appears exactly once.

- [ ] **Step 3: Gate check — luna answers through codex-lb with the hindsight key**

This repeats the spec §2 originator gate for the new transport.

The probe runs inside the running `hindsight` container, which is already on `shared-services` and has `curl`. The compose secret is a bind mount of the host file, and the `>>` append in Step 2 kept the same inode, so the new line is visible at `/run/secrets/hindsight_env` without a restart. Sourcing it in this one-off shell doesn't touch the hindsight process.
```bash
ssh silverstone.local 'sudo docker exec -i hindsight sh -s' <<'SH'
set -a; . /run/secrets/hindsight_env; set +a
curl -sS http://codex-lb:2455/v1/chat/completions \
  -H "Authorization: Bearer $HINDSIGHT_API_LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.6-luna","reasoning_effort":"medium","messages":[{"role":"user","content":"Reply with the single word OK."}]}'
SH
```
If `$HINDSIGHT_API_LLM_API_KEY` comes up empty (the request returns `401`), the secret mount didn't reflect the append. Run the same probe from a one-off `curlimages/curl:8.17.0` container on `shared-services` instead, passing the key with `-e` after sourcing the host file under `sudo sh -c`.
Expected: a chat-completion JSON whose message content is `OK`.
**Failure signature:** `Model not found gpt-5.6-luna...` means the originator or the account cohort is wrong. Stop: this is the spec §2 constraint failing, and it is a design problem, not a config tweak.

- [ ] **Step 4: Model allowlist holds**

Same heredoc as Step 3, with `"model":"gpt-5.5"`.
Expected: an error refusing the model for this key, not a completion.

- [ ] **Step 5: Reasoning effort reached upstream `[USER]`**

Dashboard → Request logs → the Step 3 request shows reasoning effort `medium`.

---

# Phase B — hindsight cutover

## Task 11: Rewrite hindsight's primary LLM

**Files:**
- Modify: `stacks/hindsight.yaml:36-64` (the `/codex` volume block, and the primary LLM block through `CODEX_HOME`)

- [ ] **Step 1: Branch from the merged master**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
git fetch origin && git switch -c feat/hindsight-codex-lb origin/master
grep -c codex-lb stacks/codex-lb.yaml
```
Expected: a count above 0. This proves Phase A is on master.

- [ ] **Step 2: Remove the `/codex` volume**

Delete these lines (the `volumes:` key holds only this mount, so it goes too):
```yaml
    volumes:
      # Dedicated Codex auth home (CODEX_HOME=/codex). NOT :ro — the provider
      # writes the rotated refresh token back, and a read-only mount breaks
      # refresh on the first rotation.
      - /mnt/spool/apps/config/hindsight/codex:/codex
```

- [ ] **Step 3: Replace the primary block**

Replace everything from `      # API: default LLM (recall, reflect, consolidation) via Hindsight's native` through `      CODEX_HOME: /codex` (inclusive) with:
```yaml
      # API: default LLM (recall, reflect, consolidation) via Hindsight's native
      # multi-LLM failover chain.
      #
      # Primary: the shared ChatGPT/Codex subscription pool behind codex-lb
      # (stacks/codex-lb.yaml), reached by name over shared-services. codex-lb
      # sends the Codex originator upstream, which gpt-5.6-luna requires
      # (openai/codex#31967 — why LiteLLM's chatgpt/ provider is not used) and
      # owns every account's token refresh.
      # HINDSIGHT_API_LLM_API_KEY = this stack's codex-lb key. It lives in
      # /run/secrets/hindsight_env: the ONE LLM var allowed there. Routing and
      # tuning stay here as the single source of truth.
      HINDSIGHT_API_LLM_PROVIDER: openai
      HINDSIGHT_API_LLM_BASE_URL: http://codex-lb:2455/v1
      HINDSIGHT_API_LLM_MODEL: gpt-5.6-luna
```
The `# Member 1:` block and everything after it stay byte-identical.

- [ ] **Step 4: Validate and assert the rendered chain**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
docker compose -f stacks/hindsight.yaml config >/dev/null && echo "Validation successful"
docker compose -f stacks/hindsight.yaml config | grep -E 'HINDSIGHT_API_LLM_(PROVIDER|BASE_URL|MODEL|1_PROVIDER|1_MODEL|STRATEGY|MAX_RETRIES)|REASONING_EFFORT|CODEX_HOME|/codex'
```
Expected: `Validation successful`, then:
- `HINDSIGHT_API_LLM_PROVIDER: openai`
- `HINDSIGHT_API_LLM_BASE_URL: http://codex-lb:2455/v1`
- `HINDSIGHT_API_LLM_MODEL: gpt-5.6-luna`
- `HINDSIGHT_API_LLM_1_PROVIDER: openai`, `HINDSIGHT_API_LLM_1_MODEL: gemma-4-12b`
- the strategy, `MAX_RETRIES: "1"`, and the four `REASONING_EFFORT` lines

and **no** `CODEX_HOME` or `/codex` line.

- [ ] **Step 5: The diff touches only the intended lines**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
git diff --stat && git diff stacks/hindsight.yaml | grep -E '^[-+][^-+]' | grep -vE 'codex|Codex|CODEX|LLM_(PROVIDER|BASE_URL|MODEL)|^[-+] +#|volumes:'
```
Expected: `1 file changed`, and the second command prints nothing. Every changed line is a comment, the volume, or one of the primary vars.

- [ ] **Step 6: Commit, push, open PR**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks/.claude/worktrees/llm-gateway
git commit -am "feat(hindsight)!: route the primary LLM through the codex-lb pool

Primary moves from the native openai-codex provider (one account, its own
CODEX_HOME) to the openai provider on http://codex-lb:2455/v1, so hindsight
draws on the pooled subscriptions. vLLM member 1 and all tuning unchanged.
The /codex mount goes; the host directory stays for rollback.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/hindsight-codex-lb
gh pr create --base master --title "feat(hindsight)!: primary LLM via the codex-lb pool" --body "$(cat <<'BODY'
## Summary

- Hindsight's primary LLM moves from the native `openai-codex` provider (a single account with its own `CODEX_HOME`) to `openai` → `http://codex-lb:2455/v1`, `gpt-5.6-luna`, using its own codex-lb key.
- vLLM `gemma-4-12b` stays as failover member 1. Retries, timeout, concurrency and reasoning-effort pins are unchanged.
- The `/codex` mount is removed. `/mnt/spool/apps/config/hindsight/codex/` stays on the host for rollback.

## Deploy prerequisite (done)

`HINDSIGHT_API_LLM_API_KEY` is in `/mnt/spool/apps/config/hindsight/env`, and luna was verified through codex-lb with that key.

Design: `docs/superpowers/specs/2026-11-17-codex-lb-gateway-design.md` §7.1

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
Expected: PR URL printed.

---

## Task 12: Deploy and verify hindsight

- [ ] **Step 1: Merge and let Portainer redeploy `hindsight` `[USER]`**

- [ ] **Step 2: The env landed, the key is present and nothing in the secret overrides routing**

```bash
ssh silverstone.local 'sudo docker exec hindsight sh -c "set -a; . /run/secrets/hindsight_env; set +a; env" | grep -E "^(HINDSIGHT_API_LLM_|CODEX_HOME)" | sed "s/\(API_KEY=\).*/\1<redacted>/" | sort'
```
Expected:
- `HINDSIGHT_API_LLM_PROVIDER=openai`
- `HINDSIGHT_API_LLM_BASE_URL=http://codex-lb:2455/v1`
- `HINDSIGHT_API_LLM_MODEL=gpt-5.6-luna`
- `HINDSIGHT_API_LLM_API_KEY=<redacted>`
- the `_1_*` members, strategy, retries, timeout and concurrency as in YAML

and no `CODEX_HOME`.

- [ ] **Step 3: Health**

```bash
ssh silverstone.local 'sudo docker exec hindsight sh -c "curl -fsS http://localhost:8888/api/health"'
```
Expected: healthy JSON.

- [ ] **Step 4: Primary serves**

Tail the logs in one shell:
```bash
ssh silverstone.local 'timeout 180 sudo docker logs -f --since 1m hindsight 2>&1 | grep -iE "codex-lb|luna|gemma|192.168.1.147|failover|401|429|model not found"'
```
Then drive a real reflect (for example `hindsight_reflect` from Claude Code against this repo's bank).
Expected: the call succeeds. codex-lb's dashboard request log shows a `hindsight`-key request on `gpt-5.6-luna` with reasoning effort `high` (the reflect pin). No advance to `192.168.1.147`.
**Failure signature:** `401` means the key is missing or wrong in the secret. Every call going to `192.168.1.147` means the primary is failing, so read the codex-lb request log for the reason.

- [ ] **Step 5: Failover still fires**

```bash
ssh silverstone.local 'sudo docker stop codex-lb'
```
Drive one reflect. Expected: it still succeeds, and the logs show the advance to `192.168.1.147` / `gemma-4-12b`.
```bash
ssh silverstone.local 'sudo docker start codex-lb && sleep 40 && sudo docker ps --filter name=codex-lb --format "{{.Names}}\t{{.Status}}"'
```
Expected: `codex-lb ... (healthy)` again. Drive one more reflect and confirm it is back on the primary.

- [ ] **Step 6: Pooling observed `[USER]`, after a day of normal traffic**

Dashboard → Request logs filtered to the `hindsight` key: requests served by more than one account (soft-sticky routing moves sessions as quota shifts). One account taking everything while others have headroom means the routing strategy didn't save. Recheck Task 7 Step 6.

---

## Rollback

- **Hindsight only:** `git revert` the Phase B commit and let Portainer redeploy. `/mnt/spool/apps/config/hindsight/codex/auth.json` was never touched. If its refresh token aged out while unused, run `codex login` into that directory. Remove the `HINDSIGHT_API_LLM_API_KEY` line from `/mnt/spool/apps/config/hindsight/env`: a stray key is harmless to `openai-codex` in theory, but the 2026-08-23 rule keeps the secret free of LLM vars that the YAML doesn't use.
- **Gateway:** stop or delete the `codex-lb` Portainer stack (revert hindsight first if it already depends on it). The datasets can be kept. Destroying them (`zfs destroy spool/apps/{data,config}/codex-lb`) discards every account login and every key, so only do it deliberately. Delete the `codex-lb` tunnel, its CNAME and the Access app in Cloudflare if the gateway is abandoned.

## Follow-ups (not in this plan)

- PR #169: mint a `yandex` key, restricted to that stack's model. Add `shared-services` (external) to `processor` and set its `OPENAI_BASE_URL` default to `http://codex-lb:2455/v1`.
- A TrueNAS periodic snapshot task covering `spool/apps/config/codex-lb` and `spool/apps/data/codex-lb` together.
- Consider per-key token caps on `hindsight` once a week of usage shows its normal volume.
