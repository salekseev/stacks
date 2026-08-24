# Hindsight ChatGPT-subscription primary LLM with vLLM failover — Design Spec

- **Date:** 2026-08-23
- **Status:** Approved 2026-08-23. Ready for implementation planning.
- **Stack file:** `stacks/hindsight.yaml` (`hindsight` env + volume, `litellm` service removal, `cloudflared` ingress, `hindsight-db-init` config)
- **Author:** brainstormed with Claude Code
- **Host facts verified:** silverstone (`silverstone.local` / `100.77.121.38`) on 2026-08-23 by direct ssh inspection

---

## 1. Goal & framing

Make hindsight's default LLM the **ChatGPT/Codex subscription** (`gpt-5.6-luna`) and fall back to the **local vLLM** box (`192.168.1.147:8080`, `gemma-4-12b`) when the subscription is unavailable — rate-limited, unauthenticated, or erroring.

Two consequences fall out of that goal and are in scope:

1. The subscription must be reached through a transport that can actually serve `gpt-5.6-luna` (see §3).
2. The `hindsight-litellm` proxy, which currently owns hindsight's LLM routing, is no longer in the path and is removed (see §5.3).

Not a goal: preserving the proxy's Copilot / `claude-*` / embedding aliases or its Postgres spend logging. The user explicitly accepted losing those.

## 2. Current state (verified, not assumed)

`stacks/hindsight.yaml` on `master` (`5d3db29`):

```yaml
HINDSIGHT_API_LLM_PROVIDER: openai
HINDSIGHT_API_LLM_BASE_URL: http://hindsight-litellm:4000/v1
HINDSIGHT_API_LLM_MODEL: hindsight-default
HINDSIGHT_API_LLM_TIMEOUT: "600"
HINDSIGHT_API_LLM_MAX_CONCURRENT: "1"
```

The in-repo comment claims `hindsight-default` routes to `chatgpt/gpt-5.4-mini`. **That comment is stale.** The live proxy config (`/mnt/spool/apps/config/hindsight/litellm/config.yaml`, mtime Jun 13) actually defines:

- `hindsight-default` → `hosted_vllm/google/gemma-4-12B-it-qat-w4a16-ct` @ `http://192.168.1.147:8080/v1`, `timeout: 540`, `num_retries: 0`.
- `router_settings.fallbacks: [{hindsight-default: [gpt-5.4-mini]}]`, where `gpt-5.4-mini` is declared **twice** under one `model_name` — `github_copilot/gpt-5.4-mini` and `openai/gpt-5.4-mini` with a hardcoded `sk-svcacct-…` key — so litellm load-balances across Copilot and a raw OpenAI service account.
- **No `chatgpt/` deployment anywhere.** The ChatGPT subscription is currently unused by hindsight.
- `qwen3.6-35b-think-general` / `-code` → `openai/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` @ `192.168.1.147:8080` — dead config; that endpoint now serves vLLM `gemma-4-12b` (`google/gemma-4-12B-it-qat-w4a16-ct`), confirmed live via `/v1/models`.
- Live and load-bearing: `copilot-tokens/api-key.json` (mtime **Aug 17**), plus `gpt-5-mini`, `gpt-4o-mini`, `claude-opus-4.7`, `claude-opus-4.6`, `claude-sonnet-4.6`, `claude-haiku-4.5`, `text-embedding-3-small`, and spend logging (`store_prompts_in_spend_logs: true`).

Token store: `/mnt/spool/apps/config/hindsight/litellm/chatgpt-tokens/auth.json`, 4652 bytes, **mtime Jun 10 20:52** — an orphan, never refreshed, referenced by no deployment. `/mnt/spool/apps/config/hindsight/codex` does not exist. `apps` = uid/gid **568**, matching the containers' `user:`.

Upstream API surface (verified against `vectorize-io/hindsight` docs on `main`):

