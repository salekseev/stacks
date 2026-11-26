# Google AI Pro Subscription Gateway (CLIProxyAPI + Oh My CPA) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run CLIProxyAPI on silverstone as a pool of two test Google AI Pro accounts (Antigravity OAuth) on `shared-services`, with Oh My CPA as the single dashboard behind Cloudflare Access, and run a one-week low-volume ban-risk test.

**Architecture:** New `stacks/cliproxyapi.yaml` with three services: `cliproxyapi` (CPA, on `shared-services` + `cpa-internal`), `omc` (on `cpa-internal` + `cpa-edge`) and `cloudflared` (on `cpa-edge`). CPA's `config.yaml` and secret env files live on ZFS datasets, never in git. No code is involved: Compose, host setup and dashboard steps.

**Tech Stack:** Docker Compose (compose-spec), Portainer git-backed stacks, `eceasy/cli-proxy-api:v8.1.7`, `wiziscool/oh-my-cpa:v0.4.14`, `cloudflare/cloudflared:2026.11.2`, Cloudflare Zero Trust Access, TrueNAS SCALE ZFS.

**Spec:** `docs/superpowers/specs/2026-11-26-cliproxyapi-gateway-design.md`

**Branch:** `feat/cliproxyapi-gateway` (holds the spec commit `d19d79f`). One PR: no consumer changes in this phase.

---

## Environment notes for the implementer

- **Host:** `silverstone.local` (TrueNAS SCALE). ssh user `salekseev` has passwordless `sudo` but is **not** in the `docker` group: every docker command is `sudo docker ...`.
- **Ownership:** `apps` is uid/gid **568**. Stack containers run as `568:568`.
- **Deployment:** Portainer deploys git-backed stacks from `master`. Creating a Portainer stack is a UI step for the user.
- **Local validation:** only the Compose v2 plugin exists locally, so `./scripts/validate-stack.sh` fails with `docker-compose: command not found`. Use `docker compose -f stacks/cliproxyapi.yaml config >/dev/null` instead. The `secrets.*.file` paths do not exist locally; `config` does not check them.
- **Do not run these images on the workstation.** Every runtime check happens on silverstone.
- **`[USER]` steps** need a browser, a Cloudflare login, a Google login or an interactive secret. Hand them to the user and suggest the `! <command>` prefix for anything that must run in their shell.
- **Docker address pool:** `172.17.0.0/12` in `/24`s, allocated sequentially from `172.16.0.0/24` (as of 2026-11-17, up to `172.16.18.0/24`). `codex-lb-edge` holds `172.31.255.248/29`. This plan takes `172.31.255.240/29`, checked free in Task 1.
- **Secrets hygiene:** never `cat` env files, `config.yaml` or `auths/*.json` into the transcript. Print key names (`sed 's/=.*//'`), lengths or hashes only.
- **Ban-risk discipline:** no load tests, no loops, no warmup. Every request in this plan is one deliberate call.

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `stacks/cliproxyapi.yaml` | Create | CPA, OMC, cloudflared, three networks, two secrets, cloudflared ingress |
| `docs/superpowers/plans/2026-11-26-cliproxyapi-gateway.md` | Create | this plan |
| `docs/superpowers/specs/2026-11-26-cliproxyapi-gateway-design.md` | Modify (Task 13) | as-built section |

Renovate needs no change: its `docker-compose` manager already matches `stacks/*.yaml`, and both new images use plain semver tags.

Host only, never in git:

| Path | Holds |
|---|---|
| `/mnt/spool/apps/config/cliproxyapi/cliproxyapi/config.yaml` | CPA config incl. the test client key (OMC rewrites it) |
| `/mnt/spool/apps/config/cliproxyapi/cliproxyapi/auths/` | Google OAuth credentials, 0700 |
| `/mnt/spool/apps/config/cliproxyapi/cliproxyapi.env` | `MANAGEMENT_PASSWORD`, 0400 |
| `/mnt/spool/apps/config/cliproxyapi/omc.env` | `OMCPA_CPA_MANAGEMENT_KEY`, `OMCPA_MASTER_KEY`, 0400 |
| `/mnt/spool/apps/config/cliproxyapi/cloudflared/tunnel.json` | tunnel credentials |
| `/mnt/spool/apps/data/cliproxyapi/cliproxyapi/` | `kv.db`, `logs/` |
| `/mnt/spool/apps/data/cliproxyapi/omc/` | OMC SQLite |

Two env files rather than the spec's one (spec §4.5 is updated in Task 13): CPA never sees `OMCPA_MASTER_KEY`.

---

## Task 1: Check the edge subnet is free

**Files:** none.

- [ ] **Step 1: List every subnet the daemon knows**

