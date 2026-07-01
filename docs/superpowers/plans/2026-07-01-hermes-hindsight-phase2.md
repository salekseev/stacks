# Hermes ↔ Hindsight Memory (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Hermes' native `hindsight` memory provider to the self-hosted Hindsight stack over a shared Docker network, so the gateway agent gets semantic recall/retain on top of its built-in Markdown memory.

**Architecture:** Both stacks are edited to join a new host-created external Docker network `shared-services`; `hermes-gateway` reaches Hindsight's REST dataplane by container name at `http://hindsight:8888/api`. Connection params are Portainer `${VAR}` env; the provider is switched on once via `config.yaml` (no env selector exists). Runtime deploy is a manual host runbook (spec §10) — the repo tasks below only change and statically validate the two compose files + reconcile docs.

**Tech Stack:** Docker Compose, `scripts/validate-stack.sh` (wraps `docker-compose config`), Portainer stack env vars.

**Spec:** `docs/superpowers/specs/2026-07-01-hermes-hindsight-phase2-design.md`

**Pre-flight facts (verified while writing this plan):**
- `docker-compose config` returns exit 0 for a stack referencing an `external: true` network that does not exist yet — so validation passes in the repo without creating the host network.
- Unset `${VAR}` prints a `level=warning … not set` line to stderr but still exits 0; `validate-stack.sh` prints `Validation successful` on success.
- `hindsight.yaml` currently has **no** top-level `networks:` block and the `hindsight` service has **no** `networks:` key (implicitly on the compose default network). Re-listing `default` when adding an explicit list keeps db/litellm/tei DNS working — confirmed rendering both `default` and `shared-services` on the service.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `stacks/hindsight.yaml` | Modify | Attach the `hindsight` service to `shared-services` (keep it on `default`). |
| `stacks/hermes.yaml` | Modify | Attach `hermes-gateway` to `shared-services`; add `HINDSIGHT_*` env; document the new required Portainer var. |
| `docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md` | Modify | One-line as-built pointer: Phase-2 Hindsight now implemented. |
| `docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md` | Modify | Same as-built pointer. |

Deploy-time (host, **not** a repo task): follow spec §10 runbook — `docker network create shared-services`, copy the tenant key into the `HINDSIGHT_API_KEY` Portainer var, redeploy both stacks, `hermes config set memory.provider hindsight`, run spec §9 checks.

---

### Task 1: Attach the `hindsight` service to `shared-services`

**Files:**
- Modify: `stacks/hindsight.yaml` (the `hindsight` service block at lines 74-80; add a new top-level `networks:` block after the `secrets:` block at EOF, lines 280-284)

- [ ] **Step 1: Write the failing assertion and run it**

The "test" is that the rendered config attaches `hindsight` to `shared-services`. Run:

```bash
docker-compose -f stacks/hindsight.yaml config 2>/dev/null | grep -q 'shared-services' && echo PRESENT || echo ABSENT
```

Expected: `ABSENT` (not wired yet).

- [ ] **Step 2: Add the `networks:` key to the `hindsight` service**

Edit `stacks/hindsight.yaml`. Find this exact block (lines 74-80):

```yaml
    expose:
      - "8888"
      - "9999"
    depends_on:
      hindsight-db:
        condition: service_healthy
    restart: unless-stopped
```

Replace it with (adds `networks:` — `default` re-listed so db/litellm/tei stay reachable):

```yaml
    expose:
      - "8888"
      - "9999"
    depends_on:
      hindsight-db:
        condition: service_healthy
    restart: unless-stopped
    # Phase-2: also join the host-created shared-services net so the hermes stack can
    # reach this dataplane by container name (http://hindsight:8888/api). `default` is
    # re-listed explicitly so siblings (hindsight-db, litellm, tei-*) stay reachable.
    networks:
      - default
      - shared-services
```

- [ ] **Step 3: Add the top-level `networks:` block**

Edit `stacks/hindsight.yaml`. Find the `secrets:` block at EOF (lines 280-284):

