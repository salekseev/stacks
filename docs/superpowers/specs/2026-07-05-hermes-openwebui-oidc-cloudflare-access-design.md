# Hermes Open WebUI Auth → Cloudflare Access OIDC — Design Spec

- **Date:** 2026-07-05
- **Status:** Approved (brainstorm) — user-confirmed **OIDC-only** edge posture 2026-07-05; **pending user review of this written spec**.
- **Stack file:** `stacks/hermes.yaml` (`open-webui` env + `cloudflared` ingress)
- **Author:** brainstormed with Claude Code (ultracode)
- **Sibling / sequencing:** Sequenced to run **after** `2026-07-03-hermes-dashboard-oidc-cloudflare-access-design.md` (the dashboard OIDC cutover) lands and is verified. Independently rollback-able. Supersedes the trusted-header SSO posture for `open-webui` from `2026-06-30-hermes-gateway-openwebui-port-design.md`.

---

## 1. Goal & framing

Replace Open WebUI's **trusted-header SSO** (`WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Cf-Access-Authenticated-User-Email`) with **native OIDC** against a **dedicated** Cloudflare Access Generic-OIDC-SaaS app for `hermes.alekseev.us`.

**This is defense-in-depth, not a new goal.** Trusted-header already delivers password-less SSO + per-user identity (goals met). The motivations are:
1. **Remove the forgeable-header footgun.** Trusted-header is safe only while "no published ports + `cloudflared` strips client `Cf-Access-*` headers" holds. That's fragile: `camofox`/`x11vnc` share `hermes-net`, so any workload on that network reaching `open-webui:8080` directly could forge `Cf-Access-Authenticated-User-Email` and be auto-provisioned **admin**; a one-line `ports:` slip does the same.
2. **Cryptographic identity.** OIDC verifies a signed ID token (JWKS), independent of network topology.
3. **Session lifecycle** — expiry / logout / deprovisioning that per-request header auth lacks.

**Security note (why OIDC-only is coherent here):** the switch **removes** the trusted-header vars, so Open WebUI stops trusting `Cf-Access-*` headers entirely — the forgery vector is closed by the OIDC migration *itself*, not by the edge app. The edge Access app was load-bearing only under trusted-header (it injected the header OWUI trusted); under OIDC it is pure redundancy, so dropping it does not reopen the vector. With zero published ports today there is **no externally-exploitable hole** — this is hardening a latent risk, not closing an open one.

**Topology decision: OIDC-only** (user-confirmed, consistent with the dashboard). Drop the edge self-hosted Access app + `cloudflared` `access:` block for `hermes.alekseev.us`; Open WebUI's own OIDC (gated by the SaaS app's Access policy) becomes the sole auth. **After this + the dashboard cutover, only `hermes-browser.alekseev.us` retains an edge `access:` block.**

## 2. Feasibility — research-verified (medium confidence)

- Open WebUI has first-class **generic OIDC** (Authlib): enabled via `ENABLE_OAUTH_SIGNUP=true` + `OAUTH_CLIENT_ID` + `OAUTH_CLIENT_SECRET` + `OPENID_PROVIDER_URL` (the discovery `/.well-known/openid-configuration` URL). Works with any compliant provider incl. Cloudflare Access.
- Fixed callback path **`/oauth/oidc/callback`**, derived from `WEBUI_URL`.
- ID token verified via the provider JWKS. **PKCE is opt-in** via `OAUTH_CODE_CHALLENGE_METHOD=S256`.
- Confirm exact env var names against the pinned image `ghcr.io/open-webui/open-webui:v0.10.2` at deploy — especially `ENABLE_PERSISTENT_CONFIG` (see §8).

## 3. Auth flow (after)

```
Browser ──► hermes.alekseev.us ──► cloudflared ──► open-webui:8080
                (OIDC-only: no edge Access, no origin JWT validation for this host)
                                   │
          OWUI has no session      │ 302
                                   ▼
   https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<OWUI_APP_ID>/authorization
                                   │  Cloudflare Access = OIDC IdP; the (dedicated) SaaS-OIDC
                                   │  app's Access policy requires your identity
                                   ▼  auth code + PKCE (S256)
   hermes.alekseev.us/oauth/oidc/callback
                                   │  OWUI verifies ID token vs JWKS, links to the existing
                                   │  admin by verified email (merge), sets its session cookie
                                   ▼
                              Open WebUI (logs your real email; no header trust)
```

## 4. Repo change — `stacks/hermes.yaml`

### 4.1 `open-webui` environment

