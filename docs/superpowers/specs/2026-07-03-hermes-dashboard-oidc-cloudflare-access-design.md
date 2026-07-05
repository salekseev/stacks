# Hermes Dashboard Auth → Cloudflare Access OIDC — Design Spec

- **Date:** 2026-07-03
- **Status:** Approved — user-confirmed 2026-07-05: (a) inline non-secret ids, (b) OIDC-only edge posture, (c) `drain` excluded. Ready for implementation planning.
- **Stack file:** `stacks/hermes.yaml` (`hermes-gateway` env + `cloudflared` ingress)
- **Author:** brainstormed with Claude Code (ultracode)
- **Related:** `2026-06-30-hermes-gateway-openwebui-port-design.md` — establishes the dashboard basic-auth model this supersedes.

---

## 1. Goal & what changes

Replace the Hermes dashboard's HTTP **basic-auth** (a shared `admin` password + token-signing secret) with the dashboard's **native OIDC relying-party** mode (`self_hosted` provider), using **Cloudflare Access as a Generic OIDC SaaS identity provider** — the pattern in Cloudflare's [generic-oidc-saas](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/saas-apps/generic-oidc-saas/) doc.

**User goals (the two that drove every decision):**
1. **Kill the shared password** — stop managing a dashboard admin password/secret at rest; authenticate via Cloudflare Access identity.
2. **Per-user identity + audit** — the dashboard should record the real signed-in identity (email), not a shared `admin`. Single operator; no role model.

Explicitly **not** goals: IdP-backed MFA (already enforced at the Access edge) and "OIDC for its own sake."

**Topology decision: OIDC-only.** The dashboard's own Cloudflare-Access-OIDC gate becomes the *sole* auth for `hermes-dashboard.alekseev.us`. The existing self-hosted edge Access app + origin-side `cloudflared` JWT validation are **removed for this host** (kept for `hermes` and `hermes-browser`). Keeping edge Access as redundant defense-in-depth is documented as an easy opt-in in §8.

## 2. Feasibility — source-verified (why this is possible natively)

Ground-truthed against `NousResearch/hermes-agent` source (commit `551e5af5`), not the (drift-prone) docs.

- **Dashboard auth providers are exactly four:** `basic`, `nous` (NousResearch portal OAuth), **`self_hosted` (generic OIDC RP)**, `drain` (non-interactive bearer). There is **no trusted-reverse-proxy header provider** — the dashboard reads **zero** inbound identity headers (no `Cf-Access-Authenticated-User-Email`, no `X-Forwarded-Email`). `HERMES_DASHBOARD_INSECURE` is a **no-op** (June-2026 hardening). Fail-closed on a non-loopback bind requires a registered provider.
- **`self_hosted` is a standards-compliant OIDC RP:** discovery via `{issuer}/.well-known/openid-configuration`; authorization-code + **PKCE (S256, always sent)**; verifies the **ID token** against the discovered JWKS (RS/ES 256/384/512; HS256 excluded) with `iss`/`aud` pinned. Supports **confidential** (`client_secret`) *and* public (PKCE-only) clients. Claims map: `user_id ← sub` (required), `email ← email`, `display_name ← name → preferred_username → nickname → email`. Callback URI = `<public URL>/auth/callback`.
- **Cloudflare Access as OIDC IdP** issues `client_id` (= the SaaS app id), a `client_secret`, and exposes endpoints rooted at `https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<app-id>` (team = `alekseev`). These endpoints live on `cloudflareaccess.com`, *not* on the app hostname — so they are unaffected by any self-hosted Access policy on `hermes-dashboard.alekseev.us`.
- **Doc-drift caveats (confirmed):** the web docs wrongly state confidential OIDC clients are unsupported and that `--insecure` still disables auth, and speculate a trusted-proxy header mode — all contradicted by source. Trust the source.

## 3. Auth flow (after)

```
Browser ──► hermes-dashboard.alekseev.us ──► cloudflared ──► hermes-gateway:9119
                (OIDC-only: no edge Access, no origin JWT validation for this host)
                                   │
          dashboard has no session │ 302
                                   ▼
   https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<app-id>/authorization
                                   │  Cloudflare Access = OIDC IdP; the SaaS-OIDC app's
                                   │  own Access policy requires your identity (login if needed)
                                   ▼  auth code + PKCE (S256)
   hermes-dashboard.alekseev.us/auth/callback
                                   │  dashboard exchanges code at token_endpoint,
                                   │  verifies ID token vs JWKS (iss/aud pinned),
                                   ▼  sets its HMAC HTTP-only session cookie
                              dashboard (logs your real email from `email`/`sub`)
```

One visible login, via Cloudflare Access, no password. Dashboard records your real identity.

## 4. Repo-side changes — `stacks/hermes.yaml` (the only automatable piece)

### 4.1 `hermes-gateway` environment
Remove the basic-auth trio; add OIDC. Keep the enable/host/port lines.

