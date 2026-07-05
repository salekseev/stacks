# Hermes Open WebUI OIDC (Cloudflare Access) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Open WebUI (`hermes.alekseev.us`) from Cloudflare-Access trusted-header SSO to its native OIDC relying-party against a dedicated Cloudflare Access Generic OIDC SaaS app, OIDC-only (no edge Access on this host), via a clean-slate DB wipe.

**Architecture:** One surgical edit to `stacks/hermes.yaml` — the `open-webui` env block (drop the two trusted-header vars, add OIDC vars), the header Portainer-secret manifest, and the `cloudflared` ingress for `hermes.alekseev.us` — validated with `validate-stack.sh`. All runtime work (create the SaaS-OIDC app, provision the client secret, wipe the OWUI DB, deploy, remove the edge app, smoke-test) is a host-side operator runbook on `silverstone`. The OWUI DB is disposable, so the migration wipes it and the first OIDC login becomes admin — no account merge, no lockout hazard.

**Tech Stack:** Docker Compose, `ghcr.io/open-webui/open-webui:v0.10.2` (Authlib generic OIDC), Cloudflare Access (Generic OIDC SaaS app), `cloudflare/cloudflared`, Portainer stack env.

**Spec:** `docs/superpowers/specs/2026-07-05-hermes-openwebui-oidc-cloudflare-access-design.md`

**⚠️ Precondition — sequencing:** Do NOT start this plan until the **dashboard OIDC cutover** (`docs/superpowers/plans/2026-07-05-hermes-dashboard-oidc-cloudflare-access.md`) is deployed and verified. Both edit the same `stacks/hermes.yaml`; this plan builds on the dashboard-edited file (its `hermes-dashboard` ingress already has no `access:` block). Running them together risks a compound stack-wide auth incident.

---

## File Structure

- **Modify (3 surgical edits):** `stacks/hermes.yaml` — (a) header Portainer-secret manifest, (b) `open-webui` env block, (c) `cloudflared` ingress entry for `hermes.alekseev.us`.
- **No tests/scripts created** — repo verification is `./scripts/validate-stack.sh hermes`; runtime verification is the host-side smoke tests (Tasks 5–7). Matches the established hermes-stack plan pattern.

**Split of responsibility:** **Task 3 is repo-side, assistant-executable** on `master`. **Tasks 1, 2, 4, 5, 6, 7** (and optional 8-repo) are a **host-side operator runbook** on `silverstone` — NOT assistant-executable. **Task 3 depends on `OWUI_APP_ID` from Task 2** (`<OWUI_APP_ID>` is a real operator-supplied value, like the tunnel UUID — not a plan placeholder).

---

## Task 1 (host/operator): Pre-flight — confirm the OIDC env var names on `v0.10.2`

Open WebUI's generic OIDC is well-established, so this is a light check (not a STOP/GO), mainly to resolve the one ambiguous var name: `ENABLE_PERSISTENT_CONFIG` vs `ENABLE_OAUTH_PERSISTENT_CONFIG`.

**Files:** none (runtime check on silverstone).

- [ ] **Step 1: Grep the image for the exact env var names**

```bash
docker run --rm --entrypoint sh ghcr.io/open-webui/open-webui:v0.10.2 -c \
  'grep -rhoE "ENABLE_OAUTH_SIGNUP|OAUTH_CLIENT_ID|OAUTH_CLIENT_SECRET|OPENID_PROVIDER_URL|OAUTH_SCOPES|OAUTH_PROVIDER_NAME|OAUTH_CODE_CHALLENGE_METHOD|DEFAULT_USER_ROLE|ENABLE_PERSISTENT_CONFIG|ENABLE_OAUTH_PERSISTENT_CONFIG" /app/backend 2>/dev/null | sort -u'
```

Expected: all of `ENABLE_OAUTH_SIGNUP`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OPENID_PROVIDER_URL`, `OAUTH_SCOPES`, `OAUTH_PROVIDER_NAME`, `OAUTH_CODE_CHALLENGE_METHOD`, `DEFAULT_USER_ROLE` appear, plus **exactly one** of `ENABLE_PERSISTENT_CONFIG` / `ENABLE_OAUTH_PERSISTENT_CONFIG`.

- [ ] **Step 2: Record the persistent-config var name** that actually appears — use it in Task 3 Step 2 (the plan assumes `ENABLE_PERSISTENT_CONFIG`; substitute if the grep shows otherwise).

---

## Task 2 (host/operator): Create the dedicated Cloudflare Access Generic OIDC SaaS app

**Files:** none (Cloudflare Zero Trust dashboard).

- [ ] **Step 1:** Zero Trust → **Access → Applications → Add an application → SaaS** → **OIDC**. Name e.g. `hermes-openwebui-oidc`. (Separate from the dashboard's SaaS app.)
- [ ] **Step 2: Configure OIDC**
  - **Redirect URL:** `https://hermes.alekseev.us/oauth/oidc/callback`
  - **Scopes:** `openid`, `email`, `profile`
  - **Grant type:** Authorization Code
  - **Enable PKCE** (OWUI will send S256; mismatch = hard auth failure)
