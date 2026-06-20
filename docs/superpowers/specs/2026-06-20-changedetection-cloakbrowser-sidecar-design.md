# changedetection: Move CloakBrowser to a maintained `cloakserve` sidecar

**Date:** 2026-06-20
**Stack:** `stacks/changedetection.yaml`
**Status:** Design approved, pending implementation plan
**Supersedes (in part):** `2026-06-19-changedetection-cloakbrowser-design.md` (in-container plugin)

## Context — where we are now

The in-container plugin approach (`2026-06-19` design) was implemented and **works**, but only after two follow-up fixes:

- The slim `python:3.11-slim-bookworm` base image ships no browser system libraries, so the CloakBrowser Chromium binary died with `libatk-1.0.so.0: cannot open shared object file`. `EXTRA_PACKAGES` is pip-only, so the fix was an `entrypoint:` wrapper that `apt-get install`s ~16 Chromium libs at boot (commits `811f037`, `954df5c`).
- The result is functional but carries an **apt-install-at-boot hack**, a `~200 MB` binary download into `/datastore/cloakbrowser-cache`, and a non-stock changedetection container.

In live use, watches launch the browser successfully but hit Cloudflare's interactive "Verify you are human" interstitial on at least one target (`home-barista.com/buysell`), from a home residential IP.

The user wants **both**: (a) a cleaner, maintained setup off the apt hack, and (b) better Cloudflare results.

## Goal

Replace the in-container CloakBrowser plugin with the maintained `cloakhq/cloakbrowser` image running in **CDP server mode** (`cloakserve`) as a sidecar, and revert the `changedetection` container to a stock image that connects to it over the internal Docker network via its built-in Playwright fetcher.

## The honest "Both" scorecard

| Axis | Outcome |
|------|---------|
| **Cleaner / maintained** | **Fully delivered.** changedetection returns to a stock image: no `EXTRA_PACKAGES`, no apt-install entrypoint, no `CLOAKBROWSER_*` vars, no binary in `/datastore`. Chromium is baked into the maintained image. |
| **Beat Cloudflare** | **Partial, with new levers.** Gains: **headed mode via Xvfb** (`--headless=false`; upstream notes "some sites detect headless even with C++ patches") and a **fixed fingerprint seed** = "returning visitor" identity (upstream-recommended for repeated hits to one site from one IP). Loses: `humanize` (a wrapper feature that does **not** apply over CDP; the C++ fingerprint patches still do). Unchanged: each check uses a fresh browser context, so `cf_clearance` does not persist between checks. |

## Verified facts (from source/docs research)