```yaml
secrets:
  hindsight_db_password:
    file: /mnt/spool/apps/config/hindsight/secrets/db_password
  hindsight_env:
    file: /mnt/spool/apps/config/hindsight/env
```

Append a `networks:` block immediately after it:

```yaml
secrets:
  hindsight_db_password:
    file: /mnt/spool/apps/config/hindsight/secrets/db_password
  hindsight_env:
    file: /mnt/spool/apps/config/hindsight/env

networks:
  # Created out-of-band on the host: `docker network create shared-services`.
  # Shared with the hermes stack so hermes-gateway resolves `hindsight` by name.
  shared-services:
    external: true
```

- [ ] **Step 4: Validate and re-run the assertion — expect PASS**

```bash
./scripts/validate-stack.sh hindsight
docker-compose -f stacks/hindsight.yaml config 2>/dev/null | grep -q 'shared-services' && echo PRESENT || echo ABSENT
docker-compose -f stacks/hindsight.yaml config 2>/dev/null \
  | awk '/^  hindsight:/{f=1} f&&/networks:/{print;p=1;next} p&&/- |: null/{print} /^  hindsight-db:/{f=0;p=0}' | head
```

Expected:
- `Validating stacks/hindsight.yaml...` then `Validation successful for stacks/hindsight.yaml` (unset-variable warnings on stderr are fine).
- `PRESENT`
- The awk snippet shows the `hindsight` service listing both `default` and `shared-services`.

- [ ] **Step 5: Commit**

```bash
git add stacks/hindsight.yaml
git commit -m "$(printf 'feat(hindsight): attach dataplane to shared-services network\n\nPhase-2 Hindsight<->Hermes wiring: adds an external shared-services\nnetwork and joins the hindsight service to it (default re-listed so\ninternal DNS is preserved) so hermes-gateway can reach the dataplane\nby container name.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: Wire `hermes-gateway` to Hindsight (network + env + docs header)

**Files:**
- Modify: `stacks/hermes.yaml` (header comment line 12; `hermes-gateway` env after line 88; `hermes-gateway` networks lines 97-98; top-level `networks:` lines 182-183)

- [ ] **Step 1: Write the failing assertion and run it**

```bash
docker-compose -f stacks/hermes.yaml config 2>/dev/null | grep -q 'hindsight:8888/api' && echo PRESENT || echo ABSENT
```

Expected: `ABSENT`.

- [ ] **Step 2: Document the new required Portainer var in the header**

Edit `stacks/hermes.yaml`. Find (lines 12-13):

```yaml
#   HERMES_TUNNEL_ID          - Cloudflare tunnel UUID
# Nothing published to host; only cloudflared reaches origins, gated by one Cloudflare Access app.
```

Replace with:

```yaml
#   HERMES_TUNNEL_ID          - Cloudflare tunnel UUID
#   HINDSIGHT_API_KEY         - Hindsight tenant key (== server HINDSIGHT_API_TENANT_API_KEY); Phase-2 memory
# Nothing published to host; only cloudflared reaches origins, gated by one Cloudflare Access app.
```

- [ ] **Step 3: Add the `HINDSIGHT_*` env vars to `hermes-gateway`**

Edit `stacks/hermes.yaml`. Find (lines 87-90):

```yaml
      # Claude via OAuth setup-token (see spec §9 for the daemon-expiry runbook).
      - ANTHROPIC_TOKEN=${ANTHROPIC_TOKEN}
    volumes:
      - /mnt/spool/apps/data/hermes/gateway:/opt/data