| Var | Action | Notes |
|---|---|---|
| `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` | **remove** | stop trusting `Cf-Access-Authenticated-User-Email` |
| `WEBUI_AUTH_TRUSTED_NAME_HEADER` | **remove** | " |
| `ENABLE_OAUTH_SIGNUP` | **add** `true` | master switch for OIDC login/provisioning |
| `OAUTH_CLIENT_ID` | **add** `<OWUI_APP_ID>` | inline (non-secret); dedicated SaaS-OIDC app id |
| `OPENID_PROVIDER_URL` | **add** `https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<OWUI_APP_ID>/.well-known/openid-configuration` | inline; discovery URL |
| `OAUTH_PROVIDER_NAME` | **add** `Cloudflare Access` | login button label |
| `OAUTH_SCOPES` | **add** `openid email profile` | default |
| `OAUTH_CODE_CHALLENGE_METHOD` | **add** `S256` | PKCE (enable PKCE on the CF app too) |
| `OAUTH_MERGE_ACCOUNTS_BY_EMAIL` | **add** `true` | link OIDC login to the existing admin by email (safe: Access verifies emails) |
| `ENABLE_PERSISTENT_CONFIG` | **add** `false` | make env authoritative over the persisted DB config (verify exact name — §8) |
| `DEFAULT_USER_ROLE` | **add** `user` | preserve today's auto-provisioning (single operator); default would be `pending` |
| `OAUTH_CLIENT_SECRET` | **add** `${OWUI_OIDC_CLIENT_SECRET}` | Portainer stack env (OWUI has no `/opt/data/.env`) |
| `WEBUI_AUTH` / `ENABLE_LOGIN_FORM` / `ENABLE_SIGNUP` / `WEBUI_URL` | **keep** | `true` / `false` / `false` / `https://hermes.alekseev.us` (callback derives from `WEBUI_URL`) |
| `ENABLE_OAUTH_ROLE_MANAGEMENT` | **do not set** (off) | avoid recomputing/overwriting the merged admin's role; dodges known role-mapping bugs |

### 4.2 `cloudflared` ingress
Drop the `access:` block for `hermes.alekseev.us` (keep the route):

```yaml
- hostname: hermes.alekseev.us
  service: http://open-webui:8080
  # OIDC-only: Open WebUI's own Cloudflare-Access-OIDC gate is the sole auth. No edge Access.
  # (After the dashboard cutover too, only hermes-browser below keeps an edge `access:` block.)
```

## 5. Secrets delta

| Secret | Used by | Change |
|---|---|---|
| `OWUI_OIDC_CLIENT_SECRET` (Portainer stack env) | `open-webui` `OAUTH_CLIENT_SECRET` | **new** — from the dedicated CF Access SaaS-OIDC app |
| `OAUTH_CLIENT_ID` / `OPENID_PROVIDER_URL` | `open-webui` | **new, non-secret** — inline in compose |

(No basic-auth/header secrets existed for OWUI to remove.)

## 6. Host-side migration (operator; **sequenced after** the dashboard cutover)

1. **Create a dedicated Generic OIDC SaaS app** in Cloudflare Access for `hermes.alekseev.us`: Redirect URL `https://hermes.alekseev.us/oauth/oidc/callback`; scopes `openid email profile`; **PKCE enabled**; attach an Access policy that **mirrors the identities allowed today**. Record `OWUI_APP_ID` (= client_id), the client secret, and verify the discovery URL.
2. **Back up** the OWUI data dir `/mnt/spool/apps/data/hermes/open-webui` — this is the recovery insurance (there is no password fallback).
3. Provision `OWUI_OIDC_CLIENT_SECRET` in Portainer stack env.
4. Deploy the `stacks/hermes.yaml` edit **while the edge Access app on `hermes.alekseev.us` is still present** (verify OIDC + the admin merge before removing any layer). Log in with the **exact same admin email** → merge-by-email links the OIDC identity to the existing admin (avoids the duplicate-pending lockout).
5. **Verify:** OIDC login succeeds; the existing admin is preserved (not a new `pending` duplicate); a normal login works; no `Cf-Access-*` header trust remains.
6. **Cut over to OIDC-only:** remove `hermes.alekseev.us` from the edge Access app (confirm the `cloudflared` `access:` block is already gone from the deployed stack). Leave `hermes-browser` edge-gated.

**Break-glass (if the merge/login fails):** restore the step-2 backup; or temporarily set `ENABLE_LOGIN_FORM=true` + a known admin password and redeploy; or `docker exec` + set the user's role to `admin` in the SQLite DB.

## 7. Alternatives considered