```bash
ssh silverstone.local 'sudo docker network inspect $(sudo docker network ls -q) -f "{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}" | sort -k2'
```
Expected: `codex-lb_codex-lb-edge 172.31.255.248/29` and nothing in `172.31.255.240`–`172.31.255.247`. If something overlaps, pick the next free /29 below (`172.31.255.232/29`) and use it everywhere this plan says `172.31.255.240/29`.

- [ ] **Step 2: Confirm `shared-services` exists**

```bash
ssh silverstone.local 'sudo docker network inspect shared-services -f "{{.Name}} {{.Internal}}"'
```
Expected: `shared-services false`.

---

## Task 2: Create the datasets and directories

Same dataset options as `spool/apps/{config,data}/codex-lb` (spec §4.4): `share_type: APPS`, `atime: OFF`.

**Files:** host only.

- [ ] **Step 1: Create both datasets through the TrueNAS middleware**

```bash
ssh silverstone.local 'set -e; for ds in spool/apps/config/cliproxyapi spool/apps/data/cliproxyapi; do sudo midclt call pool.dataset.create "{\"name\": \"$ds\", \"share_type\": \"APPS\", \"atime\": \"OFF\"}" >/dev/null; done; zfs list -H -o name,mountpoint,atime spool/apps/config/cliproxyapi spool/apps/data/cliproxyapi'
```
Expected: two lines, mounted at `/mnt/spool/apps/config/cliproxyapi` and `/mnt/spool/apps/data/cliproxyapi`, atime `off`.
If `midclt` rejects the call, create them in the TrueNAS UI `[USER]` (Datasets → Add → preset **Apps**, atime off), then re-run the `zfs list`.

- [ ] **Step 2: Own the roots and create the per-container directories**

```bash
ssh silverstone.local 'set -e
C=/mnt/spool/apps/config/cliproxyapi; D=/mnt/spool/apps/data/cliproxyapi
sudo chown 568:568 $C $D; sudo chmod 0770 $C $D
sudo install -d -o 568 -g 568 -m 0770 $C/cliproxyapi $C/cloudflared $D/cliproxyapi $D/cliproxyapi/logs $D/omc
sudo install -d -o 568 -g 568 -m 0700 $C/cliproxyapi/auths $D/omc
sudo ls -lnR $C $D'
```
Expected: every directory `568 568`; `auths` and `omc` are `drwx------`, the rest `drwxrwx---`.

---

## Task 3: Write the secret env files and `config.yaml`

Three random values are generated **on silverstone** and never printed: the management key (shared by CPA and OMC), OMC's master key, and the test client key.

**Files:** host only.

- [ ] **Step 1: Write both env files**

```bash
ssh silverstone.local 'set -e; umask 077
C=/mnt/spool/apps/config/cliproxyapi
MK=$(openssl rand -hex 32); MASTER=$(openssl rand -hex 32)
printf "MANAGEMENT_PASSWORD=%s\n" "$MK" | sudo tee $C/cliproxyapi.env >/dev/null
printf "OMCPA_CPA_MANAGEMENT_KEY=%s\nOMCPA_MASTER_KEY=%s\n" "$MK" "$MASTER" | sudo tee $C/omc.env >/dev/null
unset MK MASTER
sudo chown 568:568 $C/cliproxyapi.env $C/omc.env; sudo chmod 0400 $C/cliproxyapi.env $C/omc.env
sudo ls -ln $C/*.env; for f in $C/*.env; do echo "$f:"; sudo sed "s/=.*//" $f; done'
```
Expected: both files `-r-------- 568 568`; key names `MANAGEMENT_PASSWORD`, then `OMCPA_CPA_MANAGEMENT_KEY` and `OMCPA_MASTER_KEY`.

- [ ] **Step 2: Confirm the two management keys match without printing them**

```bash
ssh silverstone.local 'C=/mnt/spool/apps/config/cliproxyapi; a=$(sudo sed -n "s/^MANAGEMENT_PASSWORD=//p" $C/cliproxyapi.env | sha256sum); b=$(sudo sed -n "s/^OMCPA_CPA_MANAGEMENT_KEY=//p" $C/omc.env | sha256sum); [ "$a" = "$b" ] && echo match || echo MISMATCH'
```
Expected: `match`.

- [ ] **Step 3: Write `config.yaml` with a fresh test client key**