```

Replace with:

```yaml
      # Claude via OAuth setup-token (see spec §9 for the daemon-expiry runbook).
      - ANTHROPIC_TOKEN=${ANTHROPIC_TOKEN}
      # Phase-2 Hindsight semantic memory — AUGMENTS (does not replace) built-in Markdown memory.
      # Reaches the self-hosted hindsight dataplane by container name over the shared-services net.
      # api_url carries /api (server HINDSIGHT_API_BASE_PATH); the REST client appends /v1/... .
      # NOTE: `memory.provider: hindsight` must be set ONCE in config.yaml (no env selector exists)
      # — see docs/superpowers/specs/2026-07-01-hermes-hindsight-phase2-design.md §6 and §10.
      - HINDSIGHT_MODE=local_external
      - HINDSIGHT_API_URL=http://hindsight:8888/api
      - HINDSIGHT_BANK_ID=hermes
      - HINDSIGHT_API_KEY=${HINDSIGHT_API_KEY}
      # Seal the read-only app venv: hindsight-client is baked in and pinned ==0.6.1;
      # never let the runtime lazy-install into /opt/hermes/.venv (uid 1000, read-only),
      # and NEVER upgrade the client. See the spec's As-built operational notes.
      - HERMES_DISABLE_LAZY_INSTALLS=1
    volumes:
      - /mnt/spool/apps/data/hermes/gateway:/opt/data
```

- [ ] **Step 4: Attach `hermes-gateway` to `shared-services`**

Edit `stacks/hermes.yaml`. Find (lines 96-100 — this `start_period: 60s` anchor is unique to the gateway; camofox's is `30s`):

```yaml
      start_period: 60s
    networks:
      - hermes-net

  open-webui:
```

Replace with:

```yaml
      start_period: 60s
    networks:
      - hermes-net
      - shared-services

  open-webui:
```

- [ ] **Step 5: Add `shared-services` to the top-level `networks:` block**

Edit `stacks/hermes.yaml`. Find the top-level block (lines 182-183):

```yaml
networks:
  hermes-net:
```

Replace with:

```yaml
networks:
  hermes-net:
  # Created out-of-band on the host: `docker network create shared-services`.
  # Shared with the hindsight stack so hermes-gateway resolves `hindsight` by name.
  shared-services:
    external: true
```

- [ ] **Step 6: Validate and re-run the assertion — expect PASS**

```bash
./scripts/validate-stack.sh hermes
docker-compose -f stacks/hermes.yaml config 2>/dev/null | grep -q 'hindsight:8888/api' && echo API_OK || echo API_MISSING
docker-compose -f stacks/hermes.yaml config 2>/dev/null \
  | awk '/^  hermes-gateway:/{f=1} f&&/networks:/{p=1} p&&/shared-services/{print "gateway-on-shared-services"; exit}'
```

Expected:
- `Validation successful for stacks/hermes.yaml` (unset-variable warnings on stderr are fine).
- `API_OK`
- `gateway-on-shared-services`

- [ ] **Step 7: Commit**

```bash
git add stacks/hermes.yaml
git commit -m "$(printf 'feat(hermes): wire gateway to Hindsight memory over shared-services\n\nPhase-2: native hindsight provider (local_external). Adds HINDSIGHT_*\nenv (api_url=http://hindsight:8888/api, bank=hermes), joins gateway to\nthe shared-services net, and documents the new HINDSIGHT_API_KEY var.\nProvider is switched on once via config.yaml at deploy (spec §10).\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: Reconcile prior design docs with the as-built Phase-2 state

