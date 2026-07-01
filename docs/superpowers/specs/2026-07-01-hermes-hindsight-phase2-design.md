# Hermes ↔ Hindsight Memory (Phase 2) — Design Spec

- **Date:** 2026-07-01
- **Status:** Approved (brainstorm)
- **Stack files:** `stacks/hermes.yaml` (modify), `stacks/hindsight.yaml` (modify — network attach only)
- **Author:** brainstormed with Claude Code (ultracode)
- **Implements:** the Phase‑2 Hindsight enhancement deferred by `2026-06-30-hermes-stealth-browser-stack-design.md` (§12) and `2026-06-30-hermes-gateway-openwebui-port-design.md` (§2). Built‑in Markdown memory carried over unchanged and stays active.

---

## 1. Goal & what changes

**Augment — not replace —** Hermes' always‑on built‑in Markdown memory (`SOUL.md`, `memories/MEMORY.md`, `memories/USER.md` under `HERMES_HOME`) with the self‑hosted **Hindsight** stack, for large‑scale semantic recall, fact extraction, and cross‑session learning that a char‑capped Markdown store can't provide.

- **Before:** `hermes-gateway` runs the agent in‑process with **zero** memory/MCP wiring; the two stacks (`hermes`, `hindsight`) live on **isolated** Docker networks and cannot reach each other by name.
- **After:** Hermes' **native `hindsight` memory provider** (`mode=local_external`) reaches the Hindsight dataplane **server‑side** over **REST** at `http://hindsight:8888/api` via a **new shared external Docker network `shared-services`**. Automatic pre‑turn recall is injected into the system prompt and post‑turn `retain` persists to a dedicated `hermes` bank; `hindsight_recall`/`retain`/`reflect` tools are also exposed. Built‑in Markdown memory remains active alongside.

> **Transport note:** the native provider uses Hindsight's **REST client**, not MCP. It appends `/v1/default/banks/<bank>/…` to the configured `api_url`; the `/api` segment matches the server's `HINDSIGHT_API_BASE_PATH=/api`. The `/mcp/<bank>/` endpoint is only relevant to the §7 `mcp_servers` fallback.

**Why native provider (not raw MCP):** it's the first‑class, turn‑lifecycle integration (background prefetch/recall + conversation sync/retain) both design docs recommend. A raw `mcp_servers` entry is kept as a **documented fallback** only (§7).

**Why the shared network (not the public URL):** the agent is in‑process in `hermes-gateway`, so the backend must be reachable *from that container*. The public `hindsight.alekseev.us` is a dead end — it sits behind Cloudflare Access (blocks a programmatic agent) and its cloudflared rule only proxies `^/api/(mcp|v1|…)`, so the real MCP path `/mcp/<bank>/` would 404. Container‑name routing over a shared Docker network bypasses both.

## 2. Non‑goals / out of scope