```bash
ssh silverstone.local 'set -e; umask 077
F=/mnt/spool/apps/config/cliproxyapi/cliproxyapi/config.yaml
sudo tee $F >/dev/null <<'"'"'YAML'"'"'
config-version: 8

server:
  host: ""
  port: 8317
  discovery:
    enabled: false
  kv-store:
    path: /var/lib/cliproxyapi/kv.db

management:
  # OMC reaches CPA from another container.
  allow-remote: true
  # Empty on purpose: MANAGEMENT_PASSWORD (Docker secret) supplies the key.
  secret-key: ""
  # OMC is the UI; no runtime panel download from GitHub.
  disable-control-panel: true
  disable-auto-update-panel: true

access:
  api-keys:
    - "__TEST_CLIENT_KEY__"

routing:
  strategy: "round-robin"

oauth:
  auth-dir: /etc/cliproxyapi/auths

observability:
  logs:
    debug: false
    logging-to-file: false
    request-log: false
  usage:
    # Feeds the OMC usage collector.
    usage-statistics-enabled: true
YAML
KEY=$(openssl rand -hex 24); sudo sed -i "s/__TEST_CLIENT_KEY__/cpa-test-$KEY/" $F; unset KEY
sudo chown 568:568 $F; sudo chmod 0600 $F
sudo grep -c "__TEST_CLIENT_KEY__" $F || true; sudo ls -ln $F'
```
Expected: `0` (placeholder replaced), file `-rw------- 568 568`.

- [ ] **Step 4: Hand the test client key to the user `[USER]`**

The user stores it in 1Password as "cliproxyapi test client key". Run in the user's shell so it never enters the transcript:
```bash
! ssh silverstone.local 'sudo sed -n "s/^    - \"\(cpa-test-[0-9a-f]*\)\"$/\1/p" /mnt/spool/apps/config/cliproxyapi/cliproxyapi/config.yaml'
```

---

## Task 4: Create the Cloudflare tunnel and DNS route `[USER]`

`tunnel login` writes `cert.pem`, an **account-wide** Cloudflare credential. It lives only in a temporary directory and is shredded at the end.

**Files:** host only → `/mnt/spool/apps/config/cliproxyapi/cloudflared/tunnel.json`.

- [ ] **Step 1: Temporary setup directory**

```bash
ssh silverstone.local 'sudo install -d -o 568 -g 568 -m 0700 /mnt/spool/apps/config/cliproxyapi/cloudflared/.setup'
```

- [ ] **Step 2: Log in to Cloudflare `[USER]`**

```bash
! ssh -t silverstone.local 'sudo docker run --rm -it --user 568:568 -e HOME=/work -v /mnt/spool/apps/config/cliproxyapi/cloudflared/.setup:/work cloudflare/cloudflared:2026.11.2 tunnel login'
```
Open the printed URL and pick the `alekseev.us` zone. Expected: `You have successfully logged in.`

- [ ] **Step 3: Create the tunnel**

```bash
ssh silverstone.local 'sudo docker run --rm --user 568:568 -e HOME=/work -v /mnt/spool/apps/config/cliproxyapi/cloudflared/.setup:/work cloudflare/cloudflared:2026.11.2 tunnel create --credentials-file /work/tunnel.json cliproxyapi'
```
Expected: `Created tunnel cliproxyapi with id <UUID>`. **Record the UUID** for Task 6.

- [ ] **Step 4: Route DNS**

```bash
ssh silverstone.local 'sudo docker run --rm --user 568:568 -e HOME=/work -v /mnt/spool/apps/config/cliproxyapi/cloudflared/.setup:/work cloudflare/cloudflared:2026.11.2 tunnel route dns cliproxyapi cpa.alekseev.us'
```
Expected: `Added CNAME cpa.alekseev.us which will route to this tunnel`.

- [ ] **Step 5: Move credentials into place, destroy the login cert**

```bash
ssh silverstone.local 'set -e; D=/mnt/spool/apps/config/cliproxyapi/cloudflared; sudo mv $D/.setup/tunnel.json $D/tunnel.json; sudo chown 568:568 $D/tunnel.json; sudo chmod 0440 $D/tunnel.json; sudo shred -u $D/.setup/.cloudflared/cert.pem; sudo rm -rf $D/.setup; sudo ls -ln $D'
```
Expected: only `tunnel.json`, `-r--r----- 568 568`.

---

## Task 5: Create the Cloudflare Access application `[USER]`

- [ ] **Step 1: Create the app `[USER]`**

Zero Trust → Access → Applications → Add → **Self-hosted**: name `cliproxyapi`, domain `cpa.alekseev.us`, one **Allow** policy including only your email, session duration as for `codex-lb`.

- [ ] **Step 2: Record the AUD tag `[USER]`**

App → Overview → **Application Audience (AUD) Tag** (64 hex chars). **Record it** for Task 6. Team name is `alekseev`.

---

## Task 6: Write `stacks/cliproxyapi.yaml`

**Files:**
- Create: `stacks/cliproxyapi.yaml`

- [ ] **Step 1: Write the file**

