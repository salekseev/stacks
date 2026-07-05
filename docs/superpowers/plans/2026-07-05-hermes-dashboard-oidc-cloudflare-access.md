# Hermes Dashboard OIDC (Cloudflare Access) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the Hermes dashboard from HTTP basic-auth to its native `self_hosted` OIDC relying-party, authenticating against Cloudflare Access as a Generic OIDC SaaS IdP, in an OIDC-only topology (no edge Access on the dashboard host).

**Architecture:** One surgical edit to `stacks/hermes.yaml` — the `hermes-gateway` dashboard env block, the header `/opt/data/.env` secret manifest, and the `cloudflared` ingress for `hermes-dashboard.alekseev.us` — validated with `validate-stack.sh`. All runtime work (create the Cloudflare Access SaaS-OIDC app, provision the client secret, remove the edge Access app, deploy, smoke-test) is a host-side operator runbook on `silverstone`; the assistant cannot reach the host or Cloudflare.

**Tech Stack:** Docker Compose, `nousresearch/hermes-agent:v2026.7.1` (gateway dashboard, `self_hosted` OIDC provider), Cloudflare Access (Generic OIDC SaaS app), `cloudflare/cloudflared`, Portainer stack env, `/opt/data/.env` on-disk secrets.

**Spec:** `docs/superpowers/specs/2026-07-03-hermes-dashboard-oidc-cloudflare-access-design.md`

**Execution status (2026-07-05):** Task 1 **GO** (image `v2026.7.1` ships the `self_hosted` provider); Task 2 done (SaaS-OIDC app created); Task 3 **done — adapted to `.env`-only placement** (operator provisioned `issuer`/`client_id`/`secret` in `/opt/data/.env`; compose sets `HERMES_DASHBOARD_PUBLIC_URL` inline and does not hardcode the app-id), committed `9aa56f3`, `validate-stack.sh` passed. **Remaining:** Task 4 (remove the now-inert `HERMES_DASHBOARD_BASIC_AUTH_*` from `.env`), Task 5 (deploy + verify OIDC login), Task 6 (remove the dashboard host from the edge Access app).

---

## File Structure

- **Modify (3 surgical edits):** `stacks/hermes.yaml` — (a) header `/opt/data/.env` secret manifest, (b) `hermes-gateway` dashboard env block, (c) `cloudflared` ingress entry for `hermes-dashboard.alekseev.us`.
- **No tests/scripts created** — repo verification is `./scripts/validate-stack.sh hermes` (static compose parse); runtime verification is the host-side smoke tests (Tasks 5–7). This matches the established pattern for the hermes stack plans (config change + validate + operator smoke-test), so strict code-TDD does not apply.

**Split of responsibility:** **Task 3 is repo-side, assistant-executable** on `master`. **Tasks 1, 2, 4, 5, 6, 7** (and optional 8-repo) are a **host-side operator runbook** on `silverstone` via Portainer/Cloudflare — NOT assistant-executable; written as action+verify checklists. **Task 3 depends on the `APP_ID` + client secret produced by Task 2** (`<APP_ID>` is a real value the operator hands back, like the hardcoded tunnel UUID — not a plan placeholder).

---

## Task 1 (host/operator): Pre-flight gate — confirm the pinned image ships the `self_hosted` OIDC provider

STOP/GO gate. The spec's source facts were read from `main`; the stack is pinned to `v2026.7.1`. If that build lacks the OIDC provider, do **not** proceed — bump the image first (out of scope for this plan).

**Files:** none (runtime check on silverstone).

- [ ] **Step 1: Inspect the pinned image's dashboard auth plugins + OIDC env recognition**

```bash
docker run --rm --entrypoint sh nousresearch/hermes-agent:v2026.7.1 -c \
  'echo "== dashboard_auth plugins =="; \
   (ls -1 plugins/dashboard_auth/ 2>/dev/null || find / -type d -name dashboard_auth 2>/dev/null -exec ls -1 {} \;); \
   echo "== OIDC env references =="; grep -rl "HERMES_DASHBOARD_OIDC" / 2>/dev/null | head'
```

