# Google AI Pro subscription gateway (CLIProxyAPI + Oh My CPA) — Design Spec

- **Date:** 2026-11-26
- **Status:** Approved 2026-11-26. Ready for implementation planning.
- **Stack file:** `stacks/cliproxyapi.yaml` (new)
- **Author:** brainstormed with Claude Code
- **Host facts:** not yet verified on silverstone; every host-dependent value below is marked *(verify)* and is checked by the plan.

---

## 1. Goal & framing

Run a second subscription gateway next to codex-lb that pools Google AI Pro accounts through Antigravity OAuth and serves an OpenAI-compatible `/v1` endpoint on `shared-services`, with one dashboard for both account management and usage history, exposed at a single Cloudflare Access hostname.

This first phase is a **test**: two non-primary Google accounts, low volume, about one week. It answers two questions before anything depends on the gateway:

1. Does Antigravity OAuth work from a headless container behind Cloudflare (§8)?
2. Do the accounts get flagged (`403` ToS) under light, human-shaped use?

Not a goal in this phase:

- Claude subscription OAuth. Anthropic has prohibited subscription OAuth in third-party harnesses since early 2026 (clarified February, enforced from April).
- Family members' Google accounts.
- Remote access over the overlay network (option B). It is a later network attachment on `cliproxyapi` (§11).
- Wiring hindsight, nod or any other consumer.
- Replacing codex-lb for ChatGPT/Codex. The 2026-11-17 codex-lb decision (static key list, no per-key limits, cross-account `previous_response_id` issue #1382) still stands for that pool.

**Accepted risk (user-confirmed):** Google AI forum threads report `403` ToS suspensions of Gemini CLI / Antigravity access, including AI Pro subscribers, when accounts are used through third-party tools. The test uses non-primary accounts so a suspension costs nothing important.

## 2. Decision: CLIProxyAPI + Oh My CPA

Compared 2026-11-26:

| | 9router | CLIProxyAPI (CPA) | sub2api / claude-relay-service | Antigravity-Manager |
|---|---|---|---|---|
| Fit | Personal local router, Next.js, ~2.9k open issues, test suite expected red | Go, MIT, 59k★, ~140 open issues, releases several times a day | Built for resale and account sharing; Postgres + Redis | Tauri desktop app |
| Antigravity | Yes | Yes (Gemini CLI, AI Studio, Vertex too) | Gemini, not Antigravity-focused | Yes |

CPA wins on robustness and scope. It has no usable dashboard of its own for this purpose: the bundled Management Center is downloaded from GitHub at runtime and keeps no usage history. Dashboards compared:

| | Management Center (bundled) | cpa-usage-keeper | CPA-Manager-Plus | **Oh My CPA (OMC)** |
|---|---|---|---|---|
| Manages accounts/config | Yes | No | Yes | Yes |
| Persistent usage history | No | Yes | Yes | Yes |
| Login | Management key | Password or OIDC | Admin/management key | CPA management key |
| Notes | Runtime GitHub download | Needs a second UI for management | Older, larger user base | AES-GCM at rest, audit log, pre-write config backups, non-root + read-only rootfs by default, Antigravity quota module |

The user wants a single dashboard URL, which rules out Keeper. OMC was chosen over CPA-Manager-Plus as the more featureful option, accepting that it is younger (created 2026-09, v0.4.x, near-daily releases).

## 3. Topology

```
hindsight / tools ─ shared-services ─► cliproxyapi:8317/v1 ──► Google account A, B (Antigravity)
                                              ▲ /v8/management (key)
                                  cpa-internal│ (internal: true)
                                              │
     Cloudflare Access ─► cloudflared ─ cpa-edge /29 ─► omc:8080   cpa.alekseev.us
```

- No host ports are published. CPA's OAuth callback ports (`8085`, `1455`, `54545`, `51121`, `11451` in upstream compose) are never published.
- OMC is **not** on `shared-services`: its login and its `/api/mcp` endpoint are reachable only through Cloudflare Access.
- **Accepted exposure:** CPA serves `/v1` and `/v8/management` on the same port, and OMC needs `management.allow-remote: true`, so the management API is reachable from `shared-services`, protected by the management key (CPA stores a hash). This matches codex-lb's fallback login on `:2455`. The key is long and random.

## 4. `stacks/cliproxyapi.yaml`

### 4.1 Services

**`cliproxyapi`**
- Image `eceasy/cli-proxy-api:<semver>` (published by upstream's own `docker-image.yml`), pinned to the newest release at implementation time (v8.1.7 today) and tracked by Renovate.
- `user: "568:568"`. The image is Debian, runs as root and expects `/root/.cli-proxy-api`; `auth-dir` is moved to the config dataset. If the binary cannot run as 568, fall back to root with `cap_drop: ALL` and `no-new-privileges`, and record why. *(verify)*
- `TZ` overridden (the image bakes `Asia/Shanghai`).
- Healthcheck: `GET /healthz` through bash `/dev/tcp` (the image has no curl/wget), as in OMC's `compose.full.yml`.
- Networks: `shared-services` (external), `cpa-internal`.

**`omc`**
- Image `wiziscool/oh-my-cpa:<semver>`, pinned (v0.4.14 today), Renovate.
- `read_only: true`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, as upstream.
- `user: "568:568"` in place of the image's `10001`, if the data directory is all it writes. *(verify)*
- `depends_on: cliproxyapi: service_healthy`.
- Networks: `cpa-internal`, `cpa-edge`.
- **Not deployed:** `oh-my-cpa-updater` (it mounts the Docker socket). Renovate does updates.

**`cloudflared`**
- Same shape as codex-lb: `user: 568:568`, inline `configs:` ingress, credentials from the config dataset.
- Ingress `cpa.alekseev.us` → `http://omc:8080` with `originRequest.access.required: true`, `teamName: alekseev`, and the new Access application's `audTag`; then `http_status:404`.
- Network: `cpa-edge` only.

**Networks**
- `cpa-internal`: `internal: true` bridge (no egress), CPA ↔ OMC.
- `cpa-edge`: fixed IPv4 `/29`, `enable_ipv6: false`, as codex-lb-edge. Proposed `172.31.255.240/29`, directly below codex-lb's `.248/29`, chosen after checking the daemon's networks for collisions. *(verify)*
- `shared-services`: external.

### 4.2 CPA `config.yaml` (on the config dataset; OMC writes it)

| Key | Value | Why |
|---|---|---|
| `management.allow-remote` | `true` | OMC reaches CPA from another container |
| `management.secret-key` | empty; set via `MANAGEMENT_PASSWORD` from the secret env file *(verify precedence)* | keep the key out of the YAML OMC edits |
| `management.disable-control-panel` | `true` | no runtime panel download; OMC is the UI |
| `observability.usage.usage-statistics-enabled` | `true` | OMC's usage collector |
| request log | `false` | prompts stay out of logs |
| `routing.strategy` | `round-robin`, session affinity on (defaults) | |
| `server.trusted-proxies` | `[]` | no proxy sits in front of `/v1` |
| `server.discovery.enabled` | `false` | no mDNS |
| `access.api-keys` | one test key for this phase | one key per consumer later |
| `oauth.auth-dir` | config dataset path | refresh tokens off the image's `/root` |

### 4.3 OMC environment

| Variable | Value |
|---|---|
| `OMCPA_CPA_BASE_URL` | `http://cliproxyapi:8317` |
| `OMCPA_PUBLIC_URL` | `https://cpa.alekseev.us` (makes the session cookie `Secure`) |
| `OMCPA_TRUSTED_PROXY_CIDRS` | the `cpa-edge` /29 |
| `OMCPA_UPDATER_ENABLED` | `false` |
| `OMCPA_UPDATE_CHECK_ENABLED`, `OMCPA_UPDATE_CHECK_ON_PAGE_LOAD` | `false` |
| `OMCPA_DATA_DIR` | `/data` (data dataset) |
| `TZ` | host zone |
| `OMCPA_CPA_MANAGEMENT_KEY`, `OMCPA_MASTER_KEY` | secret env file (§4.5) |

**Off by policy** (UI settings, not env; confirmed at deploy):
- **Quota window warmup.** It sends scheduled synthetic requests; that pattern is a likely ban trigger.
- **Agent.** No environment switch is documented; it stays inert with no model selected. *(verify whether it can be disabled)*
- **Plugins.** OMC's own docs say plugin pages can reach CPA's raw config, including the management key.

### 4.4 Storage (ZFS datasets, created like `spool/apps/{config,data}/codex-lb`) *(verify)*

| Dataset | Container path | Holds |
|---|---|---|
| `spool/apps/config/cliproxyapi` | CPA config dir | `config.yaml`, `auths/` (**Google refresh tokens, plaintext**, mode 0700), `env` (0600), `cloudflared/tunnel.json` |
| `spool/apps/data/cliproxyapi` | OMC `/data`; CPA logs and `kv.db` | OMC SQLite (encrypted with the master key), CPA runtime state |

Back up both together: OMC's database is unreadable without `OMCPA_MASTER_KEY`, and `auths/` is the only copy of the account logins.

### 4.5 Secrets

Nothing in git and nothing in Portainer env. One Docker-secret env file, `/mnt/spool/apps/config/cliproxyapi/env`, sourced in each entrypoint with `set -a; . /run/secrets/cliproxyapi_env; set +a`, as in hindsight and nod (`env_file:` fails at Portainer parse time):

- `MANAGEMENT_PASSWORD` and `OMCPA_CPA_MANAGEMENT_KEY`: the same value.
- `OMCPA_MASTER_KEY`: `openssl rand -hex 32`; never rotated once data exists.

Both images have `sh` (Debian, Alpine). OMC's read-only rootfs does not block sourcing.

## 5. Authentication model

| Surface | Reachable from | Guard |
|---|---|---|
| OMC console + `/api/mcp` | Cloudflare Access only | Access policy (one email) + origin JWT check in cloudflared, then OMC login = CPA management key |
| CPA `/v1/*` | `shared-services` | client key in `access.api-keys` |
| CPA `/v8/management` | `shared-services`, `cpa-internal` | management key |

There is no SSO inside OMC (no OIDC or trusted-header mode). Cloudflare Access plus the key gives two layers, but the key is a shared secret to look after.

## 6. Failure modes

- **Antigravity login cannot complete headless.** Stop the test and decide between the laptop route (log in with a local CPA, copy the auth JSON into `auths/`) and abandoning. No callback port is published as a workaround.
- **`403` ToS from Google.** Stop traffic on that credential, revoke the app in the account's security settings, and record it here. Two `403`s end the experiment.
- **OMC release breaks against CPA.** Both are pinned; Renovate PRs are tested together. OMC's pre-write config backups cover a bad config write.
- **Master key lost.** OMC history is gone; CPA keeps working, and accounts survive in `auths/`.

## 7. Verification

1. `./scripts/validate-stack.sh cliproxyapi` passes.
2. Both containers healthy. `cliproxyapi` is unreachable from the host and from cloudflared's network; `omc` is unreachable from `shared-services`.
3. `https://cpa.alekseev.us` → Access challenge → OMC login with the management key.
4. Both Google accounts added through OMC (§8); quota shows for both.
5. From a throwaway container on `shared-services`: `/v1/models` lists Antigravity models; one chat completion succeeds, and again with the test key removed (expect `401`).
6. OMC shows the requests, per-account usage and Antigravity quota.
7. Warmup, Agent and plugins confirmed off.

## 8. Test protocol

1. Accounts: two non-primary Google accounts on AI Pro (non-trial). Not family members' main logins.
2. Login: OMC's OAuth page. The redirect is expected to land on `localhost:51121` in the laptop's browser and fail; paste the full callback URL back into OMC. This is the first unknown the test resolves.
3. Traffic: a handful of interactive-looking requests per day for about a week, from one test key. No load testing, no scripted loops.
4. Watch: OMC errors and quota, and `403` responses.
5. Exit: write the findings into an as-built section here, then decide whether to wire consumers.

## 9. Rollback

`docker compose -f stacks/cliproxyapi.yaml down`, revoke the app's access in each Google account, delete the Access application and tunnel, and destroy both datasets.

## 10. Naming

- Stack `stacks/cliproxyapi.yaml`; containers `cliproxyapi`, `cliproxyapi-omc`, `cliproxyapi-cloudflared`.
- Dashboard `cpa.alekseev.us`.
- Consumer base URL (later): `http://cliproxyapi:8317/v1`.

## 11. Follow-ups (explicitly out of scope)

- Remote `/v1` access over the overlay network: attach `cliproxyapi` to it, issue a separate client key.
- Per-consumer keys and wiring (hindsight failover member, nod).
- More accounts, if the test is clean.
- Claude: only via the Anthropic API, never subscription OAuth.