Substitute `<TUNNEL_UUID>` (Task 4 Step 3) and `<AUD_TAG>` (Task 5 Step 2); they are not secrets (codex-lb and hermes inline theirs). If Task 1 picked a different /29, change both `172.31.255.240/29` occurrences.

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Google AI Pro subscription pool: CLIProxyAPI (CPA) + Oh My CPA (OMC) dashboard.
# See docs/superpowers/specs/2026-11-26-cliproxyapi-gateway-design.md
#
# TEST PHASE: two non-primary Google accounts via Antigravity OAuth. No consumer
# stack is wired to this yet. Accepted risk: Google suspends Antigravity access
# (403 ToS) for accounts used through third-party tools.
#
# Consumers (later) on the external shared-services network call
#   http://cliproxyapi:8317/v1   (OpenAI-compatible; Bearer = a key in access.api-keys)
#
# Host state (ZFS datasets, apps 568:568 — back up BOTH together; OMC's DB is
# unreadable without OMCPA_MASTER_KEY, and auths/ is the only copy of the logins):
#   /mnt/spool/apps/config/cliproxyapi/cliproxyapi/  -> config.yaml (OMC edits it), auths/ (Google refresh tokens, plaintext, 0700)
#   /mnt/spool/apps/config/cliproxyapi/cliproxyapi.env  0400 -> MANAGEMENT_PASSWORD
#   /mnt/spool/apps/config/cliproxyapi/omc.env          0400 -> OMCPA_CPA_MANAGEMENT_KEY (same value), OMCPA_MASTER_KEY
#   /mnt/spool/apps/config/cliproxyapi/cloudflared/  -> tunnel.json
#   /mnt/spool/apps/data/cliproxyapi/cliproxyapi/    -> kv.db, logs/
#   /mnt/spool/apps/data/cliproxyapi/omc/            -> OMC SQLite (encrypted with the master key)
#
# Nothing published to host; CPA's OAuth callback ports are never published.
# OMC is reachable only through cloudflared (Cloudflare Access, origin JWT check),
# then its own login (= the CPA management key). OMC is NOT on shared-services.
# Accepted exposure: CPA serves /v1 and /v8/management on one port, and OMC needs
# management.allow-remote, so the management API is reachable from shared-services,
# guarded by the management key only.
# Not deployed: oh-my-cpa-updater (mounts the Docker socket). Renovate updates.
# Off by policy in OMC's UI: quota warmup, Agent, plugins.