Expected: a `self_hosted` directory under `dashboard_auth/`, and at least one file referencing `HERMES_DASHBOARD_OIDC`.

- [ ] **Step 2: Decision**

- Present (`self_hosted` + `HERMES_DASHBOARD_OIDC*`) → **GO** to Task 2.
- Absent → **STOP.** The OIDC provider isn't in this build. Bump `nousresearch/hermes-agent` to a tag that includes it (re-verify with the Step 1 command against the new tag), update the `image:` pin in `stacks/hermes.yaml`, then restart this plan. Do NOT attempt OIDC on a build without the provider — the dashboard will fail closed and lock you out.

---

## Task 2 (host/operator): Create the Cloudflare Access Generic OIDC SaaS application

**Files:** none (Cloudflare Zero Trust dashboard).

- [ ] **Step 1: Add the app**

Zero Trust dashboard → **Access → Applications → Add an application → SaaS**; choose **OIDC**. Name it e.g. `hermes-dashboard-oidc`.

- [ ] **Step 2: Configure OIDC**

- **Redirect URL:** `https://hermes-dashboard.alekseev.us/auth/callback`
- **Scopes:** check `openid`, `email`, `profile`
- **Grant type:** Authorization Code (default)
- **Enable PKCE** (Proof Key for Code Exchange). Hermes always sends S256; a mismatch causes `ERR_TOO_MANY_REDIRECTS`.

- [ ] **Step 3: Save and record the generated values** (handed to Tasks 3 and 4)

- `Client ID` → this is **`APP_ID`**
- `Client secret`
- The **issuer** from the OIDC endpoints block — shape `https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<APP_ID>`

- [ ] **Step 4: Attach an Access policy to this SaaS app**

Add a policy: Include → Emails → *your email only*. This is the actual gate that decides who may obtain an OIDC token.

- [ ] **Step 5: Verify the IdP is live and is OIDC (not Managed OAuth)**

```bash
curl -s https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<APP_ID>/.well-known/openid-configuration \
  | jq '{issuer, authorization_endpoint, token_endpoint, jwks_uri}'
```

Expected: a JSON discovery doc with `issuer`, `authorization_endpoint`, `token_endpoint`, `jwks_uri` all under `…/sso/oidc/<APP_ID>`. If instead you only get `/.well-known/oauth-authorization-server`, you created a Managed-OAuth app by mistake — delete it and create a **Generic OIDC SaaS** app.

---

## Task 3 (repo/assistant): Edit `stacks/hermes.yaml` — OIDC env, drop basic-auth, drop edge Access

Depends on Task 2. Replace `<APP_ID>` in the code below with the real **Client ID** from Task 2.

**Files:**
- Modify: `stacks/hermes.yaml` (three edits)
- Verify with: `./scripts/validate-stack.sh hermes`

- [ ] **Step 1: Update the `/opt/data/.env` secret manifest in the header comment**

Replace:

```yaml
#     HERMES_DASHBOARD_BASIC_AUTH_PASSWORD - dashboard basic-auth password (real 2nd factor behind Access)
#     HERMES_DASHBOARD_BASIC_AUTH_SECRET   - dashboard token-signing key (openssl rand -base64 32)
```

with:

```yaml
#     HERMES_DASHBOARD_OIDC_CLIENT_SECRET - dashboard OIDC client secret (from the CF Access Generic OIDC SaaS app)
```

- [ ] **Step 2: Replace the dashboard env block**

Replace:

```yaml
      # First-party dashboard — fail-closed on a non-loopback bind, so basic-auth is REQUIRED.
      - HERMES_DASHBOARD=1
      - HERMES_DASHBOARD_HOST=0.0.0.0
      - HERMES_DASHBOARD_PORT=9119
      - HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
      # HERMES_DASHBOARD_BASIC_AUTH_PASSWORD and HERMES_DASHBOARD_BASIC_AUTH_SECRET
      # are set in /opt/data/.env (not Portainer) — gateway-only secrets.
      # NEVER set HERMES_DASHBOARD_INSECURE (bypasses the auth gate).
```

with (substitute the real `<APP_ID>` in both lines):