| Var | Value | Where | Notes |
|---|---|---|---|
| `HERMES_DASHBOARD` | `1` | compose | unchanged |
| `HERMES_DASHBOARD_HOST` | `0.0.0.0` | compose | unchanged (reached by cloudflared) |
| `HERMES_DASHBOARD_PORT` | `9119` | compose | unchanged |
| `HERMES_DASHBOARD_PUBLIC_URL` | `https://hermes-dashboard.alekseev.us` | compose | fixes the `/auth/callback` redirect URI behind the proxy |
| `HERMES_DASHBOARD_OIDC_ISSUER` | `https://alekseev.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<app-id>` | compose | non-secret; filled once the SaaS app exists |
| `HERMES_DASHBOARD_OIDC_CLIENT_ID` | `<app-id>` | compose | non-secret; == the SaaS app id |
| `HERMES_DASHBOARD_OIDC_SCOPES` | `openid profile email` | compose | default; may omit |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` | `${…}` | **`/opt/data/.env`** | gateway-only secret (confidential client) |
| ~~`HERMES_DASHBOARD_BASIC_AUTH_USERNAME`~~ | — | — | **removed** |
| ~~`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`~~ | — | — | **removed** (was `.env`) |
| ~~`HERMES_DASHBOARD_BASIC_AUTH_SECRET`~~ | — | — | **removed** (was `.env`) |

- **NEVER** set `HERMES_DASHBOARD_INSECURE` (no-op today, but keep it absent).
- Do **not** set `HERMES_DASHBOARD_OAUTH_CLIENT_ID` (that selects the wrong `nous` provider).

### 4.2 `cloudflared` ingress
Drop the `access:` block for the dashboard host only; keep the route. `hermes` and `hermes-browser` keep their `access:` blocks unchanged.

```yaml
- hostname: hermes-dashboard.alekseev.us
  service: http://hermes-gateway:9119
  # OIDC-only: the dashboard's own Cloudflare-Access-OIDC gate is the sole auth. No edge Access.