- `HINDSIGHT_API_LLM_PROVIDER` accepts `openai-codex` (native ChatGPT Plus/Pro transport, reads `$CODEX_HOME/auth.json`, auto-refresh) and `litellmrouter`.
- Multi-LLM chain: `HINDSIGHT_API_LLM_<n>_PROVIDER` / `_MODEL` / `_BASE_URL` / `_API_KEY` / `_REASONING_EFFORT`, indices contiguous from 1, selected by `HINDSIGHT_API_LLM_STRATEGY` = `{"mode":"failover"}` or `{"mode":"round-robin","weights":[…]}`. Failover advances to the next member after a member's own retries are exhausted.
- `HINDSIGHT_API_LLM_MAX_RETRIES` default **3**, `HINDSIGHT_API_LLM_MAX_CONCURRENT` default 32, `HINDSIGHT_API_LLM_TIMEOUT` default 120.
- Docs warn: Codex refresh tokens are single-use and rotate; sharing `~/.codex/auth.json` with another Codex process leaves the long-running service holding a stale token → `refresh_token_reused`, `/reflect` fails while recall and `/health` keep working. Remedy is a dedicated `CODEX_HOME`.

## 3. Decision: native failover chain, not the LiteLLM Router

The request was framed as "use the built-in litellm router." Rejected in favour of hindsight's provider-agnostic chain, because of the model-availability constraint:

- litellm's `chatgpt/` provider documents models only up to `gpt-5.4` / `gpt-5.4-pro` / `gpt-5.3-codex*`. No `gpt-5.6-*`.
- openai/codex#31967: a third-party originator (`pi`) requesting `gpt-5.6-luna` over ChatGPT OAuth gets `Model not found gpt-5.6-luna-free-1p-codexswic-ev3`, while the official `codex_cli_rs` originator succeeds **on the same credentials**. Backend routing depends on originator, version, account plan and rollout cohort. Issue closed with no documented fix.
- Working around that through litellm means spoofing `CHATGPT_ORIGINATOR` / `CHATGPT_USER_AGENT`, and additionally depends on the litellm version *bundled inside* `ghcr.io/vectorize-io/hindsight:0.9.1-slim` being ≥ 1.93 (unverified).
- Hindsight's `openai-codex` provider is the Codex-native transport, so it carries the Codex originator without spoofing, and owns token refresh itself.

Secondary reasons: router mode disables batch retain, and the chain keeps it (batch runs on the first batch-capable member). Router mode also needs `"num_retries": 0` set by hand to avoid double-retries, which the chain handles through `HINDSIGHT_API_LLM_MAX_RETRIES`.

Rejected alternatives, for the record:

- **litellmrouter with originator spoof** — kept as the documented fallback plan if `openai-codex` cannot serve luna and neither can a pinned older model.
- **Split workloads** (retain/consolidation on vLLM, reflect on luna via `HINDSIGHT_API_{RETAIN,REFLECT,CONSOLIDATION}_LLM_*`) — offered for quota protection, declined; luna is primary for every operation.
- **Weighted round-robin** — declined; makes extraction-quality debugging non-deterministic.

## 4. Routing after the change

```
recall / reflect / retain / consolidation
        │
        ▼
  primary (unindexed vars): openai-codex, gpt-5.6-luna
        │  CODEX_HOME=/codex → /mnt/spool/apps/config/hindsight/codex/auth.json (rw, rotates)
        │
        ├── success ──► done
        │
        └── failure after 1 attempt (429 / 5xx / auth / timeout / model-not-found)
                 │
                 ▼
        member 1 (HINDSIGHT_API_LLM_1_*): openai → http://192.168.1.147:8080/v1, gemma-4-12b
                 │
                 └── failure ──► operation fails (no third member)
```

## 5. Repo changes — `stacks/hindsight.yaml`

### 5.1 `hindsight` service environment

