# changedetection CloakBrowser Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the failing browserless `playwright-chrome` container with the `changedetection.io-cloak-browser` in-container plugin (patchright backend), eliminating the OCI `unsafe procfs` error.

**Architecture:** Single container. The `changedetection` service loads the CloakBrowser stealth fetcher at boot via `EXTRA_PACKAGES`; the separate `playwright-chrome` (browserless) browser container — and its `SYS_ADMIN`/custom-seccomp config that triggered the runc error — is removed entirely. The proprietary CloakBrowser Chromium binary is cached in the existing `/datastore` volume.

**Tech Stack:** Docker Compose, Portainer (deploy target), `changedetection.io` 0.55.7, `changedetection.io-cloak-browser` plugin, `cloakbrowser[patchright]`.

**Spec:** `docs/superpowers/specs/2026-06-19-changedetection-cloakbrowser-design.md`

**Branch:** `changedetection-cloakbrowser` (already checked out).

**Execution note:** Tasks 1–2 are local repo changes runnable in this session. Tasks 3–4 are **operator actions on the Portainer host** (this environment has no Docker daemon / Portainer access) — they are written so the user can execute them directly.

---

### Task 1: Rewrite `stacks/changedetection.yaml`

Replace the browser-container wiring with the in-container CloakBrowser plugin. Three discrete edits, then the orphaned seccomp file is removed, then static validation.

**Files:**
- Modify: `stacks/changedetection.yaml`
- Delete: `stacks/chrome.json`

- [ ] **Step 1: Edit the `changedetection` service environment + drop `depends_on`**

Replace this exact block:

```yaml
    environment:
      # Log output levels: TRACE, DEBUG(default), INFO, SUCCESS, WARNING, ERROR, CRITICAL
      # - LOGGER_LEVEL=TRACE
      - PLAYWRIGHT_DRIVER_URL=ws://playwright-chrome:3000
      - BASE_URL=https://changedetection.alekseev.us
      - HIDE_REFERER=true
      - FETCH_WORKERS=10
      - MINIMUM_SECONDS_RECHECK_TIME=3
      - ALLOW_FILE_URI=False
      - TZ=America/New_York
    ports:
      - 5000:5000/tcp
    depends_on:
      playwright-chrome:
        condition: service_started
```

with:

```yaml
    environment:
      # Log output levels: TRACE, DEBUG(default), INFO, SUCCESS, WARNING, ERROR, CRITICAL
      # - LOGGER_LEVEL=TRACE
      - BASE_URL=https://changedetection.alekseev.us
      - HIDE_REFERER=true
      - FETCH_WORKERS=5
      - MINIMUM_SECONDS_RECHECK_TIME=3
      - ALLOW_FILE_URI=False
      - TZ=America/New_York
      # CloakBrowser stealth fetcher (in-container plugin) + patchright driver backend.
      # Binary (~200MB) downloads on first CloakBrowser fetch into CLOAKBROWSER_CACHE_DIR.
      - EXTRA_PACKAGES=changedetection.io-cloak-browser cloakbrowser[patchright]
      - CLOAKBROWSER_BACKEND=patchright
      - CLOAKBROWSER_CACHE_DIR=/datastore/cloakbrowser-cache
      - CLOAKBROWSER_HUMANIZE=true
    ports:
      - 5000:5000/tcp
```

This removes `PLAYWRIGHT_DRIVER_URL`, lowers `FETCH_WORKERS` 10→5, adds the four CloakBrowser variables, and deletes the `depends_on` block (no browser container to depend on).

- [ ] **Step 2: Delete the `playwright-chrome` service and the dead commented block**

Remove everything between the `changedetection` service's `ports` block and the top-level `volumes:` key — i.e. delete the commented-out `browser-sockpuppet-chrome` block (lines ~31–46) and the entire `playwright-chrome:` service (lines ~48–71). After Steps 1–2 the file must read **exactly**:

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json