- [ ] **Step 3: Save and record** `Client ID` → **`OWUI_APP_ID`**, the `Client secret`, and the issuer (shape `https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<OWUI_APP_ID>`).
- [ ] **Step 4: Attach an Access policy** to this SaaS app allowing your identity (Include → Emails → your email).
- [ ] **Step 5: Verify the IdP is live and OIDC (not Managed OAuth)**

```bash
curl -s https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<OWUI_APP_ID>/.well-known/openid-configuration \
  | jq '{issuer, authorization_endpoint, token_endpoint, jwks_uri}'
```

Expected: a JSON discovery doc with all four fields under `…/sso/oidc/<OWUI_APP_ID>`. (If you only get `/.well-known/oauth-authorization-server`, you made a Managed-OAuth app — delete and recreate as Generic OIDC SaaS.)

---

## Task 3 (repo/assistant): Edit `stacks/hermes.yaml` — OWUI OIDC env, drop trusted-header, drop edge Access

Depends on Task 2 (`OWUI_APP_ID`). Runs on the dashboard-edited `stacks/hermes.yaml`. Replace `<OWUI_APP_ID>` below with the real Client ID.

**Files:**
- Modify: `stacks/hermes.yaml` (three edits)
- Verify with: `./scripts/validate-stack.sh hermes`

- [ ] **Step 1: Add the OWUI OIDC client secret to the header Portainer-secret manifest**

Replace:

```yaml
#     HERMES_API_SERVER_KEY - bearer for the gateway OpenAI API :8642 (== Open WebUI OPENAI_API_KEY); >=8 chars
```

with:

```yaml
#     HERMES_API_SERVER_KEY - bearer for the gateway OpenAI API :8642 (== Open WebUI OPENAI_API_KEY); >=8 chars
#     OWUI_OIDC_CLIENT_SECRET - Open WebUI OIDC client secret (from the CF Access Generic OIDC SaaS app for hermes.alekseev.us)
```

- [ ] **Step 2: Replace the trusted-header vars in the `open-webui` env with the OIDC block**

Replace:

```yaml
      - WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Cf-Access-Authenticated-User-Email
      - WEBUI_AUTH_TRUSTED_NAME_HEADER=Cf-Access-Authenticated-User-Email
```

with (substitute the real `<OWUI_APP_ID>` in both lines; use the persistent-config var name confirmed in Task 1):

```yaml
      # Native OIDC (Authlib) against a dedicated Cloudflare Access Generic OIDC SaaS app.
      # Replaces trusted-header SSO — OWUI no longer trusts any Cf-Access-* header.
      - ENABLE_OAUTH_SIGNUP=true
      - OAUTH_PROVIDER_NAME=Cloudflare Access
      - OAUTH_CLIENT_ID=<OWUI_APP_ID>
      - OAUTH_CLIENT_SECRET=${OWUI_OIDC_CLIENT_SECRET}
      - OPENID_PROVIDER_URL=https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<OWUI_APP_ID>/.well-known/openid-configuration
      - OAUTH_SCOPES=openid email profile
      - OAUTH_CODE_CHALLENGE_METHOD=S256
      - DEFAULT_USER_ROLE=user
      - ENABLE_PERSISTENT_CONFIG=false
```

(Note: `ENABLE_LOGIN_FORM=false`, `ENABLE_SIGNUP=false`, `WEBUI_AUTH=true`, `WEBUI_URL=https://hermes.alekseev.us` are already present and stay — the callback `/oauth/oidc/callback` derives from `WEBUI_URL`. Do NOT set `ENABLE_OAUTH_ROLE_MANAGEMENT` — leave role management off.)

- [ ] **Step 3: Drop edge Access for `hermes.alekseev.us` in the `cloudflared` ingress**

Replace:

```yaml
        - hostname: hermes.alekseev.us
          service: http://open-webui:8080
          access:
            required: true
            teamName: alekseev
            audTag:
              - f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d
```

with:

```yaml
        - hostname: hermes.alekseev.us
          service: http://open-webui:8080
          # OIDC-only: Open WebUI's own Cloudflare-Access-OIDC gate is the sole auth. No edge Access.
          # (After the dashboard cutover too, only hermes-browser keeps an edge `access:` block.)
```

- [ ] **Step 4: Validate**