```

### 4.3 Header comment block
Update the top-of-file `/opt/data/.env` documentation: remove `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`/`_SECRET`; add `HERMES_DASHBOARD_OIDC_CLIENT_SECRET`.

## 5. Secrets delta (two-tier model unchanged)

| Secret | Used by | Change |
|---|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` (`.env`) | dashboard basic-auth | **removed** |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (`.env`) | dashboard token-signing | **removed** |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` (`.env`) | dashboard OIDC (confidential client) | **new** — from the Access SaaS-OIDC app |
| `HERMES_DASHBOARD_OIDC_ISSUER` / `_CLIENT_ID` | dashboard OIDC | **new, non-secret** — inline in compose |

## 6. Host-side migration (operator on `silverstone` / Cloudflare — assistant cannot reach these)

1. **Create a Generic OIDC SaaS app** in Cloudflare Access:
   - Redirect URL: `https://hermes-dashboard.alekseev.us/auth/callback`
   - Scopes: `openid`, `email`, `profile`
   - Grant: Authorization Code; **PKCE enabled** (the RP always sends S256 — see risk §10)
   - Attach an Access **policy** allowing your identity (email).
   - Record: `app-id` (= `client_id`), `client_secret`, and the issuer URL (verify the exact shape from the app's OIDC metadata).
2. **Remove** `hermes-dashboard.alekseev.us` from the existing self-hosted Access app (leave `hermes` + `hermes-browser`).
3. **`/opt/data/.env`:** drop the two basic-auth secrets; add `HERMES_DASHBOARD_OIDC_CLIENT_SECRET`.
4. Finalize `stacks/hermes.yaml` with the real `app-id` in the issuer/client_id, redeploy, smoke-test (§11).

**Safe cutover order (avoid lockout):** deploy the stack (origin JWT validation now off for this host) and configure OIDC end-to-end **first**; verify login works; **then** remove the host from the edge Access app. While the edge app still covers the host during transition, the OIDC redirect to `cloudflareaccess.com` still works — it just adds a (harmless) second login until step 2.

## 7. Alternatives considered & rejected

| Alternative | Verdict | Why |
|---|---|---|
| **`oauth2-proxy` sidecar** | rejected | Redundant given native OIDC; to feed the OIDC-incapable path it would inject upstream basic-auth — reintroducing a shared machine secret and logging a generic identity. Strictly worse on both goals. |
| **Custom trusted-header plugin** | rejected | Would consume `Cf-Access-Authenticated-User-Email` (zero redundant hop) but requires maintaining custom Python in a security-critical auth path, re-verified on every image bump. Over-engineering for one operator. |
| **`drain` bearer as *human* auth** | rejected | **Source-verified impossible.** `drain` is `supports_token=True, supports_session=False`: a static shared secret (`HERMES_DASHBOARD_DRAIN_SECRET`, `hmac.compare_digest` on the raw `Authorization: Bearer`), mints no session, authorizes only `/api/gateway/drain`, and attaches a **hardcoded** `TokenPrincipal("drain-control")`. A browser can't present it; even if Cloudflare injected it (a real capability via a Transform Rule / Worker post-Access), the human reaches only that one route and is logged as `drain-control`. Fails both goals. Available only as complementary automation (§9). |
| **`nous` provider** | rejected | Authenticates against NousResearch's own portal — the wrong IdP; you want Cloudflare Access. |

## 8. Optional (NOT chosen) — keep edge Access as defense-in-depth

If, on review, you prefer belt-and-suspenders on this full machine-control surface, keep the current arrangement instead of the removals in §4.2 and §6 (step 2):
- Leave `hermes-dashboard.alekseev.us` in the self-hosted Access app and keep its `access:` block in the `cloudflared` ingress (edge login + origin JWT validation).
- Add the dashboard OIDC on top. Result: one visible edge login; the OIDC hop is then usually **SSO-silent** (you already hold a `CF_Authorization` session). Pre-auth dashboard routes stay unreachable without an Access session.
- Cost: two Access objects to maintain and one redundant (silent) hop. No `/auth/callback` bypass is needed because edge auth precedes the OIDC round-trip.

## 9. Optional (NOT included — YAGNI) — `drain` bearer for automation

`drain` **coexists** with `self_hosted` OIDC by design (name-keyed provider registry; session vs. token providers stack disjointly). If non-interactive automation ever needs to hit `POST /api/gateway/drain`, add — alongside OIDC, not instead of it:
- `HERMES_DASHBOARD_DRAIN_SECRET` (≥ 256-bit random; provider fail-closes on weaker) in `/opt/data/.env`.
- Callers send `Authorization: Bearer <secret>`; humans continue to use OIDC.

## 10. Risks / validate-at-deploy

- **⚠️ Pinned-image gate (biggest blocker):** the source was read from `main` @ 2026-07-03; the stack is pinned to the tag **`nousresearch/hermes-agent:v2026.7.1`**. Confirm the `self_hosted` provider and `HERMES_DASHBOARD_OIDC_*` env vars exist in *that* build before relying on it (e.g. `docker run --rm nousresearch/hermes-agent:v2026.7.1 sh -c 'ls plugins/dashboard_auth/ && env | grep -i oidc'`, or inspect the auth plugin dir). A July-2026 tag very likely includes both the OIDC provider and the June-2026 `INSECURE` hardening — but verify. If absent, bump the image first.
- **Provider disambiguation:** confirm that setting `OIDC_ISSUER` + `OIDC_CLIENT_ID` (and *not* the `nous` `OAUTH_CLIENT_ID`) selects `self_hosted`; if the build requires it, also set `dashboard.oauth.provider: self-hosted` in `config.yaml` on `/opt/data`.
- **PKCE parity:** ensure PKCE is enabled on the Access SaaS app — the RP always sends S256; a mismatch yields the classic `ERR_TOO_MANY_REDIRECTS`.
- **Egress:** `hermes-gateway` must reach `cloudflareaccess.com` for discovery/token/JWKS (it already reaches `api.anthropic.com`, so egress exists — verify no policy blocks it).
- **`email` claim:** confirm the Access SaaS app releases `email` (scope `email`) so the dashboard maps identity correctly.
- **Confidential client:** the pinned build must honor `client_secret`; if it rejects it (doc-drift risk), fall back to a **public** client (PKCE-only, omit the secret).
- **Break-glass / lockout:** the dashboard fails closed; a bad OIDC config locks you out. Recovery = temporarily re-add `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD`/`_SECRET` in Portainer and redeploy.
- **Reduced defense-in-depth (accepted trade-off of OIDC-only):** the dashboard's pre-auth login/callback routes become internet-reachable through the tunnel (still fail-closed). §8 is the mitigation if this is reconsidered.
- **Callback path:** confirm the callback is exactly `/auth/callback` on the pinned image.

## 11. Testing & validation

1. **Static:** `./scripts/validate-stack.sh hermes` (compose parse; unset `${VAR}` warnings expected).
2. **Provider check:** after deploy, `GET http://<host>:9119/api/status` (or equivalent) reports OIDC/self-hosted as the active provider — no `basic`.
3. **Interactive login:** visit `hermes-dashboard.alekseev.us` unauthenticated → redirect to the Access OIDC authorize endpoint → Access login → back to `/auth/callback` → dashboard loads. **No basic-auth prompt anywhere.**
4. **Identity:** the dashboard session/logs show your real email (from `email`/`sub`), not `admin`/`drain-control`.
5. **Regression:** `hermes` and `hermes-browser` still gated by the edge Access app; chat + browser paths unaffected.
6. **Break-glass rehearsal (optional):** confirm the documented basic-auth re-add path restores access.

## 12. Decisions — user-confirmed 2026-07-05

- **(a) Inline vs Portainer for non-secret OIDC ids:** **inline in compose** (`issuer`, `client_id`), matching the hardcoded tunnel UUID convention. ✅ confirmed.
- **(b) Edge posture:** **OIDC-only** (edge Access dropped for the dashboard host). ✅ confirmed. §8 remains the documented opt-in if defense-in-depth is ever wanted.
- **(c) `drain` automation:** **excluded (YAGNI)**; §9 documents adding it later. ✅ confirmed (no objection raised).