| Var | Action | Value / note |
|---|---|---|
| `HINDSIGHT_API_LLM_PROVIDER` | change | `openai-codex` (was `openai`) |
| `HINDSIGHT_API_LLM_MODEL` | change | `gpt-5.6-luna` (was `hindsight-default`) |
| `HINDSIGHT_API_LLM_BASE_URL` | **remove** | proxy is gone; `openai-codex` needs no base URL |
| `CODEX_HOME` | add | `/codex` — dedicated auth home, not shared with any interactive Codex process |
| `HINDSIGHT_API_LLM_1_PROVIDER` | add | `openai` |
| `HINDSIGHT_API_LLM_1_BASE_URL` | add | `http://192.168.1.147:8080/v1` |
| `HINDSIGHT_API_LLM_1_MODEL` | add | `gemma-4-12b` (vLLM `--served-model-name`; the full repo id also resolves) |
| `HINDSIGHT_API_LLM_1_API_KEY` | add | `none` — vLLM ignores it, but the member requires the field |
| `HINDSIGHT_API_LLM_1_REASONING_EFFORT` | add | `none` — gemma-4 emits a thinking block at its own default, wasting tokens on extraction |
| `HINDSIGHT_API_LLM_STRATEGY` | add | `{"mode": "failover"}` |
| `HINDSIGHT_API_LLM_MAX_RETRIES` | add | `1` — default 3 would burn three luna attempts per call under a 429 before falling through |
| `HINDSIGHT_API_LLM_TIMEOUT` | keep | `600` |
| `HINDSIGHT_API_LLM_MAX_CONCURRENT` | change | `4` (was `1`, tuned for llama.cpp `--parallel 1`; vLLM batches and luna is remote) |

Comment rewrite is part of the change: the existing block documents the stale `chatgpt/gpt-5.4-mini` claim and llama.cpp-era tuning rationale. Replace with the real topology.

### 5.2 `hindsight` service volume

```yaml
volumes:
  # Dedicated Codex auth home. NOT :ro — refresh tokens are single-use and the
  # provider writes the rotated token back; a read-only mount breaks refresh.
  - /mnt/spool/apps/config/hindsight/codex:/codex
```

### 5.3 Removals

- The entire `litellm:` service block.
- Its `cloudflared` ingress entry (`hostname: hindsight-litellm.alekseev.us` → `http://hindsight-litellm:4000`).
- `CREATE SCHEMA IF NOT EXISTS litellm AUTHORIZATION postgres;` from the `hindsight-db-init` config.

Deliberately **not** touched:

- Host files under `/mnt/spool/apps/config/hindsight/litellm/` (config.yaml, copilot-tokens, chatgpt-tokens) — left in place so rollback is a pure `git revert` + redeploy.
- The existing `litellm` schema in Postgres, which holds historical spend logs. The db-init line only affects a fresh database. Dropping the schema is a separate manual decision.
- The Cloudflare DNS record for `hindsight-litellm.alekseev.us`. With the ingress gone the tunnel answers `http_status:404`; deleting the record is a manual Cloudflare step outside this repo.

### 5.4 Secret-file override hazard

The container entrypoint is `sh -c "set -a; . /run/secrets/hindsight_env; set +a; exec /app/start-all.sh"`, so `/mnt/spool/apps/config/hindsight/env` is sourced **after** compose `environment:` is applied and therefore **wins** on any key it defines. The proxy-era setup very likely put `HINDSIGHT_API_LLM_API_KEY` (the litellm master key) there, and possibly `HINDSIGHT_API_LLM_MODEL` / `_BASE_URL`.

Any `HINDSIGHT_API_LLM_*` line in that secret must be deleted, or this change silently does nothing while appearing correct in git. The secret keeps only genuine secrets (tenant API key, CP keys, DB URL); all LLM routing and tuning lives in the YAML as the single source of truth.

## 6. Credential handling