services:

  cliproxyapi:
    image: eceasy/cli-proxy-api:v8.1.7
    container_name: cliproxyapi
    hostname: cliproxyapi
    user: "568:568"
    # env_file: is resolved at compose-parse time, which fails inside Portainer.
    # A Docker secret defers the path to the daemon (same as hindsight and nod).
    # The image's own CMD is ./CLIProxyAPI with the config in its workdir; the
    # config lives on the config dataset instead, because OMC writes it.
    entrypoint:
      - sh
      - -c
      - set -a; . /run/secrets/cliproxyapi_env; set +a; exec /CLIProxyAPI/CLIProxyAPI -config /etc/cliproxyapi/config.yaml
    secrets:
      - cliproxyapi_env
    environment:
      # The image bakes Asia/Shanghai.
      TZ: America/New_York
    volumes:
      - /mnt/spool/apps/config/cliproxyapi/cliproxyapi:/etc/cliproxyapi
      - /mnt/spool/apps/data/cliproxyapi/cliproxyapi:/var/lib/cliproxyapi
      - /mnt/spool/apps/data/cliproxyapi/cliproxyapi/logs:/CLIProxyAPI/logs
    expose:
      - "8317"
    healthcheck:
      # Debian image without curl or wget: speak HTTP through bash's /dev/tcp.
      # /healthz needs no key (same probe as OMC's compose.full.yml).
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8317 && printf 'GET /healthz HTTP/1.0\\r\\n\\r\\n' >&3 && head -n 1 <&3 | grep -q ' 200 '"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    restart: unless-stopped
    networks:
      - shared-services
      - cpa-internal

  omc:
    image: wiziscool/oh-my-cpa:v0.4.14
    container_name: cliproxyapi-omc
    hostname: cliproxyapi-omc
    # Image default is 10001; it writes only OMCPA_DATA_DIR.
    user: "568:568"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    entrypoint:
      - sh
      - -c
      - set -a; . /run/secrets/omc_env; set +a; exec /usr/local/bin/oh-my-cpa
    secrets:
      - omc_env
    environment:
      TZ: America/New_York
      OMCPA_DATA_DIR: /data
      OMCPA_CPA_BASE_URL: http://cliproxyapi:8317
      # https:// marks the session cookie Secure.
      OMCPA_PUBLIC_URL: https://cpa.alekseev.us
      # cloudflared's network; forwarded client IPs feed login throttling.
      OMCPA_TRUSTED_PROXY_CIDRS: 172.31.255.240/29
      # No updater is deployed; no background release/plugin checks.
      OMCPA_UPDATER_ENABLED: "false"
      OMCPA_UPDATE_CHECK_ENABLED: "false"
      OMCPA_UPDATE_CHECK_ON_PAGE_LOAD: "false"
    volumes:
      - /mnt/spool/apps/data/cliproxyapi/omc:/data
    healthcheck:
      # The image's own probe: /api/healthz reports ok, or degraded when CPA is down.
      test: ["CMD", "sh", "/usr/local/bin/omc-healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 180s
    depends_on:
      cliproxyapi:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - cpa-internal
      - cpa-edge

  cloudflared:
    image: cloudflare/cloudflared:2026.11.2
    container_name: cliproxyapi-cloudflared
    hostname: cliproxyapi-cloudflared
    command: --config /etc/cloudflared/config.yml tunnel run
    user: "568:568"
    configs:
      - source: cloudflared
        target: /etc/cloudflared/config.yml
        uid: "568"
        gid: "568"
        mode: 0440
    volumes:
      - /mnt/spool/apps/config/cliproxyapi/cloudflared:/etc/cloudflared/creds
    depends_on:
      omc:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - cpa-edge

configs:
  cloudflared:
    content: |
      tunnel: <TUNNEL_UUID>
      credentials-file: /etc/cloudflared/creds/tunnel.json
      ingress:
        # Origin-side Cloudflare Access JWT validation (same as codex-lb and hermes):
        # cloudflared verifies Cf-Access-Jwt-Assertion against the team JWKS and
        # this app's audTag before proxying.
        - hostname: cpa.alekseev.us
          service: http://omc:8080
          originRequest:
            access:
              required: true
              teamName: alekseev
              audTag:
                - <AUD_TAG>
        - service: http_status:404

secrets:
  cliproxyapi_env:
    file: /mnt/spool/apps/config/cliproxyapi/cliproxyapi.env
  omc_env:
    file: /mnt/spool/apps/config/cliproxyapi/omc.env

networks:
  # Created out-of-band on the host: `docker network create shared-services`.
  shared-services:
    external: true
  # CPA <-> OMC only, no egress.
  cpa-internal:
    internal: true
    enable_ipv6: false
  # cloudflared <-> OMC. Fixed IPv4 /29 because it IS OMC's trusted-proxy CIDR.
  # IPv6 off: the daemon enables v6 on new bridges by default. Sits directly below
  # codex-lb-edge (172.31.255.248/29) at the top of the daemon pool.
  cpa-edge:
    enable_ipv6: false
    ipam:
      config:
        - subnet: 172.31.255.240/29
```

- [ ] **Step 2: No placeholder survived**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
grep -nE '<TUNNEL_UUID>|<AUD_TAG>' stacks/cliproxyapi.yaml || echo "no placeholders"
grep -cE '^      tunnel: [0-9a-f-]{36}$|^                - [0-9a-f]{64}$' stacks/cliproxyapi.yaml
```
Expected: `no placeholders`, then `2`.

- [ ] **Step 3: Validate**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
docker compose -f stacks/cliproxyapi.yaml config >/dev/null && echo "Validation successful"
```
Expected: `Validation successful`.

- [ ] **Step 4: Assert the security-relevant values rendered as intended**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
docker compose -f stacks/cliproxyapi.yaml config | grep -nE 'published|ports:|docker.sock|internal:|enable_ipv6|subnet|OMCPA_(UPDATER|UPDATE_CHECK|TRUSTED|PUBLIC)|read_only|user:'
```
Expected: **no** `ports:`, `published` or `docker.sock` lines; `internal: true` once; `enable_ipv6: false` twice; `subnet: 172.31.255.240/29`; the five `OMCPA_*` values as written; `read_only: true`; `user: 568:568` three times.

- [ ] **Step 5: Network membership is exactly as designed**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
docker compose -f stacks/cliproxyapi.yaml config --format json | python3 -c 'import json,sys; s=json.load(sys.stdin)["services"]; [print(n, sorted(v["networks"])) for n,v in sorted(s.items())]'
```
Expected:
```
cliproxyapi ['cpa-internal', 'shared-services']
cloudflared ['cpa-edge']
omc ['cpa-edge', 'cpa-internal']
```

- [ ] **Step 6: Commit**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add stacks/cliproxyapi.yaml
git commit -m "feat(cliproxyapi): add Google AI Pro subscription gateway stack

CLIProxyAPI pools Google AI Pro accounts via Antigravity OAuth on
shared-services; Oh My CPA is the single dashboard, reachable only
through its own cloudflared behind Cloudflare Access. No host ports,
no Docker-socket updater, CPA's runtime-downloaded panel disabled.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 7: Commit the plan and open the PR

**Files:**
- Create: `docs/superpowers/plans/2026-11-26-cliproxyapi-gateway.md` (this file)

- [ ] **Step 1: Confirm spec and plan are committed**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git status --short docs/ && git log --oneline master..HEAD
```
Expected: no pending `docs/` changes; commits for the spec, the plan and the stack.

- [ ] **Step 2: Push and open the PR**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git push -u origin feat/cliproxyapi-gateway
gh pr create --base master --title "feat(cliproxyapi): Google AI Pro subscription gateway (test phase)" --body "$(cat <<'BODY'
## Summary

New `stacks/cliproxyapi.yaml`: CLIProxyAPI pools Google AI Pro accounts through Antigravity OAuth behind an OpenAI-compatible endpoint (`http://cliproxyapi:8317/v1` on `shared-services`). Oh My CPA is the single management and usage dashboard at `cpa.alekseev.us`.

- Test phase: two non-primary Google accounts, low volume, about a week. No consumer stack is wired.
- No host ports; CPA's OAuth callback ports are never published.
- Oh My CPA is reachable only through its own cloudflared behind Cloudflare Access (origin-side JWT check); it is not on `shared-services`.
- Not deployed: Oh My CPA's updater (Docker socket). CPA's runtime-downloaded panel is disabled. Warmup, Agent and plugins stay off.
- Secrets and `config.yaml` live on ZFS datasets `spool/apps/{config,data}/cliproxyapi`, never in git or Portainer env.

Design: `docs/superpowers/specs/2026-11-26-cliproxyapi-gateway-design.md`
Plan: `docs/superpowers/plans/2026-11-26-cliproxyapi-gateway.md`

## Accepted risk

Google has suspended Antigravity access (403 ToS) for accounts used through third-party tools. The test accounts are non-primary. The management API is reachable from `shared-services`, guarded only by its key.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
Expected: PR URL printed. CI's `ci` job passes (no image workflow is touched).

---

## Task 8: Deploy and verify the containers `[USER]` for the Portainer step

- [ ] **Step 1: Merge and create the Portainer stack `[USER]`**

Merge the PR. Portainer → Stacks → Add stack → **Repository**: this repo, `refs/heads/master`, compose path `stacks/cliproxyapi.yaml`, stack name `cliproxyapi`, no environment variables, same GitOps auto-update setting as the other stacks. Deploy.

- [ ] **Step 2: All three containers up and healthy**

```bash
ssh silverstone.local 'sudo docker ps --filter name=cliproxyapi --format "{{.Names}}\t{{.Status}}"'
```
Expected: `cliproxyapi` and `cliproxyapi-omc` `Up ... (healthy)`, `cliproxyapi-cloudflared` `Up`. OMC can take up to 3 minutes (`start_period`).

**If `cliproxyapi` restarts or is unhealthy:**
```bash
ssh silverstone.local 'sudo docker logs --tail 60 cliproxyapi 2>&1 | grep -viE "token|key|secret"'
```
A `permission denied` on a path under `/CLIProxyAPI` other than `logs/` means CPA writes into its workdir. Mount a writable directory there from the data dataset if it is one path; otherwise fall back (spec §4.1) to `user: "0:0"` with `cap_drop: [ALL]` and `security_opt: [no-new-privileges:true]`, `sudo chown -R 0:0` its two config/data directories, add a YAML comment saying why, commit as `fix(cliproxyapi): run CPA as root`, and redeploy.

**If `cliproxyapi-omc` restarts:** a permission error on `/data` means the image expects 10001. Change `user:` to `"10001:10001"`, `sudo chown -R 10001:10001 /mnt/spool/apps/data/cliproxyapi/omc` and `sudo chown 10001 /mnt/spool/apps/config/cliproxyapi/omc.env`, comment, commit as `fix(cliproxyapi): run OMC as image uid`, redeploy.

- [ ] **Step 3: Management routes came from the env secret, the panel is off**

```bash
ssh silverstone.local 'sudo docker logs cliproxyapi 2>&1 | grep -iE "management routes|control panel|management.html" | tail -5'
```
Expected: `management routes enabled via MANAGEMENT_PASSWORD`, and no line about downloading the control panel.

- [ ] **Step 4: State landed where intended**

```bash
ssh silverstone.local 'sudo ls -ln /mnt/spool/apps/data/cliproxyapi/cliproxyapi /mnt/spool/apps/data/cliproxyapi/omc /mnt/spool/apps/config/cliproxyapi/cliproxyapi'
```
Expected: `kv.db` in `data/cliproxyapi/cliproxyapi`; an `oh-my-cpa.db` in `data/cliproxyapi/omc`; `config.yaml` and `auths/` in the config dir. No `kv.db` under `auths/`.

- [ ] **Step 5: Edge network IPv4-only on the expected subnet; internal network has no egress**

```bash
ssh silverstone.local 'sudo docker network inspect cliproxyapi_cpa-edge cliproxyapi_cpa-internal -f "{{.Name}} internal={{.Internal}} v6={{.EnableIPv6}} {{range .IPAM.Config}}{{.Subnet}}{{end}}"'
```
Expected: `cliproxyapi_cpa-edge internal=false v6=false 172.31.255.240/29` and `cliproxyapi_cpa-internal internal=true v6=false ...`. If `v6=true`, add `driver_opts: {com.docker.network.enable_ipv6: "false"}` to that network, commit and redeploy.

- [ ] **Step 6: Reachability matches the design**

```bash
ssh silverstone.local 'probe(){ sudo docker run --rm --network "$1" curlimages/curl:8.17.0 -s -o /dev/null -m 5 -w "$1 -> $2: %{http_code}\n" "$2" || echo "$1 -> $2: unreachable"; }
probe shared-services http://cliproxyapi:8317/healthz
probe shared-services http://omc:8080/api/healthz
probe shared-services http://cliproxyapi-omc:8080/api/healthz
probe cliproxyapi_cpa-edge http://cliproxyapi:8317/healthz'
```
Expected: `shared-services -> http://cliproxyapi:8317/healthz: 200`; the other three `unreachable` (or `000`).

- [ ] **Step 7: Tunnel connected**

```bash
ssh silverstone.local 'sudo docker logs --tail 20 cliproxyapi-cloudflared 2>&1 | grep -E "Registered tunnel connection|ERR"'
```
Expected: `Registered tunnel connection` lines and no `ERR`.

---

## Task 9: First dashboard login and policy settings `[USER]`

- [ ] **Step 1: Log in `[USER]`**

Open `https://cpa.alekseev.us`: Cloudflare Access prompts first, then OMC's sign-in. The password is the management key; read it in your own shell and paste it into the browser:
```bash
! ssh silverstone.local 'sudo sed -n "s/^MANAGEMENT_PASSWORD=//p" /mnt/spool/apps/config/cliproxyapi/cliproxyapi.env'
```
Store it in 1Password as "cliproxyapi management key". Expected: OMC dashboard, CPA connected, version v8.1.7.

- [ ] **Step 2: Confirm the unauthenticated edge refuses `[USER]`**

In a private window, `https://cpa.alekseev.us` shows the Cloudflare Access login, not OMC.

- [ ] **Step 3: Policy settings `[USER]`**

- OAuth management → **Warmup settings**: no tasks. Leave empty.
- OMC Settings → Quota: automatic post-reset reads and scheduled sweeps may stay on (they are quota reads, not completions). If OMC labels any option as sending a model request, turn it off.
- Plugins: none installed; do not open the plugin store's install actions.
- `/agent`: do not select a model. Record whether OMC offers a switch to disable the Agent page (spec §4.3 *(verify)*).
- System Information: no update action offered (updater disabled).

- [ ] **Step 4: Settings did not rewrite the management key**

```bash
ssh silverstone.local 'sudo grep -nE "^\s*secret-key:|disable-control-panel|allow-remote|usage-statistics-enabled" /mnt/spool/apps/config/cliproxyapi/cliproxyapi/config.yaml'
```
Expected: `secret-key: ""` (or a hash, never a plaintext value you recognise), `disable-control-panel: true`, `allow-remote: true`, `usage-statistics-enabled: true`.

---

## Task 10: Add the two Google accounts `[USER]`

This resolves the main unknown (spec §6, §8): whether Antigravity OAuth completes without a published callback port.

- [ ] **Step 1: Start the login `[USER]`**

OMC → OAuth management → **Antigravity** → sign in. In the Google consent screen, use test account A (non-primary, AI Pro non-trial).

- [ ] **Step 2: Complete the callback `[USER]`**

After consent the browser is redirected to `http://localhost:51121/...` (or similar) and shows a connection error. Copy the **full URL from the address bar** and paste it into OMC's callback field. Expected: OMC shows the credential as active, with an email and quota windows.

**If OMC has no callback field or the paste fails:** stop, do not publish port 51121. Use the laptop route instead: on the laptop, run the same CPA image with an empty temp auth dir and `--antigravity-login -no-browser`, complete the login there, then copy the resulting JSON into `/mnt/spool/apps/config/cliproxyapi/cliproxyapi/auths/` (`568:568`, `0600`) with `scp` + `sudo install`, and delete the laptop copy. Record which route worked for Task 13.

- [ ] **Step 3: Repeat for account B `[USER]`**

- [ ] **Step 4: Credentials on disk**

```bash
ssh silverstone.local 'sudo ls -ln /mnt/spool/apps/config/cliproxyapi/cliproxyapi/auths/'
```
Expected: two JSON files, `568 568`, mode `0600` or stricter.

---

## Task 11: Smoke test from `shared-services`

Run in the user's shell so the client key never enters the transcript. Each command is one request.

- [ ] **Step 1: Models are listed `[USER]`**

```bash
! read -rs -p "client key: " K; echo; ssh silverstone.local "sudo docker run --rm --network shared-services curlimages/curl:8.17.0 -s -H 'Authorization: Bearer $K' http://cliproxyapi:8317/v1/models" | python3 -c 'import json,sys; print("\n".join(m["id"] for m in json.load(sys.stdin)["data"]))'; unset K
```
Expected: Antigravity models (Gemini and the Claude models AI Pro gets through Antigravity). Pick one Gemini model id for Step 2.

- [ ] **Step 2: One chat completion `[USER]`**

Replace `<MODEL>` with the id from Step 1.
```bash
! read -rs -p "client key: " K; echo; ssh silverstone.local "sudo docker run --rm --network shared-services curlimages/curl:8.17.0 -s -H 'Authorization: Bearer $K' -H 'Content-Type: application/json' -d '{\"model\":\"<MODEL>\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}]}' http://cliproxyapi:8317/v1/chat/completions"; unset K
```
Expected: a JSON completion whose message content contains `pong`.

- [ ] **Step 3: No key, no service**

```bash
ssh silverstone.local 'sudo docker run --rm --network shared-services curlimages/curl:8.17.0 -s -o /dev/null -w "%{http_code}\n" http://cliproxyapi:8317/v1/models'
```
Expected: `401`.

- [ ] **Step 4: OMC saw it `[USER]`**

OMC → requests: the Step 1–2 requests appear with account, model, tokens and latency. Credentials/quota view shows Antigravity quota for both accounts. Record whether Antigravity quota displays (spec risk from brainstorming).

---

## Task 12: One-week low-volume test `[USER]`

- [ ] **Step 1: Daily, for about 7 days `[USER]`**

A handful of interactive requests per day with the test key (for example from a coding tool on the laptop through an SSH tunnel, or Task 11 Step 2 with a real prompt). No scripts or loops.

- [ ] **Step 2: Daily check**

```bash
ssh silverstone.local 'sudo docker logs --since 24h cliproxyapi 2>&1 | grep -cE " 403 |PERMISSION_DENIED|ToS|terms of service"; sudo docker logs --since 24h cliproxyapi 2>&1 | grep -E " 403 |PERMISSION_DENIED" | sed -E "s/(Bearer|key|token)[^ ]*/\1=REDACTED/gI" | tail -5'
```
Expected: `0`. On any `403`: stop sending traffic on that credential, disable it in OMC, revoke the app in that Google account's security settings, and note the date. A second `403` ends the experiment (spec §6): stop the stack.

---

## Task 13: Record the result

**Files:**
- Modify: `docs/superpowers/specs/2026-11-26-cliproxyapi-gateway-design.md`

- [ ] **Step 1: Correct §4.5 for the two env files**

Replace the §4.5 bullet list's opening sentence and file path so it reads: two Docker-secret env files, `/mnt/spool/apps/config/cliproxyapi/cliproxyapi.env` (`MANAGEMENT_PASSWORD`) and `/mnt/spool/apps/config/cliproxyapi/omc.env` (`OMCPA_CPA_MANAGEMENT_KEY`, `OMCPA_MASTER_KEY`), so CPA never holds the master key. Update the §4.4 table's `env` entry the same way.

- [ ] **Step 2: Append `## 12. As-built (<date>)`**

Record, with evidence (command output, dates):
- which uid each container runs as, and any fallback taken in Task 8;
- the edge subnet used;
- which OAuth route worked in Task 10 (paste-callback or laptop);
- whether Antigravity quota shows in OMC; whether the Agent page can be disabled;
- the test outcome: days run, requests, any `403`;
- the decision: wire consumers, add accounts, or tear down (spec §9).

- [ ] **Step 3: Commit and open a PR**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git switch -c docs/cliproxyapi-as-built master
git add docs/superpowers/specs/2026-11-26-cliproxyapi-gateway-design.md
git commit -m "docs(cliproxyapi): as-built and test outcome

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin docs/cliproxyapi-as-built
gh pr create --base master --title "docs(cliproxyapi): as-built and test outcome" --body "Records the deployment deviations and the one-week Antigravity test result.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
Expected: PR URL printed.
