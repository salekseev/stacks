# Shared ChatGPT/Codex subscription gateway (codex-lb) — Design Spec

- **Date:** 2026-11-17
- **Status:** Approved 2026-11-17. Ready for implementation planning.
- **Stack files:** `stacks/codex-lb.yaml` (new), `stacks/hindsight.yaml` (primary LLM cutover). `stacks/yandex-station.yaml` is wired in PR #169, not here.
- **Author:** brainstormed with Claude Code
- **Host facts verified:** silverstone (TrueNAS SCALE `26.0.0-BETA.3`) on 2026-11-17 by direct ssh inspection

---

## 1. Goal & framing

Pool several ChatGPT/Codex subscriptions behind one self-hosted, OpenAI-compatible gateway, and give each consuming stack its own API key against that pool. First consumers: hindsight (cut over in this change) and the yandex-station `processor` (wired in PR #169 once this merges).

Scope is ChatGPT/Codex subscriptions only. Not a goal:

- Pooling the Claude OAuth token Hermes uses (`ANTHROPIC_TOKEN` stays in Hermes).
- Routing the local vLLM box through the gateway (it stays each consumer's own failover member).
- A fallback LLM for the yandex brain.
- PostgreSQL for gateway state.

## 2. Hard constraint inherited from hindsight

`docs/superpowers/specs/2026-08-23-hindsight-codex-failover-design.md` §3 dropped LiteLLM because the ChatGPT backend serves `gpt-5.6-luna` only to Codex originators: a third-party originator gets `Model not found gpt-5.6-luna-free-1p-codexswic-ev3` on the same credentials (openai/codex#31967). Any gateway in front of the subscriptions must send a Codex originator upstream.

## 3. Decision: codex-lb

Candidates compared on 2026-11-17:

| | apache/casbin-gateway | Soju06/codex-lb | router-for-me/CLIProxyAPI |
|---|---|---|---|
| Purpose | Local desktop agent monitor + relay | ChatGPT/Codex account pool | Multi-vendor OAuth proxy (Codex, Claude Code, Gemini, Grok) |
| Codex originator upstream | Yes (`codexOriginator`) | Yes (`codex_cli_rs` / Desktop persona) | Yes (`codex_cli_rs`) |
| Server fit | Weak: `runmode = dev`, kills whatever holds its port, loopback admin auto-signed-in, no published image (build-only, so no Renovate pin), SQLite only | Strong: published `ghcr.io/soju06/codex-lb`, `/health/ready`, single-replica compose, SQLite default / Postgres optional | Good: Go, frequent releases |
| Client auth | Relay tokens, scoping undocumented | Per-key model allowlist, token/cost limits, account scoping, reasoning-effort policy | Static key list, no per-key limits |
| Pooling | Strategies + cooldown | Quota-aware (5 h / weekly windows), soft sticky threads, hard continuation affinity | Round-robin; cross-account `previous_response_id` issue (#1382) |
| Maturity | 650★, no releases | 3.4k★, MIT, Python | 59k★, MIT, Go |

codex-lb wins: it is the only candidate built to run as a server-side subscription pool, and per-key limits give each stack an independently capped, separately attributed identity. casbin-gateway is designed for one developer's workstation. CLIProxyAPI's multi-vendor breadth is out of scope (§1) and its client auth is weaker.

**Accepted risk (user-confirmed):** ChatGPT plans are licensed for individual use, and codex-lb's own routing guide states no strategy guarantees account safety. Pooling automated service traffic across subscriptions can get accounts flagged or suspended. Volume is low and the accounts belong to the operator, which reduces but does not remove that risk.

## 4. Topology

```
hindsight ─┐                                       ┌─ ChatGPT account A
processor ─┼─ shared-services ─► codex-lb:2455 ────┼─ ChatGPT account B
(future) ──┘   /v1 + per-stack key      ▲          └─ ChatGPT account C
                                        │ codex-lb-edge (dedicated /29)
          Cloudflare Access ─► cloudflared   dashboard: codex-lb.alekseev.us
```

- Clients reach codex-lb by container name over the existing external `shared-services` network, the same pattern Hermes uses for `http://hindsight:8888/api`.
- No host ports are published. Port 1455 (OAuth callback) is never exposed: accounts are added with codex-lb's device-code OAuth flow.
- Proxy routes and the dashboard share port 2455. They are separated by authentication (§6), not by port.

## 5. `stacks/codex-lb.yaml`

### 5.1 Services

**`codex-lb`**
- Image `ghcr.io/soju06/codex-lb:<semver>`, pinned to the newest published semver tag at implementation time and tracked by Renovate.
- `user: "568:568"` per repo convention. The image's own user is `app`. If the image cannot run as 568 (for example because its entrypoint writes outside the data directory), fall back to the image uid and chown both datasets to it. The plan verifies which applies.
- Healthcheck: `GET http://localhost:2455/health/ready`, mirroring upstream's `docker-compose.prod.yml`.
- Networks: `shared-services` (external) and `codex-lb-edge`.

**`cloudflared`**
- Same shape as hindsight's: `--config /etc/cloudflared/config.yml tunnel run`, `user: 568:568`, inline `configs:` ingress, credentials from the config dataset.
- Ingress: `codex-lb.alekseev.us` → `http://codex-lb:2455`, then `http_status:404`.
- Network: `codex-lb-edge` only.

**`codex-lb-edge`** is a stack-local bridge with a fixed `/29` IPAM subnet. The plan picks a subnet after checking existing Docker networks on silverstone for collisions.

### 5.2 Storage (ZFS datasets — created 2026-11-17)

Both created through TrueNAS middleware (`pool.dataset.create`, `share_type: APPS`, `atime: OFF`), matching `spool/apps/{config,data}/hindsight`: nfsv4 ACL, aclmode/aclinherit passthrough, xattr sa, lz4, recordsize 128K, owner `apps:apps` (568), mode 770.

| Dataset | Mount | Container path | Holds |
|---|---|---|---|
| `spool/apps/data/codex-lb` | `/mnt/spool/apps/data/codex-lb` | `/var/lib/codex-lb` | SQLite DB, archives (`CODEX_LB_DATA_DIR` default) |
| `spool/apps/config/codex-lb` | `.../config/codex-lb/codex-lb/` | `/etc/codex-lb` in `codex-lb` | `encryption.key` |
| | `.../config/codex-lb/cloudflared/` | `/etc/cloudflared/creds` in `cloudflared` | `tunnel.json` (tunnel credentials; same layout as hermes) |

Each container mounts only its own subdirectory, so codex-lb never sees the tunnel credentials and cloudflared never sees the key.

The encryption key lives apart from the encrypted account tokens, so a copy of the data dataset alone cannot decrypt anything. The two datasets must be snapshotted and backed up together: the DB is useless without the key.

### 5.3 Environment

| Var | Value | Why |
|---|---|---|
| `CODEX_LB_ENCRYPTION_KEY_FILE` | `/etc/codex-lb/encryption.key` | Fixed key location on the config dataset (§5.2) |
| `CODEX_LB_DASHBOARD_AUTH_MODE` | `trusted_header` | SSO via Cloudflare Access |
| `CODEX_LB_DASHBOARD_AUTH_PROXY_HEADER` | `Cf-Access-Authenticated-User-Email` | Identity header Cloudflare Access injects |
| `CODEX_LB_FIREWALL_TRUST_PROXY_HEADERS` | `true` | Required by `trusted_header` |
| `CODEX_LB_FIREWALL_TRUSTED_PROXY_CIDRS` | the `codex-lb-edge` subnet only | Containers on `shared-services` cannot forge the identity header |
| `CODEX_LB_TELEMETRY_ENABLED` | `false` | Default sends an anonymous snapshot to a third-party collector at start and every 24 h |

Dashboard-managed settings (not env, applied once after first start and listed in the plan):
- Local `admin` password set from the bootstrap token, TOTP enrolled, designated break-glass, then local sign-in policy → `break_glass_only`. Port 2455 is reachable from `shared-services`, so the password form must admit nothing but the TOTP-enrolled emergency account (only at `/login?local=1`). Host recovery CLI (`codex-lb admin reset-password`) remains for lockout.
- Trusted-header provider `unknownIdentityRoleId` → `null`, so a new Cloudflare Access identity gets no access until it is added explicitly.
- API Key Auth enabled.
- Routing strategy **Capacity weighted**, sticky threads on.
- Conversation archive stays off (its default).

### 5.4 Secrets

Nothing in git, nothing in Portainer env. Tunnel credentials and the encryption key live on the config dataset. The first-run bootstrap token is read once from `docker logs codex-lb`.

## 6. Authentication model

- **Proxy routes** (`/v1/*`, `/backend-api/codex/*`): bearer API key. One key per consumer, named after the stack (`hindsight`, `yandex`), restricted to the models that stack uses, with optional token caps.
- **Dashboard**: Cloudflare Access gates the hostname, and codex-lb trusts its identity header only from the `codex-lb-edge` subnet. Local admin password is the fallback.
- **Upstream accounts**: each subscription is logged in fresh through device-code OAuth in the dashboard. Copied `auth.json` files are never used, so each account's refresh-token chain belongs to codex-lb alone. This avoids the `refresh_token_reused` failure documented in the hindsight failover spec §6.

## 7. Consumers

### 7.1 Hindsight (this change)

| Var / mount | Action | Value / note |
|---|---|---|
| `HINDSIGHT_API_LLM_PROVIDER` | change | `openai` (was `openai-codex`) |
| `HINDSIGHT_API_LLM_BASE_URL` | add | `http://codex-lb:2455/v1` |
| `HINDSIGHT_API_LLM_MODEL` | keep | `gpt-5.6-luna` |
| `HINDSIGHT_API_LLM_API_KEY` | add, **in `/run/secrets/hindsight_env`** | the `hindsight` codex-lb key |
| `CODEX_HOME` | remove | codex-lb owns tokens now |
| `/mnt/spool/apps/config/hindsight/codex:/codex` | remove mount | host directory left in place for rollback |
| `HINDSIGHT_API_LLM_1_*`, `_STRATEGY`, `_MAX_RETRIES`, `_TIMEOUT`, `_MAX_CONCURRENT`, per-operation `*_REASONING_EFFORT` | keep | unchanged |

The 2026-08-23 rule "no `HINDSIGHT_API_LLM_*` in the secret file" is narrowed: routing and tuning stay in YAML as the single source of truth, and only `HINDSIGHT_API_LLM_API_KEY`, a real secret, goes in the secret file. The comment block above the LLM vars is rewritten to describe the new topology.

Hindsight already joins `shared-services`, so no network change is needed.

The hindsight account currently in `/codex/auth.json` joins the pool by being logged in fresh in codex-lb (§6), not by copying that file.

### 7.2 Yandex station (PR #169, after this merges)

- `processor` joins `shared-services` (declared `external: true`).
- `OPENAI_BASE_URL` default → `http://codex-lb:2455/v1`. `OPENAI_API_KEY` = the `yandex` key. The model is chosen in that PR.

### 7.3 Hermes

Unchanged. It stays on its Claude token.

## 8. Failure modes

| Condition | Behavior |
|---|---|
| codex-lb down | Hindsight fails over to vLLM member 1. The yandex brain has no fallback, so its LLM calls fail. Accepted. |
| All accounts quota-exhausted | codex-lb answers `No available accounts`. Hindsight fails over to vLLM. |
| Thread's owner account unavailable | Hard-affinity request fails; a fresh turn routes normally. Low impact: both consumers are mostly stateless chat. |
| Upstream token revoked for one account | Account goes ineligible; traffic routes to the rest of the pool. Re-login that account via device code. |
| Encryption key lost | Every stored account token is unreadable. Re-login every account. |
| Account flagged by OpenAI (§3 risk) | That account drops out of the pool. Remove it in the dashboard. |

## 9. Verification

1. **Static:** `./scripts/validate-stack.sh codex-lb` and `./scripts/validate-stack.sh hindsight`.
2. **Boot:** `/health/ready` green. The container user can write `/var/lib/codex-lb` and read `/etc/codex-lb/encryption.key`. `ls -ln` on the datasets shows files owned by the expected uid.
3. **Originator gate:** a `gpt-5.6-luna` completion through codex-lb succeeds. This repeats the §2 constraint check for the new transport.
4. **Proxy auth:** from inside the hindsight container, `GET /v1/models` with the hindsight key succeeds, the same request without a key returns 401, and a chat completion on `gpt-5.6-luna` succeeds.
5. **Reasoning effort:** hindsight's per-operation `reasoning_effort` reaches upstream. Check the codex-lb request log for effort on a reflect call.
6. **Hindsight primary:** a reflect call's logs show the primary member serving, not member 1.
7. **Failover:** stop codex-lb, confirm hindsight reflect falls through to vLLM, then restart codex-lb.
8. **Header forging:** from a `shared-services` container, a request to the dashboard API carrying a forged `Cf-Access-Authenticated-User-Email` gets no dashboard session.
9. **Pooling:** with two or more accounts added, dashboard request logs show traffic served by more than one account.

## 10. Rollback

- **Hindsight:** `git revert` the hindsight commit and redeploy. `/mnt/spool/apps/config/hindsight/codex/auth.json` was never touched. Its refresh token may have aged out if unused for a long time; if so, run `codex login` into that directory again.
- **Gateway:** independent of hindsight's rollback. Stop or remove the `codex-lb` stack. The ZFS datasets can be kept or destroyed.

## 11. Follow-ups (explicitly out of scope)

- Wire the yandex `processor` to codex-lb (PR #169).
- Move Hermes or Open WebUI onto codex-lb for OpenAI models, if wanted.
- A ZFS snapshot task covering both codex-lb datasets together.
- `hs-decide-1-flash` decision model for hindsight (consolidation, reflect, pages), self-hosted if it fits silverstone's GPU. See §12.

## 12. As-built (2026-11-18)

Gateway deployed from PR #185. Where the deployment differs from §5–§7, this section wins.

**Dashboard lock-down (supersedes the `break_glass_only` and unknown-identity-role parts of §5.3).** The doc pages used during design describe codex-lb's `main` branch. The deployed `1.24.0` has none of local sign-in policy, break-glass designation, unknown-identity default role, or Organisation settings: its `app/modules` has no `auth_providers`/dashboard-users module, and its `docs/authentication.md` names none of them. 1.24.0 is single-admin: any identity that arrives through cloudflared is admin, narrowed only by the Cloudflare Access policy, which allows one email. The fallback form on :2455 is reachable from `shared-services`, so it is hardened with what 1.24.0 has:
- local password set, TOTP enrolled, **Require TOTP on login** on;
- API key authentication on;
- dashboard session lifetime 720 h (down from the 8760 h default);
- guest access off. Telemetry is pinned off by `CODEX_LB_TELEMETRY_ENABLED`.

Verified from the settings table, read-only. Revisit `break_glass_only` when Renovate brings codex-lb ≥ 1.25.

**Trust boundaries verified** before bootstrap, from `shared-services`:
- `/v1/models` with no key returns `401`;
- `/api/accounts` with a forged `Cf-Access-Authenticated-User-Email` returns `401`, the same as with no header;
- the edge hostname without an Access session returns `302` to the Access login.

The edge network is IPv4-only (`EnableIPv6=false`, `172.31.255.248/29`). The container runs as `568:568` with no uid fallback. `encryption.key` lives only on the config dataset.

**Pool.** Three accounts, all active: three distinct users across two ChatGPT workspace accounts, plans `business`/`team`/`team`. Per-account routing policies are `preserve`, `normal` and `burn_first`. These are workspace seats, so the workspace admins' visibility and terms apply (operator to confirm none is an employer seat).

**Hindsight key.**
- Traffic class `opportunistic`: per codex-lb `app/core/balancer/logic.py`, it may only use expendable capacity (`burn_first` → `normal` → `preserve`, subject to reserve floors) and is otherwise refused with `opportunistic burn window closed`. That refusal falls through to vLLM member 1.
- Model allowlist: `gpt-5.6-luna`, `gpt-6-luna`.
- Probes from inside the hindsight container: `gpt-5.6-luna` returns `200 "OK"`; `gpt-6-luna` at `high` and at `medium` returns `200 "OK"`; `gpt-5.5` returns `403 model_not_allowed`.
- The future yandex key should be `foreground`: it is latency-sensitive with no failover.

**Hindsight primary model (supersedes §7.1's `keep gpt-5.6-luna`): `gpt-6-luna`.** codex-lb's model registry describes it as "Fast and affordable model for easier tasks" (272k context, default effort medium, levels low…max, same as 5.6-luna). Hindsight's reflect leaderboard scores it 89.3 at $4.12/1k cases, against gpt-5.6-luna's 86.7 at $7.46. `gpt-6.1-terra` was rejected: the registry describes it as tuned for "visual understanding and computer use", and it scores 78.7 at $47/1k.

**Hindsight cutover verified (Task 12).** After the redeploy:
- the env shows `openai` / `codex-lb` / `gpt-6-luna`, there is no `CODEX_HOME` and no `/codex` mount, and `/health` is healthy;
- a real reflect was served by the primary; codex-lb logged 5 `gpt-6-luna` calls at effort `high`, and consolidation at `medium`, all `success`.

**Failover defect found, and fixed in the next PR.** With codex-lb stopped, the chain did advance to member 1. vLLM `gemma-4-12b` then answered `400 "response_format json_object/json_schema is not supported (no constrained decoding)"`, so reflect failed. This existed before the cutover, but the `opportunistic` key makes it routine: any pool refusal would fail reflect. The fix:
- primary `HINDSIGHT_API_LLM_PROVIDER: openai-responses`. This is hindsight 1.2.1's `OpenAIResponsesLLM`, which sends `/v1/responses`, `store=False`, `reasoning={"effort":…}`, `text.format`. Probed through codex-lb with the hindsight key: strict `json_schema` plus `reasoning.effort=high` returned 200 `{"city":"Paris"}`;
- `HINDSIGHT_API_LLM_OPENAI_COMPATIBLE_JSON_MODE: "false"`. It is global, but only `openai_compatible_llm.py` reads it, so it moves member 1 to schema-in-prompt without touching the primary. `_parse_llm_members` has no per-member variant.

**Tooling note.** `hindsight:1.2.1-slim` ships no `curl`; in-container probes use `python3` with `urllib`.

**Embeddings.** The subscriptions cannot serve embeddings; the Codex backend has none. codex-lb's `/v1/embeddings` forwards only to separately configured model sources. Hindsight keeps local TEI. `HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY` and the LiteLLM comment blocks in hindsight's secret file are unused leftovers.

**hs-decide-1-flash feasibility (follow-up input).** silverstone's GPU is an NVIDIA RTX A400 (4 GB). About 1.4 GB is used by Frigate, ffmpeg and two TEI routers, which leaves about 2.6 GB. A 0.8B bf16 model needs about 1.6 GB for weights alone. It only fits with a reduced `--max-model-len`, a lowered `--gpu-memory-utilization`, `--enforce-eager`, and `HINDSIGHT_API_DECISION_MODEL_MAX_REQUEST_TOKENS` sized to match. The card has no FP8. Frigate memory spikes are the main risk. The follow-up spec must measure before committing.

## 13. Patched image (2026-11-21)

The stack runs `ghcr.io/salekseev/codex-lb:1.24.0-pr2692`, built here from the published 1.24.0 image plus the one-file change of upstream PR soju06/codex-lb#2692 (`stacks/codex-lb/Dockerfile`, `.github/workflows/codex-lb-image.yml`).

**Defect.** The nod stack calls codex-lb over Chat Completions. codex-lb converts those requests to the Responses API and passed an omitted tool `strict` flag through unchanged. Chat Completions treats omitted as non-strict; Responses treats it as strict. Nod's `pay` tool schema (allOf + anyOf) cannot be compiled strictly, so any request carrying it failed with `400 invalid_json_schema` ("required property 'fields' is unsatisfiable"). Probed through the gateway with the nod key: `strict` omitted returned 400, `strict: false` returned 200. Upstream issue soju06/codex-lb#2691.

**Scope.** Only `app/core/openai/chat_requests.py` changes, and only the chat-completions path calls `_normalize_chat_tools`. Hindsight uses `/v1/responses` and is not affected. Yandex-station and nod use chat completions; for them an omitted `strict` now means `false`, which is the Chat Completions default.

**Deployed and confirmed (2026-11-22 04:45 UTC).** The same `pay` schema probe through the redeployed gateway returns 200 with `strict` omitted, 200 with `strict: false`, and still 400 `invalid_function_parameters` with `strict: true`. Hindsight and nod both succeed afterwards. A confirmation was posted on soju06/codex-lb#2692.

**Restart behaviour found during this deploy.** Every request failed with `400 model_not_found` ("The '<model>' model is not supported when using Codex with a ChatGPT account") from 04:45:25 to 04:50:38 UTC: 104 hindsight calls and 4 nod calls. This is not caused by the patch. On start, codex-lb's upstream header build uses `CodexVersionCache.cached_version_or_default()`, which returns the bundled `model_registry_client_version` (`0.144.0`) until the model-registry refresh warms the cache with the current Codex release (`0.171.0` at the time). Upstream rejects current models for the old client version. The first refresh cycle after start only applied the persisted snapshot; the next one runs 300 s later (`_REFRESH_INTERVAL_SECONDS`) and fixed it without intervention. Expect about five minutes of failures after any codex-lb restart, including Renovate bumps. A second restart does not help. Overriding the fallback version through the environment may avoid it; the variable name was not verified.

**Exit.** Renovate bumps the `FROM` line in `stacks/codex-lb/Dockerfile`. When a release contains the fix, the `patch` step fails the build. Then delete the Dockerfile, the workflow and the Renovate rule, and point the stack back at `ghcr.io/soju06/codex-lb`.
