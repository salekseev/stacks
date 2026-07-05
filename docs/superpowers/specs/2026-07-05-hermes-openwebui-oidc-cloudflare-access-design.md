# Hermes Open WebUI Auth → Cloudflare Access OIDC — Design Spec

- **Date:** 2026-07-05
- **Status:** Approved 2026-07-05 — OIDC-only edge posture; user confirmed the **OWUI DB is disposable → clean-slate migration** (see §6/§10). Ready for implementation planning.
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
| `OAUTH_MERGE_ACCOUNTS_BY_EMAIL` | **omit** | not needed — clean-slate migration wipes the DB, so there is no pre-existing account to merge (§6) |
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

Because the OWUI DB is **disposable** (user-confirmed — no critical data), we use a **clean-slate** migration: wipe the DB so the first OIDC login auto-provisions as admin. This removes the merge-by-email step and the admin-lockout hazard entirely.

1. **Create a dedicated Generic OIDC SaaS app** in Cloudflare Access for `hermes.alekseev.us`: Redirect URL `https://hermes.alekseev.us/oauth/oidc/callback`; scopes `openid email profile`; **PKCE enabled**; attach an Access policy that allows your identity. Record `OWUI_APP_ID` (= client_id), the client secret, and verify the discovery URL.
2. Provision `OWUI_OIDC_CLIENT_SECRET` in Portainer stack env.
3. **Wipe the OWUI data dir for a clean slate.** Stop `open-webui`, then empty `/mnt/spool/apps/data/hermes/open-webui` (e.g. move it aside so recovery is trivial): `mv /mnt/spool/apps/data/hermes/open-webui{,.bak-YYYYMMDD} && mkdir /mnt/spool/apps/data/hermes/open-webui && chown 1000:1000 /mnt/spool/apps/data/hermes/open-webui`. An empty DB makes the first OIDC login the admin.
4. Deploy the `stacks/hermes.yaml` edit. (You may leave the edge Access app on `hermes.alekseev.us` in place for this first deploy to verify OIDC before removing it — optional now that data is disposable.)
5. **Verify:** the first OIDC login succeeds and lands as **admin** (empty DB); chat works; the user is your real email; no `Cf-Access-*` header trust remains.
6. **Cut over to OIDC-only:** remove `hermes.alekseev.us` from the edge Access app (confirm the `cloudflared` `access:` block is already gone from the deployed stack). Leave `hermes-browser` edge-gated.

**Break-glass (trivial — data is disposable):** wipe the data dir again and redeploy; or temporarily set `ENABLE_LOGIN_FORM=true` + a known admin password. Nothing of value is lost.

## 7. Alternatives considered

| Alternative | Verdict | Why |
|---|---|---|
| **Keep trusted-header (status quo)** | viable, not chosen | Fully defensible — goals already met. We choose OIDC for the hardening in §1. |
| **Keep edge Access + OIDC (defense-in-depth)** | offered, not chosen | User chose OIDC-only for consistency with the dashboard. Acceptable because removing the trusted-header vars already closes the forgery vector (§1). |
| **Fold into the dashboard spec/plan** | rejected | Different service with a live-DB admin-lockout hazard; bundling risks a compound stack-wide incident and muddies rollback. Kept separate + sequenced after. |

## 8. Risks / validate-at-deploy

- **Admin-lockout hazard — NEUTRALIZED by the clean-slate migration (§6):** the risk (OWUI matches `oauth_sub` first; an existing trusted-header admin has none; no password fallback) only applies when migrating a *populated* DB. Because the DB is wiped, the first OIDC login auto-becomes admin — no merge, no duplicate-`pending` lockout. Break-glass = wipe + redeploy.
- **`ENABLE_PERSISTENT_CONFIG` exact name/behavior (lower severity with a fresh DB):** on the wiped DB the env is read on first boot, so the "persisted config shadows env" trap is largely moot for the initial cutover; still set it (`false`) so future env changes stay authoritative, and verify the exact var name against `v0.10.2` (research inputs disagreed on `ENABLE_PERSISTENT_CONFIG` vs `ENABLE_OAUTH_PERSISTENT_CONFIG`).
- **`DEFAULT_USER_ROLE`** defaults to `pending` under OIDC → set `user` to preserve today's auto-provisioning.
- **Policy parity:** the dedicated SaaS-OIDC app has its own Allow policy — must allow your identity or OIDC denies even though the (soon-removed) edge app would have allowed you.
- **PKCE consistency:** if the CF app enables PKCE, OWUI must send `S256`; mismatch = hard auth failure. Enable on both.
- **merge-by-email:** not used (clean-slate migration has no pre-existing account to merge). If you ever migrate a *populated* DB instead, `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` is safe here only because Access verifies emails (never with unverified-email IdPs — account-takeover vector).
- **Role-management bugs** (upstream #13676/#15551/#20518: `OAUTH_ALLOWED_ROLES`/mapping silently ignored on some providers): keep `ENABLE_OAUTH_ROLE_MANAGEMENT` **off**.
- **Recovery is trivial** — data is disposable, so wipe + redeploy (or temporarily `ENABLE_LOGIN_FORM=true`) is the fallback; no backup required as insurance.
- **Reduced defense-in-depth (accepted):** OIDC-only drops the edge layer; OWUI's pre-auth routes become reachable via the tunnel (OWUI still cryptographically gates all data).
- **Egress:** `open-webui` must reach `cloudflareaccess.com` for discovery/JWKS/token.
- **Double-Access not applicable:** because OIDC-only drops the edge app, there is no edge+OIDC double login and no callback bypass to configure (unlike a keep-edge design).
- **Sequencing:** land and verify the dashboard cutover **first**, to avoid a compound stack-wide auth incident.
- **Image pin:** confirm OWUI OIDC env var names on `ghcr.io/open-webui/open-webui:v0.10.2`.

## 9. Testing & validation

1. **Static:** `./scripts/validate-stack.sh hermes` (compose parse; `hermes.alekseev.us` ingress keeps its route, loses `access:`; `hermes-browser` keeps `access:`).
2. **OIDC login:** `hermes.alekseev.us` unauthenticated → redirect to CF OIDC → login → `/oauth/oidc/callback` → chat UI loads. No trusted-header dependency.
3. **First login = admin:** the first OIDC login on the wiped DB lands as admin; admin panel accessible.
4. **Identity:** the logged-in user is your real email.
5. **Regression:** the dashboard (already OIDC) and `hermes-browser` (still edge-gated) are unaffected.
6. **Break-glass rehearsal (optional):** confirm the backup-restore / `ENABLE_LOGIN_FORM=true` recovery path.

## 10. Decisions — user-confirmed 2026-07-05

- **Edge posture:** **OIDC-only** (drop the edge Access app + `cloudflared` `access:` block for `hermes.alekseev.us`). ✅
- **Structure:** **separate spec + plan**, sequenced after the dashboard cutover (flag if a single combined cutover is actually wanted). ✅ (interpretation)
- **Inline vs Portainer:** non-secret `client_id` / `OPENID_PROVIDER_URL` **inline**; `OAUTH_CLIENT_SECRET` via **Portainer** `${OWUI_OIDC_CLIENT_SECRET}`. ✅
- **`DEFAULT_USER_ROLE=user`** to preserve current auto-provisioning. ✅
- **OWUI DB is disposable** (no critical data) → **clean-slate migration**: wipe the data dir, first OIDC login = admin; no merge-by-email, no backup-as-insurance. ✅