Both prior specs list Hindsight as deferred/out-of-scope. Add a dated one-line pointer so the doc set stays honest (matches the repo's as-built reconciliation convention). This task changes only Markdown; there is no `validate-stack.sh` step.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md`
- Modify: `docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md`

- [ ] **Step 1: Locate the Hindsight/Phase-2 mentions**

```bash
grep -n -i 'hindsight' docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md | head
grep -n -i 'hindsight' docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md | head
```

Expected: at least one hit in each (the stealth doc's §12 Phase-2 section; the gateway-port doc's out-of-scope line).

- [ ] **Step 2: Add the as-built pointer to the stealth-browser design doc**

In `docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md`, at the start of the Hindsight/§12 Phase-2 section (immediately after its heading line found in Step 1), insert this blockquote line on its own line:

```markdown
> **As-built update (2026-07-01):** Implemented. See `docs/superpowers/specs/2026-07-01-hermes-hindsight-phase2-design.md` and `docs/superpowers/plans/2026-07-01-hermes-hindsight-phase2.md`. Wired via the native `hindsight` provider (`local_external`, `http://hindsight:8888/api`) over the `shared-services` network.
```

- [ ] **Step 3: Add the as-built pointer to the gateway-port design doc**

In `docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md`, on the line immediately after the Hindsight out-of-scope mention found in Step 1, insert:

```markdown
> **As-built update (2026-07-01):** Phase-2 Hindsight memory now implemented — see `docs/superpowers/specs/2026-07-01-hermes-hindsight-phase2-design.md`.
```

- [ ] **Step 4: Sanity-check both edits render**

```bash
grep -n 'As-built update (2026-07-01)' docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md
```

Expected: one match in each file.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-30-hermes-stealth-browser-stack-design.md docs/superpowers/specs/2026-06-30-hermes-gateway-openwebui-port-design.md
git commit -m "$(printf 'docs(hermes): mark Phase-2 Hindsight as implemented in prior specs\n\nAdds dated as-built pointers to the 2026-07-01 Phase-2 spec/plan in the\nstealth-browser and gateway-port design docs.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Deploy (host, manual — outside this plan)

After the three tasks land in the repo, deploy per spec §10:

1. `docker network create shared-services` (idempotent).
2. Read `HINDSIGHT_API_TENANT_API_KEY` from `/mnt/spool/apps/config/hindsight/env`; set it as `HINDSIGHT_API_KEY` on the hermes Portainer stack.
3. Redeploy the hindsight stack; verify internal DNS (`docker exec hindsight getent hosts hindsight-db`).
4. Redeploy the hermes stack.
5. `docker exec hermes-gateway hermes config set memory.provider hindsight` (config-file-only; restart gateway if it caches config at boot). **Do not run `hermes memory setup`'s dependency install / ignore its "Install failed" warning** — `hindsight-client` is baked in (`==0.6.1`) and the venv is read-only, so the warning is cosmetic (see spec As-built notes).
6. Run spec §9 checks: `GET /api/version` from the gateway, `hermes config get memory.provider` → `hindsight`, retain→recall round-trip against the auto-created `hermes` bank.

**Operational guardrails (verified live 2026-07-01):**
- **Never upgrade `hindsight-client`** — pinned `==0.6.1`; any drift wedges runtime retain. `HERMES_DISABLE_LAZY_INSTALLS=1` (in `hermes.yaml`) enforces use of the baked client and makes the plugin fail-fast instead of emitting `ensurepip` errors.
- Diagnostics via `sudo docker exec` run as **root** (can write the venv); the daemon runs as **uid 1000** (cannot) — a manual install "working" can mask the real daemon behavior.
- The Hermes tenant key can list the whole Hindsight tenant (`claude-code::*` banks); isolation from Claude Code's memory is by `bank_id` (`hermes`) only.

---

## Self-Review

**Spec coverage:**
- §2 shared network → Task 1 (hindsight side) + Task 2 Steps 4-5 (hermes side). ✓
- §5.2 hermes env + activation → Task 2 Steps 2-3 (env + header); activation is deploy-step (config.yaml only, §6). ✓
- §5.3 hindsight network attach (re-list `default`) → Task 1 Steps 2-3. ✓
- §6 api_url/activation/bank facts → encoded in env values (Task 2) + Deploy section + spec. ✓
- §7 fallback → documented in spec; not a repo task (correct — only used if native fails at deploy). ✓
- §9 validation / §10 runbook → Deploy section. ✓
- Doc reconciliation (repo convention) → Task 3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows exact before/after YAML and exact commands with expected output. ✓

**Type/name consistency:** `shared-services`, `HINDSIGHT_API_URL=http://hindsight:8888/api`, `HINDSIGHT_BANK_ID=hermes`, `HINDSIGHT_API_KEY`, `memory.provider: hindsight` used identically across tasks and match the spec. ✓