services:

  changedetection:
    restart: unless-stopped
    image: ghcr.io/dgtlmoon/changedetection.io:0.55.7
    container_name: changedetection
    hostname: changedetection
    volumes:
      - changedetection-data:/datastore
    # Configurable proxy list support, see https://github.com/dgtlmoon/changedetection.io/wiki/Proxy-configuration#proxy-list-support
    #        - ./proxies.json:/datastore/proxies.json
    environment:
      # Log output levels: TRACE, DEBUG(default), INFO, SUCCESS, WARNING, ERROR, CRITICAL
      # - LOGGER_LEVEL=TRACE
      - BASE_URL=https://changedetection.alekseev.us
      - HIDE_REFERER=true
      - FETCH_WORKERS=5
      - MINIMUM_SECONDS_RECHECK_TIME=3
      - ALLOW_FILE_URI=False
      - TZ=America/New_York
      # CloakBrowser stealth fetcher (in-container plugin) + patchright driver backend.
      # Binary (~200MB) downloads on first CloakBrowser fetch into CLOAKBROWSER_CACHE_DIR.
      - EXTRA_PACKAGES=changedetection.io-cloak-browser cloakbrowser[patchright]
      - CLOAKBROWSER_BACKEND=patchright
      - CLOAKBROWSER_CACHE_DIR=/datastore/cloakbrowser-cache
      - CLOAKBROWSER_HUMANIZE=true
    ports:
      - 5000:5000/tcp

volumes:
  changedetection-data:
```

- [ ] **Step 3: Delete the now-orphaned seccomp profile**

`chrome.json` was referenced only by the removed `playwright-chrome` service (verified: no other stack references it).

Run:

```bash
cd /Users/salekseev/src/github.com/salekseev/stacks
git rm stacks/chrome.json
```

Expected: `rm 'stacks/chrome.json'`

- [ ] **Step 4: Statically validate the stack (this is the test)**

Run:

```bash
cd /Users/salekseev/src/github.com/salekseev/stacks
./scripts/validate-stack.sh changedetection
```

Expected output ends with:

```
Validating stacks/changedetection.yaml...
Validation successful for stacks/changedetection.yaml
```

If `docker-compose` (v1) is not installed, run the v2 equivalent instead and expect a clean rendered config with exit code 0:

```bash
docker compose -f stacks/changedetection.yaml config -q
```

Expected: no output, exit 0. If validation fails, re-check that the file matches the block in Step 2 exactly (indentation included) and that no `playwright-chrome`/`depends_on`/`PLAYWRIGHT_DRIVER_URL` references remain:

```bash
grep -nE "playwright-chrome|PLAYWRIGHT_DRIVER_URL|depends_on|chrome.json" stacks/changedetection.yaml
```

Expected: no matches.

- [ ] **Step 5: Commit**

```bash
cd /Users/salekseev/src/github.com/salekseev/stacks
git add stacks/changedetection.yaml
git commit -m "$(cat <<'EOF'
feat(changedetection): replace browserless with CloakBrowser plugin

Retire the playwright-chrome (ghcr.io/browserless/chromium) container
whose SYS_ADMIN + custom seccomp profile triggered the runc "unsafe
procfs / openat2 function not implemented" OCI error on the Portainer
host. Load the changedetection.io-cloak-browser in-container plugin via
EXTRA_PACKAGES with the patchright driver backend, persist the binary
cache under /datastore, and lower FETCH_WORKERS 10->5 since browser
fetches now run inside the changedetection container. Delete the
orphaned chrome.json seccomp profile.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git show --stat HEAD` lists `stacks/changedetection.yaml` modified and `stacks/chrome.json` deleted.

---

### Task 2: Open a PR (optional, follows repo convention)

The repo integrates via PRs to `master` (see recent merge commits). Skip if the user prefers to merge locally.

- [ ] **Step 1: Push and open PR**

```bash
cd /Users/salekseev/src/github.com/salekseev/stacks
git push -u origin changedetection-cloakbrowser
gh pr create --base master --head changedetection-cloakbrowser \
  --title "feat(changedetection): replace browserless with CloakBrowser plugin" \
  --body "$(cat <<'EOF'
Replaces the failing `playwright-chrome` (browserless) container with the
`changedetection.io-cloak-browser` in-container plugin (patchright backend).

**Why:** browserless's `SYS_ADMIN` + custom seccomp (`chrome.json`) profile
triggers `runc create failed: ... unsafe procfs detected: openat2 ...
function not implemented` on the Portainer host.

**Changes:**
- Retire the `playwright-chrome` service and its `SYS_ADMIN`/seccomp config
- Add `EXTRA_PACKAGES=changedetection.io-cloak-browser cloakbrowser[patchright]`,
  `CLOAKBROWSER_BACKEND=patchright`, `CLOAKBROWSER_CACHE_DIR=/datastore/cloakbrowser-cache`,
  `CLOAKBROWSER_HUMANIZE=true`
- Drop `PLAYWRIGHT_DRIVER_URL` and `depends_on`; lower `FETCH_WORKERS` 10->5
- Delete orphaned `stacks/chrome.json`