- changedetection's built-in Playwright fetcher connects with `browser_type.connect_over_cdp(self.browser_connection_url, timeout=60000)` at `changedetectionio/content_fetchers/playwright.py:278`, where `browser_connection_url = os.getenv("PLAYWRIGHT_DRIVER_URL", 'ws://playwright-chrome:3000')`. So pointing `PLAYWRIGHT_DRIVER_URL` at a CDP endpoint is the supported path.
- `cloakhq/cloakbrowser` ships a `cloakserve` CLI that starts a persistent stealth Chromium exposing **CDP on port 9222**; clients attach via `connect_over_cdp("http://host:9222")`. Official `docker-compose` example provided upstream (with a `curl http://localhost:9222/json/version` healthcheck — `curl` is present in the image).
- `cloakserve` is a **CDP proxy**: it rewrites the discovered `webSocketDebuggerUrl` to point back through itself using the request `Host`, so dialing `http://cloakbrowser:9222` yields `ws://cloakbrowser:9222/devtools/...` (reachable via Docker DNS). Playwright's `connect_over_cdp` independently rewrites the ws host to match the endpoint — belt and suspenders. Source: route table in `bin/cloakserve` `main()` (`/json/version`, `/devtools/{path}`, `/fingerprint/{seed}/devtools/{path}`).
- **WebSocket data plane (source-confirmed):** `handle_ws_default`/`handle_ws_seed` perform a real WS upgrade (`web.WebSocketResponse().prepare(request)`) and `proxy_cdp_websocket()` runs a bidirectional pump to the real Chrome at `ws://127.0.0.1:<cdp_port>/devtools/...`, forwarding TEXT+BINARY both ways with `max_size=None` (no 1 MB frame cap — needed for CDP screenshot/DOM payloads). Not a discovery-only shim; carries full CDP traffic, which is what `connect_over_cdp` requires.
- Inter-container traffic needs **no published port**; `ports:` only maps to the host. 9222 stays internal (CDP = full browser control; upstream warns never to expose it publicly).
- **Binding (source-confirmed):** `bin/cloakserve` `main()` sets `in_container = os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv")` and binds `host = "0.0.0.0" if in_container else "127.0.0.1"`. Docker always creates `/.dockerenv`, so the sidecar listens on `0.0.0.0:9222` and accepts peer-container connections with no flag. (This is *not* inference from the `-p` example.)
- **Origin gate is not a blocker (source-confirmed):** `_origin_is_allowed()` returns `True` when the WebSocket `Origin` header is absent ("Playwright/Puppeteer and other non-browser CDP clients commonly omit Origin"). changedetection's `connect_over_cdp` client omits `Origin`, so it is allowed; the gate only rejects browser-origin CSRF.
- **Fingerprint pinning (source-confirmed, preferred lever):** `parse_cli_args` accepts a server-side default seed via `cloakserve --fingerprint=<seed>` (plus `--fingerprint-locale=`, `--fingerprint-timezone=`). This pins one "returning visitor" identity for every connection **without** depending on changedetection forwarding a query string. Per-connection `connect_over_cdp("http://host:9222?fingerprint=<n>")` also works (the `/json/version?fingerprint=N` discovery maps to the `/fingerprint/N/devtools/...` route), but the server flag is simpler for our single-identity case.
- **Flag syntax (source-confirmed):** defaults are `--port=9222` and `headless=True`; `--headless=false` enables headed mode (rendered to the image's bundled Xvfb) and is passed through to Chrome; `--idle-timeout=<sec>` reaps disconnected per-seed browsers; unknown flags like `--proxy-server=` pass through to Chrome via `build_args()`.

## Architecture

Two services on the stack's default network. changedetection drives CloakBrowser over CDP by service name; port 9222 is never published.

```
changedetection ──HTTP /json/version──▶ cloakbrowser:9222 (cloakserve, headed/Xvfb)
                ◀── ws://cloakbrowser:9222/devtools/... (rewritten by cloakserve)
                ──WebSocket (CDP)──────▶ drives stealth Chromium

PLAYWRIGHT_DRIVER_URL=http://cloakbrowser:9222   (changedetection env)
fetcher per watch: built-in "Playwright Chromium"
```

### Target `stacks/changedetection.yaml`

```yaml
services:

  cloakbrowser:
    image: cloakhq/cloakbrowser
    container_name: cloakbrowser
    hostname: cloakbrowser
    restart: unless-stopped
    command: cloakserve --headless=false --idle-timeout=300
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9222/json/version"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

  changedetection:
    restart: unless-stopped
    image: ghcr.io/dgtlmoon/changedetection.io:0.55.7
    container_name: changedetection
    hostname: changedetection
    depends_on:
      cloakbrowser:
        condition: service_healthy
    volumes:
      - changedetection-data:/datastore
    environment:
      - BASE_URL=https://changedetection.alekseev.us
      - HIDE_REFERER=true
      - FETCH_WORKERS=5
      - MINIMUM_SECONDS_RECHECK_TIME=3
      - ALLOW_FILE_URI=False
      - TZ=America/New_York
      - PLAYWRIGHT_DRIVER_URL=http://cloakbrowser:9222
      - WEBDRIVER_DELAY_BEFORE_CONTENT_READY=10
    ports:
      - 5000:5000/tcp

volumes:
  changedetection-data:
```

Everything from the in-container design is removed: the `entrypoint:` wrapper, `EXTRA_PACKAGES`, `CLOAKBROWSER_BACKEND`, `CLOAKBROWSER_CACHE_DIR`, `CLOAKBROWSER_HUMANIZE`.

## Anti-bot tuning order (apply only if a site still challenges)

1. **Wait** — `WEBDRIVER_DELAY_BEFORE_CONTENT_READY=10` (set above) + per-watch "Wait seconds before extracting text". Lets a managed challenge auto-resolve before capture.
2. **Fixed fingerprint seed** — add `--fingerprint=<n>` to the `cloakserve` command (server-side default identity for every connection). Source-confirmed in `parse_cli_args`; no dependency on changedetection forwarding a query string. (Per-connection `...:9222?fingerprint=<n>` in `PLAYWRIGHT_DRIVER_URL` is an alternative but would need the query-passthrough check.)
3. **Confirm headed helps** — `--headless=false` is the default in this design; toggling to headless is a one-flag comparison if headed proves unstable or unnecessary.

## Testing / verification

Implementation is unverifiable from the dev box (no access to the Portainer host); these run on deploy:

1. **Static:** `./scripts/validate-stack.sh changedetection` and `docker compose -f stacks/changedetection.yaml config`.
2. **Sidecar up:** `cloakbrowser` reaches `healthy` (healthcheck passing).
3. **Cross-container WS reachability (the key check):** from a peer container on the stack network,
   `docker run --rm --network <stack_net> curlimages/curl -s http://cloakbrowser:9222/json/version`
   → confirm `webSocketDebuggerUrl` host is `cloakbrowser:9222` (not `127.0.0.1`/`localhost`).
4. **Integration first:** switch one watch to the **"Playwright Chromium"** fetcher against an easy page; confirm a successful fetch (proves CDP connect works end-to-end) *before* judging Cloudflare.
5. **Cloudflare:** re-check `home-barista.com/buysell`; inspect whether the interstitial clears. Apply the tuning order above as needed.

## Risks & mitigations

- **`webSocketDebuggerUrl` resolves to localhost** → unreachable. Low risk now: source confirms `0.0.0.0` container bind + Host-based rewrite + Playwright's own rewrite. Still cheap to confirm via verification step 3. Fallback: cloakserve forwarded-header flags.
- **Headed mode instability** in server mode → toggle to default headless.
- **Loss of `humanize`** over CDP → accepted; fingerprint patches (the dominant Turnstile signal) still apply; fixed seed compensates.
- **Reintroduces a second container** → accepted; it is a clean, healthchecked, maintained image with no `SYS_ADMIN`/seccomp, so the original OCI error cannot recur.

## Rollback

The working in-container setup is committed (`954df5c`). `git revert`/checkout of `stacks/changedetection.yaml` restores it; no data migration (the `/datastore` volume is untouched).

## Post-deploy manual steps

- Switch each watch from "CloakBrowser - Stealth Chromium" (plugin fetcher, now gone) to **"Playwright Chromium"**.
- Optional cleanup: delete the orphaned `/datastore/cloakbrowser-cache` (~200 MB) from the plugin era. Harmless if left.

## Out of scope

- Outbound residential **proxy** (already on a home residential IP; can be added later via `cloakserve --proxy-server=` with no architectural change).
- `cf_clearance` **cookie persistence** across checks (changedetection creates a fresh context per check; not modifiable here).
