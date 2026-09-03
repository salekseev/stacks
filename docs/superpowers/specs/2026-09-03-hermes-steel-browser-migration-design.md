# Hermes Camofox → Steel Browser Migration — Design Spec

- **Date:** 2026-09-03
- **Status:** Approved 2026-09-03 — design agreed; ready for implementation planning.
- **Stack file:** `stacks/hermes.yaml` (new `steel-browser` service, `hermes-gateway` env, `cloudflared` ingress)
- **Author:** brainstormed with Claude Code
- **Supersedes (browser engine + remote-login handoff):** the `camofox` sections of
  `2026-06-30-hermes-stealth-browser-stack-design.md`. Camofox stays deployed through the parallel
  phase; a follow-up PR removes it.
- **Related:** `stacks/hermes.yaml` camofox reaper hardening (branch `fix/hermes-camofox-session-hardening`)
  keeps camofox usable during the parallel phase and is a prerequisite for nothing here.

---

## 1. Goal

Replace the camofox sidecar with self-hosted [steel-browser](https://github.com/steel-dev/steel-browser)
as the Hermes agent's browser backend, because the camofox integration is fragile in two specific ways
the operator hits repeatedly:

1. **Sessions die mid-task.** Three independent reapers close the browser context out from under a
   running task (documented in the superseded spec's "session survival" table).
2. **The noVNC login-handoff is unreliable by construction.** `POST /sessions/:userId/toggle-display`
   starts a viewer only when the userId has exactly one session, and always invalidates open tabs when
   a session exists.

Steel replaces both mechanisms with a single long-lived Chrome plus a built-in interactive viewer.

## 2. Non-goals

- Not building a custom container image — the stack keeps using pinned upstream images.
- Not using Steel's cloud (`api.steel.dev`). Fully self-hosted; no `STEEL_API_KEY`.
- Not publishing any browser/CDP port on the host. Only `cloudflared` reaches origins.
- Not installing the [`hermes-steel`](https://github.com/steel-dev/hermes-steel) plugin — see §9.1.
- Not solving concurrent multi-profile browsing. Self-hosted Steel is single-session by design (§10.2).
- Not removing camofox in this change. That is a follow-up once browsing and a login handoff are
  verified against real sites (§8.3).

## 3. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Browser backend | **self-hosted steel-browser**, Apache-2.0 | Batteries-included Chrome sandbox with a REST API, a persistent-profile mode, and an interactive live viewer. Actively developed. |
| Hermes wiring | **native CDP override** (`BROWSER_CDP_URL`), not the `hermes-steel` plugin | The plugin derives its CDP URL from Steel's `DOMAIN`-built `websocketUrl`, which collides with the operator-facing viewer URL built from the same variable. See §9.1. |
| Container count | **one** (`steel-browser`) | The api image bakes the dashboard at `/ui` (`Dockerfile:113-114`, built `--base=/ui` with `VITE_API_URL=""` at `Dockerfile:33`). The upstream two-service compose predates this and breaks the viewer behind a single hostname. See §9.2. |
| Service name | **`steel-browser`** | One container serves API + dashboard + viewer; calling it `api` would misdescribe it. Matches the repo's plain-name style (`camofox`, `open-webui`). |
| `DOMAIN` value | **`hermes-steel.alekseev.us`** + `USE_SSL=true` | `DOMAIN` only shapes URLs Steel *advertises*; with the plugin gone its sole audience is the operator's browser, which reaches Steel over https through the tunnel. |
| Gateway → Steel path | **`ws://steel-browser:3000/`** on `hermes-net` | Container-to-container, plaintext, no Access, independent of `DOMAIN`. |
| Stealth posture | `CHROME_HEADLESS=false` (headed in Xvfb), fingerprint injection left **on** | Matches the changedetection `--headless=false` lesson already recorded in this repo. `SKIP_FINGERPRINT_INJECTION` stays at its `false` default. |
| Login persistence | **`CHROME_USER_DATA_DIR` on a bind mount** | One on-disk Chrome profile shared by every session; human logs in once via the viewer. See §7. |
| Image pinning | `:latest`, digest-pinned by Renovate | Both Steel images publish **only** `latest` (verified against the ghcr tag list). `renovate.json` already has a `matchCurrentValue: "/^(latest\|plexpass)$/i"` + `pinDigests: true` rule, so no Renovate change is needed. Current digests: api `sha256:f9a4648883dc06c402f5ffbec1c906bf9a803b5b737a1347de4e0aa0ca8d944a`, ui `sha256:bcc45ea21949081b25661be6223a0d226b9362ff334b94cca681843bc46ca122`. |
| Cutover | **parallel, then remove camofox** | Rollback is removing one env var; camofox stays running and untouched. |

## 4. Architecture

```
                              Internet
                                 │
                        Cloudflare Access (one app, team alekseev)
                                 │
                          cloudflared (tunnel sidecar)
        ┌────────────────┬───────────────────┬──────────────────────┐
        ▼                ▼                   ▼                      ▼
 hermes.alekseev.us  hermes-dashboard.  hermes-browser.      hermes-steel.alekseev.us   ← new
        │            alekseev.us        alekseev.us                  │
        ▼                ▼                   ▼                      ▼
  open-webui:8080   hermes-gateway:9119   camofox:6080        steel-browser:3000
                          │                                    ├── /v1/sessions/debug   interactive viewer
                          │                                    ├── /ui                  dashboard (baked in)
                          │                                    └── /v1/...              REST API
                          │
                          └── BROWSER_CDP_URL=ws://steel-browser:3000/ ──► steel-browser
                                 (hermes-net, plaintext, no Access)
```

**Control / data flow**

1. **Agent browsing.** `BROWSER_CDP_URL` makes Hermes' browser tools drive the CDP endpoint directly.
   A websocket upgrade on `:3000` that matches no named handler falls through to
   `cdpService.proxyWebSocket()` (`api/src/plugins/browser-socket/browser-socket.ts:62-67`), so `/`
   is a browser-level CDP endpoint. Chrome is launched eagerly at boot via the `onListen` hook
   (`api/src/plugins/browser.ts:71-73`), so this works before any session is created.
2. **Operator login handoff.** Operator opens `https://hermes-steel.alekseev.us/v1/sessions/debug?interactive=true`
   → Cloudflare Access → `steel-browser:3000`. The page forwards real `Input.dispatchMouseEvent` /
   `Input.dispatchKeyEvent` to CDP (`api/src/plugins/browser-socket/casting.handler.ts:301-316`).
3. **Persistence.** Cookies/localStorage land in `CHROME_USER_DATA_DIR` on the bind mount and are
   reused by every later session (§7).

### 4.1 Why `DOMAIN` is load-bearing

Steel builds advertised URLs from `DOMAIN` (`api/src/utils/url.ts:17-21`), not from the request:

| Response field | Built as | Audience |
|---|---|---|
| `websocketUrl` | `ws://$DOMAIN/` (`session.service.ts:42`) | CDP clients — **unused in this design** |
| `debugUrl` | `http://$DOMAIN/v1/sessions/debug` (`session.service.ts:43`) | Operator; the dashboard iframes it (`ui/src/components/sessions/session-viewer/session-viewer.tsx:186`) |
| viewer's cast socket | `ws://$DOMAIN/v1/sessions/cast` (`sessions.controller.ts:152`) | Operator's browser |
| `debuggerUrl` | `CDP_DOMAIN ?? DOMAIN` (`cdp.service.ts:255`) | Operator (raw DevTools) |

`USE_SSL` is cosmetic — it only selects `https`/`wss` when composing those strings
(`api/src/utils/url.ts:9`). Fastify still listens plaintext (`api/src/index.ts:13` passes no `https`
option); cloudflared terminates TLS. It must nevertheless be `true`: the viewer page is served over
https, and a `ws://` socket from an https origin is blocked as mixed content.

**Invariant to preserve:** `DOMAIN` must be the public tunnel hostname and `USE_SSL` must be `true`.
Setting `DOMAIN` to an internal name breaks the viewer and the dashboard iframe; dropping `USE_SSL`
breaks the viewer's websocket. Both fail silently from the API's point of view.

## 5. Component specifications

### 5.1 `steel-browser` (new)

- **Image:** `ghcr.io/steel-dev/steel-browser-api:latest` (digest pinned by Renovate).
- **Role:** Chrome sandbox + REST API + `/ui` dashboard + interactive viewer, all on `:3000`.
- **Ports (internal only):** `3000` REST/CDP/UI/viewer; `9223` raw CDP redirect (nginx → Chrome
  `:9222`, `nginx.conf`) — **not used by this design**, see §5.1.1.
- **Environment:**

  | Var | Value | Notes |
  |---|---|---|
  | `DOMAIN` | `hermes-steel.alekseev.us` | Operator-facing; see §4.1. |
  | `USE_SSL` | `true` | Required, or the viewer's websocket is mixed-content-blocked. |
  | `CDP_DOMAIN` | `hermes-steel.alekseev.us` | Only shapes `debuggerUrl` (`cdp.service.ts:255`). |
  | `CHROME_HEADLESS` | `false` | Headed inside Xvfb (`DISPLAY` defaults to `:10`, `api/src/env.ts:33`). Upstream default is `true`. |
  | `CHROME_USER_DATA_DIR` | `/data/profile` | Persistent shared profile (§7). |
  | `LOG_STORAGE_ENABLED` | `true` | Matches upstream compose. |
  | `LOG_STORAGE_PATH` | `/data/logs/browser-logs.duckdb` | On the bind mount so logs survive restarts. |

- **Volume:** `/mnt/spool/apps/data/hermes/steel:/data`.
- **Healthcheck:** `GET http://localhost:3000/health` (`api/src/modules/sessions/sessions.routes.ts:25`),
  probed with `node -e` to match the camofox healthcheck idiom (the image ships Node).
- **Network:** `hermes-net`.

#### 5.1.1 Why `:3000/` and not `:9223`

Chrome is launched with `--remote-debugging-address=0.0.0.0 --remote-debugging-port=9222` and
`--remote-allow-origins=*` (`cdp.service.ts:859`, `:916-917`), and `nginx.conf` republishes `9222`
on `9223` with `proxy_set_header Host $host`. Chrome's DevTools HTTP endpoint validates the `Host`
header, so a `Host: steel-browser:9223` request risks rejection. Steel's own fastify proxy on `:3000`
has no such issue: it dials Chrome over loopback itself. Using `:3000/` also means the URL survives a
Chrome relaunch, because each upgrade is proxied to whichever Chrome is currently live — unlike a
`ws://…/devtools/browser/<uuid>` URL, which is invalidated by a relaunch (§10.4).

### 5.2 `hermes-gateway` (modified)

One added env var:

```yaml
- BROWSER_CDP_URL=ws://steel-browser:3000/
```

- `BROWSER_CDP_URL` is the highest-precedence CDP source (`tools/browser_tool.py:_get_cdp_override_raw`,
  ahead of `browser.cdp_url` in `config.yaml`), so **no `config.yaml` edit is required** — the whole
  switch lives in the compose file.
- A CDP override **outranks camofox**: `is_camofox_mode()` returns False whenever one is active
  (`tools/browser_camofox.py:115-127`). All `CAMOFOX_*` vars can stay in place during the parallel
  phase; they are simply shadowed.
- **The trailing slash is load-bearing.** `_resolve_cdp_override` (`tools/browser_tool.py:499-527`)
  treats a bare `ws://host:port` as a discovery endpoint and probes `/json/version` — which Steel's
  fastify does not serve, costing a failed request and a warning on every session. With the trailing
  slash the value is returned as-is, unprobed.
- `depends_on: steel-browser: condition: service_healthy` is added.

Gateway env that stays untouched this change: every `CAMOFOX_*` var.

### 5.3 `cloudflared` (modified)

A fourth ingress rule, with the same `teamName` / `audTag` as `hermes.alekseev.us` and
`hermes-browser.alekseev.us`:

```yaml
- hostname: hermes-steel.alekseev.us
  service: http://steel-browser:3000
  access:
    required: true
    teamName: alekseev
    audTag:
      - f79eba4208644c03e8777ab7870842bc46887458b09d3ad19e74570b119bc37d
```

Websockets pass through cloudflared unmodified, which the viewer's cast socket and the dashboard's
`/ws/` calls both need.

### 5.4 External prerequisites (operator, out of band)

1. DNS `CNAME hermes-steel` → the tunnel (`0a0fe09f-7724-4e7e-9ad8-0326b70fa07f.cfargotunnel.com`).
2. Add `hermes-steel.alekseev.us` to the existing Cloudflare Access application.
3. `mkdir -p /mnt/spool/apps/data/hermes/steel` on the Docker host.

The stack cannot be verified end-to-end until 1 and 2 are done.

## 6. Login-handoff runbook

Replaces the camofox `toggle-display` procedure entirely.

1. Open `https://hermes-steel.alekseev.us/v1/sessions/debug?interactive=true` (Access-gated).
2. Click and type in the page — real input events reach Chrome over CDP. Log in, solve MFA.
3. Done. Cookies persist to `/data/profile`; the agent's next browse reuses them.

Notable absences compared with camofox: no session-count precondition, no context restart, no tab
invalidation, no `x11vnc`/`websockify`, no on-demand toggle, and the viewer is reachable **before**
any agent activity because Chrome launches at boot.

Supporting views: the dashboard at `https://hermes-steel.alekseev.us/ui` (session list, logs, replay)
and raw DevTools via `debuggerUrl`.

## 7. Persistence model

`session.service.ts:181-183` resolves the profile directory as: an explicit `userDataDir`/`persist`
request wins, otherwise `env.CHROME_USER_DATA_DIR`, otherwise a temp dir. In CDP-direct mode nothing
creates sessions through the REST API, so `CHROME_USER_DATA_DIR=/data/profile` always applies — one
durable profile on the bind mount, shared by the operator's login and the agent's browsing.

`GET /v1/sessions/:sessionId/context` (`sessions.routes.ts:94`) remains available as a manual
cookie/localStorage export if the profile ever needs to be rebuilt.

## 8. Cutover plan

### 8.1 Deploy (parallel phase)

1. Create the host directory; add DNS + Access (§5.4).
2. Add the `steel-browser` service and the cloudflared ingress; redeploy. Camofox untouched.
3. Verify `/health` is 200 and the container is healthy.
4. Open the viewer; confirm an interactive page (mouse and keyboard both land).

### 8.2 Switch the agent

5. Add `BROWSER_CDP_URL=ws://steel-browser:3000/` to `hermes-gateway`; recreate the gateway.
6. Verify in the gateway log that `_browser_cdp_check` and `_browser_dialog_check` no longer report
   `returned False` (they are gated on a reachable CDP endpoint).
7. Ask the agent to browse a real page; confirm rendered content.
8. Do a login handoff on a real site, then confirm the agent inherits the authenticated session.

**Rollback:** remove `BROWSER_CDP_URL` and recreate the gateway. Camofox resumes immediately —
`is_camofox_mode()` goes back to True with no other change.

### 8.3 Follow-up PR (after verification)

Remove the `camofox` service, its `CAMOFOX_*` gateway vars, the `hermes-browser.alekseev.us` ingress,
and (once the profile is known unneeded) the camofox data directory. Retire the camofox sections of
the superseded spec.

## 9. Rejected alternatives

### 9.1 The `hermes-steel` plugin

`steel-dev/hermes-steel` (MIT, v1.0.0) is a legitimate Hermes browser provider and explicitly
supports self-hosting: with `STEEL_BASE_URL` set, `STEEL_API_KEY` becomes optional and no credentials
are sent (`config.py:steel_api_key`, `custom_base_url`). It was rejected for one blocking reason plus
three that make the loss cheap.

**Blocking:** the plugin dials the CDP URL that Steel returns — `websocketUrl`, built from `DOMAIN`
(`provider.py:322` → `_normalize_cdp_url`) — and exposes no override. Its entire env surface is
`STEEL_API_KEY`, `STEEL_BASE_URL`, `STEEL_SESSION_TIMEOUT`, `STEEL_USE_PROXY`, `STEEL_SOLVE_CAPTCHA`;
`STEEL_BASE_URL` only says where to POST the session. So `DOMAIN` must be internal for the plugin
(breaking the operator's viewer and the dashboard iframe) or public for the operator (handing the
gateway a `wss://` URL that hairpins out through Cloudflare into an Access-gated hostname a CDP
handshake cannot authenticate to, against a plaintext origin).

**Cheap losses:**

- `STEEL_USE_PROXY` / `STEEL_SOLVE_CAPTCHA` send `useProxy` / `solveCaptcha`, which are Steel **cloud**
  features. Self-hosted proxying needs a concrete `proxyUrl` (`sessions.schema.ts` `CreateSession`),
  which the plugin never sends. Both knobs are inert here.
- Per-task session create/release is actively harmful: since
  [PR #186](https://github.com/steel-dev/steel-browser/pull/186) removed `clearBrowserState`, ending a
  session does a full Chrome shutdown and relaunch to defaults (`cdp.service.ts:1379-1390`). Every
  task would bounce the browser, churning against the persistent-profile handoff.
- `steel_scrape` (one-shot extraction) is the one real loss; `web_extract` covers most of it.

**Gained by going CDP-direct:** `browser_cdp` (raw protocol passthrough), `browser_dialog` (native
dialog handling), and the snapshot `frame_tree`. All three are unavailable on camofox and on every
cloud provider; the gateway log confirms they are off today (`_browser_cdp_check returned False`,
`_browser_dialog_check returned False`).

**Re-evaluate if** Steel derives its base URL from the request instead of `DOMAIN` — `trustProxy: true`
is already set (`api/src/index.ts:15`), so honoring `Host`/`X-Forwarded-Host` is a small upstream
patch. If that lands, adopting the plugin is: drop `BROWSER_CDP_URL`, set `STEEL_BASE_URL` and
`browser.cloud_provider: steel`. Worth filing upstream.

### 9.2 Upstream's two-container compose (`api` + `ui`)

Rejected as legacy. Upstream's own
[PR #186](https://github.com/steel-dev/steel-browser/pull/186) (2025-09-18) states: *"Currently we
have two separate apps for both UI and API however this isn't necessary in production as the UI is
just a static build … once we settle on this approach we can remove the existing Dockerfiles."* The
two-service `docker-compose.yml` predates it and has only had env/logging touch-ups since;
`docker-compose.dev.yml` is where the split earns its keep (Vite hot reload).

It also **breaks the viewer** behind one hostname: `debugUrl` is absolute from `DOMAIN`, so the
dashboard iframes `https://<host>/v1/sessions/debug`, but the ui container's nginx proxies only
`/api/` and `/ws/` (`ui/nginx.conf.template`) — no `/v1/` location, so the iframe 404s. Setting
`DOMAIN=<host>/api` makes the page load but moves its cast socket to `wss://<host>/api/v1/sessions/cast`,
and only the `/ws/` location carries `Upgrade`/`Connection` headers, so the socket fails. Fixing it
means hand-patching their nginx template.

### 9.3 TLS sidecar to keep the plugin

`DOMAIN` public + `USE_SSL=true`, plus an nginx sidecar holding a Cloudflare Origin certificate and a
docker network alias for `hermes-steel.alekseev.us`, so the gateway speaks `wss` internally — with the
CF Origin CA mounted into the gateway and `NODE_EXTRA_CA_CERTS` set. Works, but adds a container, a
certificate, and a trust-store coupling to buy back features that are inert self-hosted (§9.1).

### 9.4 Multiple Steel replicas for concurrency

`hermes-steel`/`BROWSER_CDP_URL` both take a single endpoint, so this needs a router plus per-replica
`DOMAIN`/`CDP_DOMAIN` so advertised URLs stay correct. Rejected against a single-operator workload.

### 9.5 Keeping camofox as a plugin-only fallback

`Koumi460/hermes-plugin-camofox` adds camofox tools without overriding the default browser tools,
which would keep Camoufox available for Chromium-blocked sites. Deferred, not rejected: it can be
added later without touching this design. Revisit if §10.1 bites.

## 10. Risks and known regressions

### 10.1 Weaker stealth ceiling

Camoufox is Firefox patched at the C++ level; Steel is Chromium plus fingerprint injection. On hard
anti-bot targets Steel is likely weaker. Mitigations in this design: headed-in-Xvfb
(`CHROME_HEADLESS=false`) and fingerprint injection left enabled. This is the main reason camofox
stays deployed until real sites are tested (§8.3), and the reason §9.5 stays on the table.

### 10.2 One shared browser, globally

`session.service.ts:67` holds a single `public activeSession`, and in CDP-direct mode every task
drives the same Chrome and the same profile. Two concurrent browsing tasks interleave on one browser
rather than getting isolated contexts. Accepted for a single-operator stack; note that kanban
dispatch already throttles workers.

### 10.3 Runs as root; profile files root-owned

Steel's `Dockerfile` sets no `USER`, so `/mnt/spool/apps/data/hermes/steel` will be root-owned
(camofox wrote as uid 1000). No `HERMES_UID`-style remap exists.

### 10.4 Chrome relaunch drops live CDP sockets

Any full session teardown shuts Chrome down and relaunches it (§9.1). Nothing in this design triggers
that, but an operator calling `POST /v1/sessions/release` — or the dashboard's release button — will
kill the agent's in-flight browser work. The `ws://steel-browser:3000/` form means the *next* connect
recovers automatically.

### 10.5 Cookie durability on unclean shutdown

Chrome flushes cookies to the profile on graceful shutdown. A `docker kill` shortly after a login
handoff can lose the newest cookie writes; redo the handoff if a session looks unauthenticated.

### 10.6 Mutable upstream tags

Steel publishes only `latest`. Renovate digest-pinning covers reproducibility, but upstream can ship
breaking changes under the same tag between pins; `v0.5.4-beta` is also still beta.

## 11. Open follow-ups

1. Remove camofox (§8.3).
2. File the `Host`/`X-Forwarded-Host` base-URL patch upstream; adopt `hermes-steel` if it merges (§9.1).
3. Consider `hermes-plugin-camofox` as a stealth fallback if §10.1 bites (§9.5).
4. Revisit pinning if Steel starts publishing version tags (§10.6).

## 12. Appendix — target compose stanzas

```yaml
  steel-browser:
    restart: unless-stopped
    # Self-hosted Steel: Chrome sandbox + REST API + baked-in dashboard (/ui) + interactive
    # viewer (/v1/sessions/debug), all on :3000. Replaces the camofox sidecar; see
    # docs/superpowers/specs/2026-09-03-hermes-steel-browser-migration-design.md
    image: ghcr.io/steel-dev/steel-browser-api:latest
    container_name: steel-browser
    hostname: steel-browser
    environment:
      # DOMAIN/USE_SSL shape only the URLs Steel ADVERTISES (debugUrl, the /ui iframe src, and the
      # viewer's cast websocket) — never what it listens on. Their sole audience is the operator's
      # browser, which arrives over https through cloudflared, so DOMAIN must be the public hostname
      # and USE_SSL must be true (an https page cannot open a ws:// socket). The gateway does NOT use
      # these: it dials ws://steel-browser:3000/ over hermes-net. Do not "fix" DOMAIN to an internal
      # name — the viewer and dashboard break silently.
      - DOMAIN=hermes-steel.alekseev.us
      - USE_SSL=true
      - CDP_DOMAIN=hermes-steel.alekseev.us
      # Headed inside the image's Xvfb (DISPLAY=:10) — stronger anti-detect than true headless,
      # same lesson as changedetection's --headless=false. Upstream default is true.
      - CHROME_HEADLESS=false
      # One persistent on-disk Chrome profile shared by the operator's login and the agent's
      # browsing. Applies because nothing here passes userDataDir/persist per session.
      - CHROME_USER_DATA_DIR=/data/profile
      - LOG_STORAGE_ENABLED=true
      - LOG_STORAGE_PATH=/data/logs/browser-logs.duckdb
    volumes:
      - /mnt/spool/apps/data/hermes/steel:/data
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:3000/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    networks:
      - hermes-net
```

Gateway addition:

```yaml
      # Steel Browser over CDP, straight across hermes-net. A CDP override outranks camofox, so the
      # CAMOFOX_* vars above are shadowed while this is set — remove this one line to roll back.
      # The trailing slash matters: without it Hermes treats the value as a discovery endpoint and
      # probes /json/version (which Steel does not serve) on every session.
      - BROWSER_CDP_URL=ws://steel-browser:3000/
```

Operator quick reference:

```sh
# Health
curl -s http://localhost:3000/health

# Interactive viewer (through the tunnel, Access-gated)
https://hermes-steel.alekseev.us/v1/sessions/debug?interactive=true

# Dashboard
https://hermes-steel.alekseev.us/ui

# Export the logged-in context as a backup
curl -s https://hermes-steel.alekseev.us/v1/sessions/<sessionId>/context
```