| Alternative | Verdict | Why |
|---|---|---|
| **Keep trusted-header (status quo)** | viable, not chosen | Fully defensible — goals already met. We choose OIDC for the hardening in §1. |
| **Keep edge Access + OIDC (defense-in-depth)** | offered, not chosen | User chose OIDC-only for consistency with the dashboard. Acceptable because removing the trusted-header vars already closes the forgery vector (§1). |
| **Fold into the dashboard spec/plan** | rejected | Different service with a live-DB admin-lockout hazard; bundling risks a compound stack-wide incident and muddies rollback. Kept separate + sequenced after. |

## 8. Risks / validate-at-deploy

- **⚠️ Admin-lockout hazard (biggest):** OWUI matches OAuth logins by `oauth_sub` first; the existing trusted-header admin has no `oauth_sub`, and first-user-becomes-admin only fires on an empty DB. A naive cutover creates a **duplicate `pending`** account and **locks out the admin**, with no password fallback (`ENABLE_LOGIN_FORM=false`). Mitigation = §6 steps 2 (backup) + `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` + same-email login.
- **`ENABLE_PERSISTENT_CONFIG` exact name/behavior:** if the persisted DB config shadows env, the new OAuth env is silently ignored and the cutover no-ops. Verify the exact var against `v0.10.2` (the two research inputs disagreed on `ENABLE_PERSISTENT_CONFIG` vs `ENABLE_OAUTH_PERSISTENT_CONFIG`); or apply config via the Admin Panel.
- **`DEFAULT_USER_ROLE`** defaults to `pending` under OIDC → set `user` to preserve today's auto-provisioning.
- **Policy parity:** the dedicated SaaS-OIDC app has its own Allow policy — must allow your identity or OIDC denies even though the (soon-removed) edge app would have allowed you.
- **PKCE consistency:** if the CF app enables PKCE, OWUI must send `S256`; mismatch = hard auth failure. Enable on both.
- **merge-by-email safety:** safe **only** because Cloudflare Access verifies emails. Never enable against an IdP with unverified emails (account-takeover vector).
- **Role-management bugs** (upstream #13676/#15551/#20518: `OAUTH_ALLOWED_ROLES`/mapping silently ignored on some providers): keep `ENABLE_OAUTH_ROLE_MANAGEMENT` **off**.
- **No break-glass with login-form off** → the backup is the recovery path; take it first.
- **Reduced defense-in-depth (accepted):** OIDC-only drops the edge layer; OWUI's pre-auth routes become reachable via the tunnel (OWUI still cryptographically gates all data).
- **Egress:** `open-webui` must reach `cloudflareaccess.com` for discovery/JWKS/token.
- **Double-Access not applicable:** because OIDC-only drops the edge app, there is no edge+OIDC double login and no callback bypass to configure (unlike a keep-edge design).
- **Sequencing:** land and verify the dashboard cutover **first**, to avoid a compound stack-wide auth incident.
- **Image pin:** confirm OWUI OIDC env var names on `ghcr.io/open-webui/open-webui:v0.10.2`.

## 9. Testing & validation

1. **Static:** `./scripts/validate-stack.sh hermes` (compose parse; `hermes.alekseev.us` ingress keeps its route, loses `access:`; `hermes-browser` keeps `access:`).
2. **OIDC login:** `hermes.alekseev.us` unauthenticated → redirect to CF OIDC → login → `/oauth/oidc/callback` → chat UI loads. No trusted-header dependency.
3. **Admin preserved:** the merged account is your existing admin (not a new `pending` duplicate); admin panel accessible.
4. **Identity:** the logged-in user is your real email.
5. **Regression:** the dashboard (already OIDC) and `hermes-browser` (still edge-gated) are unaffected.
6. **Break-glass rehearsal (optional):** confirm the backup-restore / `ENABLE_LOGIN_FORM=true` recovery path.

## 10. Decisions — user-confirmed 2026-07-05

- **Edge posture:** **OIDC-only** (drop the edge Access app + `cloudflared` `access:` block for `hermes.alekseev.us`). ✅
- **Structure:** **separate spec + plan**, sequenced after the dashboard cutover (flag if a single combined cutover is actually wanted). ✅ (interpretation)
- **Inline vs Portainer:** non-secret `client_id` / `OPENID_PROVIDER_URL` **inline**; `OAUTH_CLIENT_SECRET` via **Portainer** `${OWUI_OIDC_CLIENT_SECRET}`. ✅
- **`DEFAULT_USER_ROLE=user`** to preserve current auto-provisioning. ✅
