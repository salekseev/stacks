# changedetection: Replace browserless with the CloakBrowser in-container plugin

**Date:** 2026-06-19
**Stack:** `stacks/changedetection.yaml`
**Status:** Design approved, pending implementation plan

## Problem

The `playwright-chrome` browser container (`ghcr.io/browserless/chromium:v2.50.1`) fails to start on the Portainer host with:

```
OCI runtime create failed: runc create failed: unable to start container process:
error during container init: error closing exec fds: get handle to /proc/thread-self/fd:
unsafe procfs detected: openat2 fsmount:fscontext:proc/thread-self/fd/: function not implemented
```

**Root cause:** the service applies a custom seccomp profile (`security_opt: - seccomp:./chrome.json`). That profile blocks the `openat2` syscall, so the host's newer `runc` fails its procfs safety check with `ENOSYS` (`function not implemented`). `SYS_ADMIN` alone is not the trigger — the custom seccomp profile is. This leaves changedetection without a working browser backend.

## Goal

Give the changedetection instance a working, better browser backend with anti-bot capability by adopting CloakBrowser, while eliminating the failing container and the configuration that caused the OCI error.

## Decisions

These were settled during brainstorming:

1. **Integration model: in-container plugin** (`changedetection.io-cloak-browser`), not the separate `sockpuppetbrowser-cloakbrowser` CDP-proxy container. Rationale: no image to build (the sockpuppet repo publishes no prebuilt image), uses the existing changedetection image, and removes the `SYS_ADMIN`/seccomp container so the OCI error cannot recur. Matches the repo's prebuilt-image Portainer workflow.
2. **Retire `playwright-chrome` completely.** CloakBrowser becomes the only browser. The CloakBrowser fetcher is selected per-watch in the UI; watches left on the old websocket-Playwright fetcher will error until switched. This is accepted.
3. **No proxy wired in now.** CloakBrowser still defeats fingerprint/Turnstile/`navigator.webdriver` checks without one. IP-reputation blocks would need a proxy, which can be added later as env vars with no architectural change.
4. **Lower `FETCH_WORKERS` from 10 to 5.** Browser fetches now run as Chromium processes *inside* the changedetection container (~150–300 MB each) rather than in a separate browserless container that capped concurrency at `CONCURRENT=5`. Five keeps in-container memory bounded.
5. **Enable the `patchright` backend.** Install `cloakbrowser[patchright]` alongside the plugin and set `CLOAKBROWSER_BACKEND=patchright` so the automation/driver layer also suppresses CDP detection signals (notably the `Runtime.enable` leak) on top of CloakBrowser's binary-level fingerprint patches. This is *off* the plugin's documented path, so the deploy must verify it loads (see Testing). Fallback: unset `CLOAKBROWSER_BACKEND` to revert to the default backend.

## Verified facts

- Plugin `changedetection.io-cloak-browser` **0.1.1** is on PyPI: `requires-python >=3.10`, deps `changedetection.io>=0.54.6`, `cloakbrowser>=0.3.0`, `playwright>=1.40.0`. The running image is `0.55.7` (satisfies the constraint).
- `cloakbrowser` **0.3.31** is on PyPI.
- The CloakBrowser binary cache location is controlled by the `CLOAKBROWSER_CACHE_DIR` environment variable (confirmed in the upstream sockpuppet Dockerfile, which pre-downloads into it). Pointing it at `/datastore/...` persists the binary in the existing volume.
- `cloakbrowser` exposes a `[patchright]` optional extra that pulls `patchright>=1.40`. `patchright` is a separate PyPI package (**1.60.1**) — an "undetected" patched fork of the Playwright driver. The `CLOAKBROWSER_BACKEND` variable selects the driver layer (`playwright` or `patchright`); `patchright` requires that package to be installed.
- `chrome.json` and the `playwright-chrome` service name are referenced only by `stacks/changedetection.yaml` — nothing else in the repo depends on them, so removing them is safe.

## Design

### Architecture