Design: `docs/superpowers/specs/2026-06-19-changedetection-cloakbrowser-design.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: `gh` prints the new PR URL.

---

### Task 3: Deploy and verify on Portainer (operator action)

Performed by the user on the Portainer host. Each step is concrete and observable.

- [ ] **Step 1: Redeploy the stack**

In Portainer, pull/redeploy the `changedetection` stack from the updated branch (or `master` after merge). Then confirm the container is up and the old one is gone:

```bash
docker ps --filter "name=changedetection" --format '{{.Names}}\t{{.Status}}'
docker ps -a --filter "name=playwright-chrome" --format '{{.Names}}'
```

Expected: `changedetection` shows `Up ...`; the `playwright-chrome` query returns **nothing**. No `OCI runtime create failed` / `unsafe procfs` error appears during deploy.

- [ ] **Step 2: Confirm the plugin and patchright installed at boot**

```bash
docker logs changedetection 2>&1 | grep -iE "cloak|patchright|Successfully installed|ERROR" | head -40
```

Expected: lines showing `changedetection.io-cloak-browser` and `patchright` were pip-installed (`Successfully installed ...`), and **no** pip/import error.

Bracket-glob fallback: if logs show a `pip` error caused by `cloakbrowser[patchright]`, change that env value to `EXTRA_PACKAGES=changedetection.io-cloak-browser patchright` (install the package directly), redeploy, and re-run this step.

- [ ] **Step 3: Confirm the CloakBrowser fetcher registered and the backend loaded**

```bash
docker exec changedetection python -c "from changedetectionio.content_fetchers import available_fetchers; print(available_fetchers())"
```

Expected: output includes `('html_cloakbrowser', 'CloakBrowser - Stealth Chromium (anti-bot bypass)')`.

Backend fallback: if Step 2/this step shows a `CLOAKBROWSER_BACKEND`/patchright import error, remove the `CLOAKBROWSER_BACKEND=patchright` line from the stack and redeploy — CloakBrowser's binary-level fingerprint patches still apply with the default backend.

- [ ] **Step 4: Smoke-test one watch and confirm the binary cached**

In the UI, pick one watch → **Edit → Fetch tab → "CloakBrowser - Stealth Chromium (anti-bot bypass)"** → Save → **Recheck**. Confirm it fetches without error. Then:

```bash
docker exec changedetection ls -la /datastore/cloakbrowser-cache
docker restart changedetection && sleep 20
docker exec changedetection ls -la /datastore/cloakbrowser-cache
```

Expected: the Chromium binary is present in `/datastore/cloakbrowser-cache` after the first fetch and **still present** after the restart (no re-download).

---

### Task 4: Migrate watches to CloakBrowser (operator action, as needed)

The plugin's fetcher is selected per-watch; existing watches keep their prior fetcher and any still set to the retired websocket-Playwright fetcher will error until switched.

- [ ] **Step 1: Switch each browser-dependent watch**

For every watch that needs JS rendering / anti-bot: **Edit → Fetch tab → "CloakBrowser - Stealth Chromium (anti-bot bypass)" → Save**. Watches that only need plain HTML can stay on the basic HTTP fetcher.

Expected: rechecks succeed for switched watches; no watch reports a "browser/driver connection" error.

---

## Self-Review

**1. Spec coverage:**
- Retire `playwright-chrome` + remove `SYS_ADMIN`/seccomp → Task 1 Steps 1–2. ✓
- Remove `PLAYWRIGHT_DRIVER_URL` + `depends_on` → Task 1 Step 1. ✓
- `FETCH_WORKERS` 10→5 → Task 1 Step 1. ✓
- Add `EXTRA_PACKAGES` (plugin + `cloakbrowser[patchright]`), `CLOAKBROWSER_BACKEND=patchright`, `CLOAKBROWSER_CACHE_DIR`, `CLOAKBROWSER_HUMANIZE` → Task 1 Step 1. ✓
- Delete orphaned `chrome.json` + dead commented block → Task 1 Steps 2–3. ✓
- Static validation → Task 1 Step 4. ✓
- Runtime verification (no OCI error, plugin+patchright installed, backend loaded, fetch works, binary persists) → Task 3 Steps 1–4. ✓
- Bracket-glob + backend-honored fallbacks from spec operational notes → Task 3 Steps 2–3. ✓
- Per-watch migration → Task 4. ✓

**2. Placeholder scan:** No TBD/TODO/"add error handling". Every step has concrete commands, exact file content, and expected output.

**3. Type/name consistency:** Env var names, the cache path `/datastore/cloakbrowser-cache`, the fetcher id `html_cloakbrowser`, and the seccomp filename `chrome.json` are used identically across all tasks and match the spec.

No gaps found.