1. Create `/mnt/spool/apps/config/hindsight/codex` on silverstone, owned `568:568`, mode `0700`.
2. Copy `auth.json` from a machine with a **live** codex login into that directory, `chown 568:568`, `chmod 600`.
   - The chosen source is a workstation whose codex CLI is currently working. Note `~/.codex/auth.json` on the 192.168.1.147 box is dated **May 30** — older than silverstone's Jun 10 orphan — so it is not the preferred source.
   - The Jun 10 orphan at `.../litellm/chatgpt-tokens/auth.json` is **not** used; it stays where it is as an untouched artifact of the removed proxy.
3. Accepted risk (user-confirmed): the copied refresh chain is shared with the source machine's codex CLI. Refresh tokens are single-use, so whichever side refreshes first invalidates the other. Symptom is `refresh_token_reused` on reflect while recall and `/health` stay green. Remedy if it bites: a dedicated `codex login` into the container's `CODEX_HOME` on silverstone, which removes the sharing entirely.

## 7. Failure modes

| Condition | Behavior |
|---|---|
| luna 429 / quota exhausted | one attempt, then vLLM. No cooldown exists in failover mode, so every subsequent call re-tries luna first — one wasted attempt per call for as long as the limit holds. |
| luna model-not-found (§3 risk) | falls through to vLLM, but deterministically wastes an attempt on every call. Must be caught by the §8 probe, not left in production. |
| `refresh_token_reused` | reflect fails; recall, retain and `/health` unaffected. Fix per §6.3. |
| vLLM box down, luna healthy | primary serves everything; no impact. |
| vLLM box down **and** luna failing | operation fails — there is no third member by design. |
| retain batch | runs on the first batch-capable member in declared order and does not fail over mid-batch. |

## 8. Verification

1. **Static:** `./scripts/validate-stack.sh hindsight`.
2. **Model probe (gates everything):** after deploy, confirm the primary actually serves `gpt-5.6-luna` from this account/host — a real retain or reflect call that succeeds *and* whose logs show the primary member, not member 1. If luna is rejected, pin `gpt-5.5` or `gpt-5.3-codex` and re-probe; if no Codex model works, switch to the §3 litellmrouter fallback plan.
3. **Failover test:** point `CODEX_HOME` at an empty directory temporarily (or stop the vLLM box for the reverse case) and confirm the chain advances to member 1 rather than erroring.
4. **Token rotation check:** after the first successful call, `stat` the mounted `auth.json` — an updated mtime proves the container can write its rotated token back.
5. **Regression:** `/health` green, recall latency sane, no `hindsight-litellm` references left in logs.

## 9. Rollback

`git revert` the commit and redeploy. The proxy's host-side config, Copilot tokens and Postgres schema were never removed, so the previous routing comes back intact. The only non-reverting side effect is any Codex token refresh that already happened in the new `CODEX_HOME`.

## 10. Security actions (out of band, not part of the stack change)

Reading the live proxy config exposed credentials in a session transcript. These must be rotated independently of this work:

- The `sk-svcacct-…` OpenAI service-account key, hardcoded twice in `config.yaml` (`openai/gpt-5.4-mini` and `openai/text-embedding-3-small`). The commented-out `openai.prod.ai-gateway.quantumblack.com` base URL beside it suggests an employer-issued credential, which makes rotation mandatory rather than discretionary.
- The litellm `general_settings.master_key`, reused verbatim as `ui_password`.

Both live only in the on-host `config.yaml`, never in git. Since the proxy is being removed, rotation is cleanup rather than reconfiguration — but the key remains valid until revoked at the provider.

## 11. Follow-ups (explicitly out of scope)

- Re-homing the Copilot / `claude-*` / embedding aliases somewhere else, if they turn out to have consumers.
- Deleting the Cloudflare DNS record and the stale on-host `litellm/` directory once the change is proven.
- Dropping the historical `litellm` Postgres schema.
- Quota protection via per-operation chains, if luna-for-everything proves too expensive.