```yaml
      # First-party dashboard — fail-closed on a non-loopback bind. Auth = native OIDC (self_hosted
      # provider) against Cloudflare Access as a Generic OIDC SaaS IdP. No basic-auth, no edge Access.
      - HERMES_DASHBOARD=1
      - HERMES_DASHBOARD_HOST=0.0.0.0
      - HERMES_DASHBOARD_PORT=9119
      - HERMES_DASHBOARD_PUBLIC_URL=https://hermes-dashboard.alekseev.us
      # Cloudflare Access Generic OIDC SaaS app (team alekseev). issuer + client_id are non-secret → inline.
      - HERMES_DASHBOARD_OIDC_ISSUER=https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<APP_ID>
      - HERMES_DASHBOARD_OIDC_CLIENT_ID=<APP_ID>
      - HERMES_DASHBOARD_OIDC_SCOPES=openid profile email
      # HERMES_DASHBOARD_OIDC_CLIENT_SECRET is set in /opt/data/.env (not Portainer) — gateway-only secret.
      # NEVER set HERMES_DASHBOARD_INSECURE (no-op since June-2026 hardening; keep absent).
      # Do NOT set HERMES_DASHBOARD_OAUTH_CLIENT_ID (that selects the wrong `nous` provider).
```

- [ ] **Step 3: Drop edge Access for the dashboard host in the `cloudflared` ingress**

Replace:

```yaml
        - hostname: hermes-dashboard.alekseev.us
          service: http://hermes-gateway:9119
          access:
            required: true
            teamName: alekseev
            audTag:
              - f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d
```

with:

```yaml
        - hostname: hermes-dashboard.alekseev.us
          service: http://hermes-gateway:9119
          # OIDC-only: the dashboard's own Cloudflare-Access-OIDC gate is the sole auth. No edge Access.
          # (hermes + hermes-browser below keep their edge `access:` blocks.)
```

- [ ] **Step 4: Validate**

Run: `./scripts/validate-stack.sh hermes`
Expected: compose parses with no error. Unset `${VAR}` warnings for the other Portainer vars (`CAMOFOX_SHARED_KEY`, `HERMES_API_SERVER_KEY`, etc.) are expected/acceptable. Confirm the `hermes-dashboard.alekseev.us` ingress kept its `service: http://hermes-gateway:9119` route and has **no** `access:` key, while `hermes` and `hermes-browser` still have theirs.

- [ ] **Step 5: Commit**

```bash
git add stacks/hermes.yaml
git commit -m "feat(hermes): dashboard auth via Cloudflare Access OIDC (drop basic-auth + edge Access)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4 (host/operator): Provision the OIDC client secret; remove basic-auth secrets

**Files:** `/mnt/spool/apps/data/hermes/gateway/.env` on silverstone (the container's `/opt/data/.env`).

- [ ] **Step 1: Edit the on-disk `.env`**

Remove:

```
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=...
HERMES_DASHBOARD_BASIC_AUTH_SECRET=...
```

Add (value = **Client secret** from Task 2 Step 3):

```
HERMES_DASHBOARD_OIDC_CLIENT_SECRET=<client-secret-from-task-2>
```

- [ ] **Step 2: Sync the deployed stack to the committed compose**

In Portainer, update the hermes stack so the new `hermes-gateway` env + `cloudflared` ingress from Task 3 are in effect (pull the repo change / update the stack definition). Confirm there are **no leftover** `HERMES_DASHBOARD_BASIC_AUTH_*` or `HERMES_DASHBOARD_INSECURE` entries in the Portainer stack env.

---

## Task 5 (host/operator): Deploy and verify OIDC login

The edge self-hosted Access app may still list `hermes-dashboard` here — harmless (an extra login until Task 6). Deploy + verify OIDC works **before** removing the edge app (spec §6 safe cutover order).

- [ ] **Step 1: Redeploy** the hermes stack in Portainer (recreate `hermes-gateway` + `cloudflared`).

- [ ] **Step 2: Gateway comes up healthy, no fail-closed**

```bash
docker ps --filter name=hermes-gateway --format '{{.Status}}'
docker logs hermes-gateway 2>&1 | grep -iE 'dashboard|oidc|auth|refus|fail' | tail -30
```

Expected: `healthy`; logs show the dashboard bound with the OIDC/`self_hosted` provider and NO `Refusing to bind dashboard to 0.0.0.0` error.

- [ ] **Step 3: Active provider is `self_hosted`, and `/api/status` stays loopback-reachable (healthcheck depends on it)**

```bash
docker exec hermes-gateway python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9119/api/status',timeout=5).read().decode())"
```

Expected: JSON indicating auth is required with the OIDC/self-hosted provider active (not `basic`).

- [ ] **Step 4: Gateway can reach the IdP endpoints (outbound egress)**

```bash
docker exec hermes-gateway python3 -c "import urllib.request; print(urllib.request.urlopen('https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<APP_ID>/.well-known/openid-configuration',timeout=5).status)"
```

Expected: `200`. (Confirms the gateway can fetch discovery/JWKS; it already reaches `api.anthropic.com`, so egress should be open.)

- [ ] **Step 5: If it fail-closed or picked the wrong provider**, pin it explicitly in `/opt/data/config.yaml` and redeploy:

```yaml
dashboard:
  oauth:
    provider: self-hosted