Run: `./scripts/validate-stack.sh hermes`
Expected: parses with no error. Unset `${VAR}` warnings (incl. the new `${OWUI_OIDC_CLIENT_SECRET}`) are expected/acceptable. Confirm `hermes.alekseev.us` kept its `service: http://open-webui:8080` route with **no** `access:` key, and that `hermes-browser.alekseev.us` still has its `access:` block (and `hermes-dashboard.alekseev.us` still has none, from the dashboard cutover).

- [ ] **Step 5: Commit**

```bash
git add stacks/hermes.yaml
git commit -m "feat(hermes): Open WebUI auth via Cloudflare Access OIDC (drop trusted-header + edge Access)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4 (host/operator): Provision the OWUI OIDC client secret

**Files:** Portainer stack env for the hermes stack.

- [ ] **Step 1:** Add the Portainer stack env var `OWUI_OIDC_CLIENT_SECRET=<client-secret-from-task-2>`.
- [ ] **Step 2:** Sync the deployed stack to the committed compose (pull the Task 3 change / update the stack definition).

---

## Task 5 (host/operator): Clean-slate wipe + deploy + verify OIDC login

- [ ] **Step 1: Stop Open WebUI and wipe its data dir** (clean slate — the DB is disposable):

```bash
docker stop open-webui 2>/dev/null || true
mv /mnt/spool/apps/data/hermes/open-webui{,.bak-$(date +%Y%m%d)} \
  && mkdir /mnt/spool/apps/data/hermes/open-webui \
  && chown 1000:1000 /mnt/spool/apps/data/hermes/open-webui
```

Expected: the old dir moved aside (trivial recovery), a fresh empty dir owned by uid 1000.

- [ ] **Step 2: Redeploy** the hermes stack in Portainer (recreate `open-webui`). You may leave the edge Access app on `hermes.alekseev.us` in place for this deploy to verify OIDC before removing it.

- [ ] **Step 3: First OIDC login = admin**

In a browser, open `https://hermes.alekseev.us`. Expected: a "Sign in with Cloudflare Access" button / redirect → Access login → back to `/oauth/oidc/callback` → chat UI loads. Because the DB is empty, this first login is **admin**. Confirm the user is your real email and the admin panel is accessible.

- [ ] **Step 4: Confirm env was honored (not shadowed by persisted config)**

```bash
docker exec open-webui sh -c 'env | grep -E "ENABLE_OAUTH_SIGNUP|OAUTH_CLIENT_ID|OPENID_PROVIDER_URL"'
```

Expected: the OIDC vars are present. If login shows no OAuth button, the persisted-config var was wrong (Task 1) — fix the var name and redeploy.

---

## Task 6 (host/operator): Cut over to OIDC-only — remove the edge Access app for `hermes.alekseev.us`

- [ ] **Step 1:** Zero Trust → Access → Applications → edit the self-hosted app protecting the hostnames → remove `hermes.alekseev.us` (leave `hermes-browser.alekseev.us`; `hermes-dashboard` was already removed in the dashboard cutover). The self-hosted app now covers only `hermes-browser`.
- [ ] **Step 2: Verify cutover**

```bash
curl -sI https://hermes.alekseev.us/ | head
```

Expected: not the edge Access interstitial; Open WebUI responds (its own OAuth redirect). A fresh incognito visit goes straight to OWUI's Cloudflare-Access-OIDC login.

- [ ] **Step 3: Regression**

```bash
curl -sI https://hermes-browser.alekseev.us/ | head
```

Expected: still edge-gated (302 to the Access login), unchanged.

---

## Task 7 (host/operator): Post-cutover smoke tests

- [ ] **Step 1: No header trust** — with the edge app removed, a direct-through-tunnel request without an OIDC session does not grant access (OWUI redirects to login); the old `Cf-Access-*` header path is gone.
- [ ] **Step 2: Identity** — the logged-in user is your real email; chat to the Hermes model works end-to-end (`hermes-gateway:8642/v1`).
- [ ] **Step 3: Unrelated paths unaffected** — the dashboard (OIDC) and `hermes-browser` (edge-gated) still work.
- [ ] **Step 4 (optional): Break-glass rehearsal** — confirm recovery is trivial: wipe the data dir + redeploy, or temporarily set `ENABLE_LOGIN_FORM=true` and log in with a known admin password. (Nothing of value is lost.)

---

## Task 8 (repo/assistant, optional): Record as-built status

- [ ] **Step 1:** After a successful deploy, append an `## As-built (YYYY-MM-DD)` section to the spec: the real `OWUI_APP_ID`/issuer used, the confirmed persistent-config var name, and any deltas.
- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-07-05-hermes-openwebui-oidc-cloudflare-access-design.md
git commit -m "docs(hermes): record Open WebUI OIDC as-built status

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