Single container. The `changedetection` service loads the CloakBrowser fetcher at startup via `EXTRA_PACKAGES` (changedetection's built-in mechanism that `pip install`s extra packages on boot). No separate browser container, no `SYS_ADMIN`, no custom seccomp.

### Changes to `stacks/changedetection.yaml`

On the `changedetection` service:

- **Remove** `PLAYWRIGHT_DRIVER_URL=ws://playwright-chrome:3000` (no websocket browser remains).
- **Remove** the `depends_on: playwright-chrome` block.
- **Change** `FETCH_WORKERS=10` → `FETCH_WORKERS=5`.
- **Add** environment variables:
  - `EXTRA_PACKAGES=changedetection.io-cloak-browser cloakbrowser[patchright]` — installs the plugin **and** the patchright driver extra at container start (space-separated; both passed to `pip install`).
  - `CLOAKBROWSER_BACKEND=patchright` — uses the undetected patchright driver layer.
  - `CLOAKBROWSER_CACHE_DIR=/datastore/cloakbrowser-cache` — persists the ~200 MB binary in the existing `changedetection-data` volume.
  - `CLOAKBROWSER_HUMANIZE=true` — human-like input behavior (plugin default; set explicitly for clarity).

Elsewhere in the file:

- **Delete** the entire `playwright-chrome` service definition.
- **Delete** the commented-out `browser-sockpuppet-chrome` block (dead config).
- **Delete** the orphaned `stacks/chrome.json` file.

The service otherwise keeps: `image: ghcr.io/dgtlmoon/changedetection.io:0.55.7`, the `changedetection-data` volume, `BASE_URL`, `HIDE_REFERER`, `MINIMUM_SECONDS_RECHECK_TIME`, `ALLOW_FILE_URI`, `TZ`, and port `5000`.

### Target compose (illustrative)

```yaml
services:
  changedetection:
    restart: unless-stopped
    image: ghcr.io/dgtlmoon/changedetection.io:0.55.7
    container_name: changedetection
    hostname: changedetection
    volumes:
      - changedetection-data:/datastore
    environment:
      - BASE_URL=https://changedetection.alekseev.us
      - HIDE_REFERER=true
      - FETCH_WORKERS=5
      - MINIMUM_SECONDS_RECHECK_TIME=3
      - ALLOW_FILE_URI=False
      - TZ=America/New_York
      - EXTRA_PACKAGES=changedetection.io-cloak-browser cloakbrowser[patchright]
      - CLOAKBROWSER_BACKEND=patchright
      - CLOAKBROWSER_CACHE_DIR=/datastore/cloakbrowser-cache
      - CLOAKBROWSER_HUMANIZE=true
    ports:
      - 5000:5000/tcp

volumes:
  changedetection-data:
```

## Post-deploy manual steps (UI)

For each watch that should use stealth: **Edit → Fetch tab → "CloakBrowser - Stealth Chromium (anti-bot bypass)"**. The first such fetch downloads the binary to `/datastore/cloakbrowser-cache`.

## Operational notes & risks

- **First-run download:** the proprietary CloakHQ Chromium binary (~200 MB) downloads on the first CloakBrowser fetch into the persisted cache dir; it survives container recreates thereafter.
- **Startup cost:** `EXTRA_PACKAGES` runs `pip install` on every container start, adding boot time and requiring outbound internet at boot.
- **Dependency resolution:** the plugin declares `playwright>=1.40.0` and `changedetection.io>=0.54.6`; both are already present in the `0.55.7` image, so the boot-time install should resolve without upgrading core packages. Watch the first deploy's logs to confirm.
- **Trust/licensing:** CloakBrowser is a closed-source binary downloaded at runtime under the CloakBrowser Binary License. This is inherent to the CloakBrowser approach regardless of integration model.
- **`patchright` backend (off documented path):** enabled per decision 5. Two risks to verify on first deploy:
  - **Bracket globbing:** `EXTRA_PACKAGES` is passed to `pip install`; the value `cloakbrowser[patchright]` contains shell glob characters. If the changedetection startup expands it unquoted and the glob fails to match a file, shells leave it literal (the expected case). If it causes a `pip` error, the equivalent fallback is `EXTRA_PACKAGES=changedetection.io-cloak-browser patchright` (install the package directly).
  - **Backend honored:** the plugin ships only on PyPI (no source in its GitHub repo), so it is unconfirmed that it reads `CLOAKBROWSER_BACKEND` the same way the sockpuppet wrapper does. If the boot log shows a patchright import/backend error, unset `CLOAKBROWSER_BACKEND` to revert to the default backend; CloakBrowser's binary-level patches still apply.

## Testing & validation

- **Static:** `./scripts/validate-stack.sh changedetection` — compose validates with the browser service removed.
- **Runtime (Portainer):**
  1. Redeploy the stack; confirm `changedetection` starts cleanly with no OCI `unsafe procfs` error.
  2. In container logs, confirm both `changedetection.io-cloak-browser` and `patchright` installed (no `pip` failure / no bracket-glob error).
  3. Confirm the patchright backend initializes (no `CLOAKBROWSER_BACKEND`/patchright import error in logs). If it errors, apply the fallback (unset `CLOAKBROWSER_BACKEND`).
  4. Set one watch to the CloakBrowser fetcher and trigger a recheck; confirm a successful fetch.
  5. Confirm the binary landed in `/datastore/cloakbrowser-cache` and persists across a container restart.

## Out of scope

- Wiring in a residential/SOCKS proxy (deferred; trivial env-var addition later).
- The `sockpuppetbrowser-cloakbrowser` separate-container approach.
- Any change to other stacks.