```

- [ ] **Step 6: Interactive login test**

Open `https://hermes-dashboard.alekseev.us` in a browser. Expected: redirect to the Cloudflare Access OIDC authorize endpoint → Access login (your identity) → back to `/auth/callback` → dashboard loads. There must be **no HTTP basic-auth username/password prompt**, and the dashboard must show your real identity/email (not `admin`).

---

## Task 6 (host/operator): Cut over to OIDC-only — remove the edge Access app for the dashboard host

- [ ] **Step 1: Remove the hostname from the edge Access app**

Zero Trust → Access → Applications → edit the existing **self-hosted** app that protects the hostnames → remove `hermes-dashboard.alekseev.us` (leave `hermes.alekseev.us` and `hermes-browser.alekseev.us`).

- [ ] **Step 2: Verify the cutover**

```bash
curl -sI https://hermes-dashboard.alekseev.us/ | head
```

Expected: the response is **not** the edge Access login interstitial; the dashboard responds (redirecting to its own OIDC authorize). A fresh incognito visit goes straight to the dashboard's OIDC redirect — one login via Access-OIDC, no separate edge-Access login first.

- [ ] **Step 3: Regression — other two hosts unchanged**

```bash
curl -sI https://hermes.alekseev.us/ | head
curl -sI https://hermes-browser.alekseev.us/ | head
```

Expected: both still gated by the edge Access app (302 to the Access login), unchanged.

---

## Task 7 (host/operator): Post-cutover smoke tests (spec §11)

- [ ] **Step 1: No basic-auth anywhere** — full OIDC login succeeds; no username/password prompt; logging out and back in re-runs the OIDC flow.
- [ ] **Step 2: Identity/audit** — the dashboard session/user reflects your real email (from the `email`/`sub` claims), not `admin` or `drain-control`.
- [ ] **Step 3: Unrelated paths unaffected** — chat at `hermes.alekseev.us` and the noVNC handoff at `hermes-browser.alekseev.us` still work (edge Access + their own auth unchanged).
- [ ] **Step 4 (optional): Break-glass rehearsal** — temporarily re-add `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD`/`_SECRET` in Portainer + redeploy, confirm basic-auth login works as a recovery path, then revert to OIDC-only.

---

## Task 8 (repo/assistant, optional): Record as-built status

- [ ] **Step 1:** After a successful deploy, append an `## As-built (YYYY-MM-DD)` section to the spec capturing: the real `APP_ID`/issuer used, whether `config.yaml` provider pinning (Task 5 Step 5) was needed, whether `/api/status` stayed unauthenticated, whether the confidential `client_secret` path worked (spec §10 doc-drift risk), and any other deltas.
- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-07-03-hermes-dashboard-oidc-cloudflare-access-design.md
git commit -m "docs(hermes): record dashboard-OIDC as-built status

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