- Replacing or disabling built‑in Markdown memory (it's always‑on and stays active; §5.2 keeps the `memory` tool enabled).
- Changing Hindsight's own behavior, models, embeddings, DB, or LLM wiring — the only edit to `hindsight.yaml` is a network attach (§5.3).
- Per‑session or per‑user bank isolation via `bank_id_template` — we pin a **single** `hermes` bank (revisit later if multi‑agent isolation is needed).
- Publishing any host port; all cross‑stack traffic stays on the internal shared network. External human access remains cloudflared + Cloudflare Access, unchanged.
- Fixing the unrelated pinned‑image issues (duplicate‑`tool_use`‑id transcript bug; `config.yaml`/OpenRouter provider default). Noted as risks (§11), handled elsewhere.

## 3. Key decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Integration mechanism | **Native `hindsight` provider** (`mode=local_external`) | First‑class turn‑lifecycle recall/retain + `reflect` synthesis; matches both design docs. `mcp_servers` kept as fallback only. |
| Cross‑stack networking | **Shared external network `shared-services`** | Cleanest, reusable; container‑name routing survives IP churn; no internet, no Cloudflare Access, no `/api/mcp` 404. |
| Hindsight endpoint | **`http://hindsight:8888/api`** by container name (REST) | Native provider is REST; client appends `/v1/default/banks/<bank>/…`; `/api` matches server `HINDSIGHT_API_BASE_PATH=/api`. Reached only over `shared-services`. |
| Connection config surface | **Portainer `${VAR}` env on `hermes-gateway`** (env overrides file) | Matches the stack's existing zero‑docker‑secrets pattern; 12‑factor; survives image upgrades without seeding files. |
| Provider activation | **`memory.provider: hindsight`** persisted in `HERMES_HOME/config.yaml` | **Config‑file‑only — no env var selects the provider** (source‑confirmed). Set once via `hermes config set memory.provider hindsight` / `hermes memory setup`; persists in the `/opt/data` volume. |
| Tenant key | **New Portainer var `HINDSIGHT_API_KEY`**, value copied from the host Hindsight secret | Consistent with the current hermes stack (no docker secrets today). |
| Memory bank | **Single pinned bank `hermes`** (`HINDSIGHT_BANK_ID=hermes`) | Isolates this agent's memory from other Hindsight tenants; simple. |
| Built‑in memory | **Kept enabled alongside Hindsight** | Additive design; built‑in is always‑on and needs no infra. Option to `hermes tools disable memory` if the model over‑prefers it. |

## 4. Architecture

Two Portainer stacks on the same host, bridged by one **external** Docker network. `hermes-gateway` gains a second network attachment; the `hindsight` service gains one. Nothing else moves; nothing is published to the host.

```
   ┌─────────────────────── hermes stack (hermes-net) ───────────────────────┐
   │  open-webui ──/v1──▶ hermes-gateway  ──browser tools──▶ camofox          │
   │                       (agent in‑process; gateway run)                    │
   │                       HERMES_HOME=/opt/data                              │
   │                       native hindsight provider ─┐                       │
   └───────────────────────────────────────────────── │ ─────────────────────┘
                                                       │  http://hindsight:8888/api (REST)
                            shared-services  ◀─────────┘  (external: true)
                                (bridge)     ─────────┐
   ┌──────────────────────── hindsight stack ──────── │ ─────────────────────┐
   │  hindsight ◀──────────────────────────────────────┘                     │
   │   :8888 dataplane API — REST /api/v1 (native); /mcp/<bank>/ = fallback   │
   │   :9999 control plane UI                                                 │
   │   ├─ hindsight-db (vchord pg18)   ├─ hindsight-litellm :4000             │
   │   ├─ hindsight-tei-embed          └─ hindsight-tei-reranker              │
   │   (all on the stack's default project network — unchanged)              │
   └──────────────────────────────────────────────────────────────────────────┘
```

## 5. Component specifications

### 5.1 `shared-services` network (host + both stacks)

- **Host, once:** `docker network create shared-services` (a plain bridge; external to both compose projects).
- Declared in **both** stacks top‑level as:
  ```yaml
  networks:
    shared-services:
      external: true
  ```

### 5.2 `stacks/hermes.yaml` — modify `hermes-gateway`

1. **Network attach** — join both networks:
   ```yaml
   services:
     hermes-gateway:
       networks:
         - hermes-net
         - shared-services
   ```
   (Every other service stays on `hermes-net` only. Add the top‑level `shared-services` block from §5.1.)
2. **Connection env** (Portainer `${VAR}` pattern; env overrides the JSON config file):
   ```yaml
       environment:
         HINDSIGHT_MODE: local_external
         HINDSIGHT_API_URL: http://hindsight:8888/api   # /api = server HINDSIGHT_API_BASE_PATH; client appends /v1/...
         HINDSIGHT_BANK_ID: hermes
         HINDSIGHT_API_KEY: ${HINDSIGHT_API_KEY}         # == server's HINDSIGHT_API_TENANT_API_KEY
   ```
3. **Provider activation** — set `memory.provider: hindsight` once via `hermes config set memory.provider hindsight` (or `hermes memory setup` → hindsight); persists to `/opt/data/config.yaml`. **Required — no env var can select the provider** (§6).
4. **Built‑in memory** — left enabled (no change). Optional post‑deploy tuning: `hermes tools disable memory` if recall quality suffers from tool competition.
5. **New required Portainer var:** `HINDSIGHT_API_KEY` — its value must equal the Hindsight server's `HINDSIGHT_API_TENANT_API_KEY` (documented in the stack header comment alongside the existing required vars).

### 5.3 `stacks/hindsight.yaml` — modify the `hindsight` service only

The `hindsight` service currently declares **no** `networks:` key (it's implicitly on the project default network). Adding an explicit list means we must **re‑list `default`** so its siblings (`hindsight-db`, `hindsight-litellm`, `hindsight-tei-*`) stay reachable:

```yaml
services:
  hindsight:
    networks:
      - default
      - shared-services
networks:
  shared-services:
    external: true
```

No other Hindsight service is touched; `default` remains auto‑created for db/litellm/tei.

## 6. Provider activation & config resolution

Config resolution order (highest wins): **`HINDSIGHT_*` env** → `HERMES_HOME/hindsight/config.json` → provider defaults. The provider *selection* (`memory.provider`) lives separately in `HERMES_HOME/config.yaml`. The following were resolved from source (`NousResearch/hermes-agent` plugin + `vectorize-io/hindsight` client/server) at **HIGH confidence**:

- **Q1 — `api_url` shape → `http://hindsight:8888/api`.** Hermes passes `api_url` verbatim as the client `base_url` (`plugins/memory/hindsight/__init__.py:1283,1057`); the generated client appends its own resource paths — `POST /v1/default/banks/<bank>/memories` (retain), `.../memories/recall`, `.../reflect`, and an init‑time `GET /version` probe. The client never inserts `/api`; that prefix is the **server's** `HINDSIGHT_API_BASE_PATH=/api` (FastAPI `root_path`), so `api_url` must carry it. Net path for retain: `http://hindsight:8888/api/v1/default/banks/hermes/memories`.
  *Deploy verify (the exact probe Hermes runs on init):*
  ```
  docker exec hermes-gateway sh -c 'curl -fsS -H "Authorization: Bearer $HINDSIGHT_API_KEY" http://hindsight:8888/api/version'
  ```
- **Q2 — activation → `memory.provider: hindsight` in `config.yaml`, config‑file‑only.** The gateway reads the provider via `cfg_get(cfg, "memory", "provider")` (`gateway/run.py:14536`), a pure config‑file lookup with **no env fallback** — there is no `HERMES_MEMORY_PROVIDER` (source‑confirmed). Set once: `hermes config set memory.provider hindsight` (or `hermes memory setup`). The `HINDSIGHT_*` env vars only configure the provider *after* it is selected.
  *Deploy verify:* `docker exec hermes-gateway hermes config get memory.provider` → `hindsight`.
- **Q3 — bank provisioning → auto‑created on first write; no pre‑creation.** Official 0.8 docs: *"You don't need to pre‑create a bank. Hindsight will automatically create it… when you first use it."* This holds under the `ApiKeyTenantExtension` (it validates the Bearer key and pins the `public` schema; it does not change auto‑create or the `default` namespace segment). Hermes' default `bank_id` is `hermes`.
  *Deploy verify (end‑to‑end retain against the tenant‑authed instance):*
  ```
  docker exec hermes-gateway sh -c 'curl -fsS -X POST -H "Authorization: Bearer $HINDSIGHT_API_KEY" -H "Content-Type: application/json" -d "{\"items\":[{\"content\":\"deploy smoke test\"}]}" http://hindsight:8888/api/v1/default/banks/hermes/memories'
  ```

## 7. Fallback — raw `mcp_servers` (documented, not wired)

If `local_external` misbehaves on the pinned `hermes-agent` digest, register Hindsight as a plain MCP server in `HERMES_HOME/config.yaml`:

```yaml
mcp_servers:
  hindsight:
    url: http://hindsight:8888/mcp/hermes/     # bank in path; see base-path caveat below
    headers:
      Authorization: "Bearer ${HINDSIGHT_API_KEY}"
    tools:
      include: [recall, retain, sync_retain, reflect, get_memory, list_memories]
    timeout: 120
```

Trade‑off: no automatic pre‑turn recall injection (model must call tools), but path/auth are fully documented and `sync_retain` gives read‑after‑write.

**Base‑path caveat:** unlike the REST client (§6 Q1), the MCP mount's interaction with `HINDSIGHT_API_BASE_PATH=/api` is unverified — the endpoint may be `/mcp/hermes/` or `/api/mcp/hermes/`. Only relevant if the native provider fails; confirm the working path at deploy before wiring the fallback.

## 8. Error handling & gotchas

- **Async retain** — `retain_async=true` (default): a recall immediately after a write may miss. Acceptable for background learning; use `sync_retain` (fallback tools) where read‑after‑write matters.
- **Timeouts** — Hindsight's server LLM timeout is **600s** in this deployment (`HINDSIGHT_API_LLM_TIMEOUT=600`). Keep Hermes' client/MCP timeout generous (≥ server window); the fallback `mcp_servers` block starts at 120 and should be raised if writes time out.
- **Tenant key extraction** — the real key value lives on the host in `/mnt/spool/apps/config/hindsight/env` (docker secret `hindsight_env`), under the var **`HINDSIGHT_API_TENANT_API_KEY`**. The runbook copies that value into the new `HINDSIGHT_API_KEY` Portainer var on the hermes stack. The client sends it as `Authorization: Bearer <key>`.
- **Startup ordering** — cross‑stack, so no compose `depends_on`. Bring `hindsight` up first; the native provider tolerates a briefly‑absent backend (recall degrades gracefully), but verify after both are up.
- **Network side‑effects** — attaching `hindsight` to a second network must not break its internal DNS; §5.3 re‑lists `default` precisely to preserve it. Validate `hindsight` still resolves `hindsight-db`/`hindsight-litellm` after the edit.
- **Known unrelated image bug** — duplicate‑`tool_use`‑id transcript wedging on the pinned digest; watch long chats after adding a tool provider (out of scope to fix here).

## 9. Validation

- **Static:** `./scripts/validate-stack.sh hermes` and `./scripts/validate-stack.sh hindsight` (both must pass `docker compose config`).
- **Runtime (host, after redeploy):**
  1. Reachability + api_url: `docker exec hermes-gateway sh -c 'curl -fsS -H "Authorization: Bearer $HINDSIGHT_API_KEY" http://hindsight:8888/api/version'` — 200 confirms container‑name routing over `shared-services` and the `/api` base path.
  2. Provider selected: `docker exec hermes-gateway hermes config get memory.provider` → `hindsight`; `hermes memory status` → connected.
  3. Round‑trip: chat turn stating a durable fact → later turn recalls it; confirm a `retain` landed in the `hermes` bank (Control Plane `:9999`), and/or run the §6 Q3 retain curl.

## 10. Host runbook (manual — assistant cannot reach the host)

1. `docker network create shared-services` (idempotent; skip if it exists).
2. Read `HINDSIGHT_API_TENANT_API_KEY` from `/mnt/spool/apps/config/hindsight/env`.
3. In Portainer, add `HINDSIGHT_API_KEY=<that value>` to the **hermes** stack env.
4. Deploy the updated `hindsight` stack (network attach) — verify internal DNS intact (`docker exec hindsight getent hosts hindsight-db`).
5. Deploy the updated `hermes` stack (env + network attach).
6. Set the provider (required, config‑file‑only): `docker exec hermes-gateway hermes config set memory.provider hindsight` (or `hermes memory setup` → hindsight). Restart the gateway if it caches config at boot.
7. Run the §9 runtime checks. Bank `hermes` auto‑creates on first retain (no pre‑creation). If `local_external` fails, switch to the §7 `mcp_servers` fallback.

## 11. Risks

- **Version skew on the pinned digest** — §6 was verified against upstream `main`; the pinned `hermes-agent` digest (`…f670f417`) may ship an older provider or `hindsight-client` where paths differ. *Mitigation:* §9 step 1 (`/api/version`) + step 2 (`memory status`) catch it immediately; §7 fallback covers a hard miss.
- **Static OAuth token expiry** (pre‑existing) — unrelated to memory but a silent‑outage risk for the daemon.
- **Tool competition** — model may prefer the built‑in `memory` tool over Hindsight; mitigated by keeping auto‑recall on and, if needed, `hermes tools disable memory`.

## 12. Validate‑at‑deploy checklist

- [ ] `shared-services` network exists; both stacks attach without error.
- [ ] `hindsight` still resolves its siblings after the network edit.
- [ ] `GET http://hindsight:8888/api/version` from `hermes-gateway` returns 200 (routing + `/api` base path).
- [ ] `hermes config get memory.provider` → `hindsight`; `hermes memory status` connected.
- [ ] retain → recall round‑trip works against the auto‑created `hermes` bank.
- [ ] (Only if falling back) confirmed the working MCP path re: the `/api` base‑path caveat (§7).
