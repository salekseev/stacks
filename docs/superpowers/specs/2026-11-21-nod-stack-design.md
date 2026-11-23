# Nod personal AI assistant stack — Design Spec

- Date: 2026-11-21
- Status: approved in brainstorming, pending spec review
- Stack file: `stacks/nod.yaml`
- Upstream: <https://github.com/n8n-io/nod> (Apache-2.0, "early preview"), self-host docs <https://nod.n8n.io/docs/deploy/self-host/>
- Upstream pin at design time: `1b42e689a814a4acff13f0aff7d32070214f109a` (short `1b42e68`)

## 1. Goal

Run Nod (n8n's single-user AI assistant with its own Linux workspace and
browser) on silverstone as a Portainer-deployed stack. Nod reaches its LLM
through the existing codex-lb gateway with an API key that belongs to Nod alone.

Out of scope: voice (needs a real OpenAI key), Telegram webhook mode and
WhatsApp Cloud mode (need extra public webhook handling), Nebula/defined.net
access (deferred), a Postgres dump sidecar (follow-up).

## 2. Constraints found during exploration

1. **Upstream publishes no images.** `nod-server`, `nod-browser` and
   `nod-workspace` are built from source by `deployment/self-host/compose.yaml`.
   Portainer's Git deploy cannot build (`stacks/yandex-station.build.yaml` header).
2. **Portainer cannot resolve relative binds or `env_file`.** Upstream binds
   `./docker-proxy.mjs` into the `runtime` service and loads `.env` via
   `env_file`. Both must be replaced.
3. **Nod requires an exact HTTPS origin** in `NOD_PUBLIC_URL` for any
   non-loopback access, checks the `Host` header itself, and ignores forwarded
   headers. The proxy must preserve `Host` and support WebSockets and streaming.
4. **The `compatible` provider speaks OpenAI Chat Completions**
   (`api: 'openai-completions'`, upstream `src/providers/pi/models.ts`). It
   discovers models from `GET <base>/models`, requires streaming and tool calls,
   and wants at least 64,000 tokens of context. codex-lb already serves this
   shape to the yandex-station processor.
5. **Nod containers do not run as `568:568`.** Server, browser and workspace run
   as `node` (uid 1000). The workspace also executes commands as uids
   20000–59999 with gid 1002. Only Postgres can follow the repo's `568` convention.
6. **`workspace-tools:/home/node` relies on named-volume copy-up** from the
   `nod-workspace` image. A plain host bind would start empty.

## 3. Decisions

| Topic | Decision | Why |
|---|---|---|
| Shape | Faithful port of upstream's six services plus `cloudflared` | Keeps upstream's isolation (workspace firewall, Docker-socket allowlist proxy, read-only root, dropped capabilities) |
| Images | Built in GitHub Actions from a pinned submodule, pushed to `ghcr.io/salekseev/nod-*` | Same pattern as `v3rt3p-images.yml`; Portainer only pulls |
| LLM | `compatible` provider → `http://codex-lb:2455/v1`, model `gpt-6.2-sol`, dedicated codex-lb key | User requirement; isolates Nod's usage and limits |
| Postgres | `postgres:18-alpine`, `568:568`, `PGDATA` subdirectory | Matches other stacks; upstream tests on 17 |
| Access | Dedicated Cloudflare tunnel, public hostname, **no** Cloudflare Access; gate is `NOD_AUTH_TOKEN` | Desktop app and browser both work; Nebula deferred |
| Secrets | Host files loaded as Docker secrets, sourced by an entrypoint wrapper | hindsight pattern; nothing in git or Portainer env |
| Storage | ZFS datasets, mounted as named volumes with bind driver options | ZFS snapshots plus the copy-up behaviour of constraint 6 |

Rejected: a slimmed port without `runtime` and `workspace-network` (removes the
guards that matter most for a public agent with a shell); running upstream's
compose by hand on the host (outside Portainer, Renovate and ZFS conventions).

## 4. Images

### 4.1 Source pin

Add `n8n-io/nod` as a git submodule at `stacks/nod/upstream`. The tag contract
is the one `v3rt3p-images.yml` uses: every image is tagged with the 7-character
short SHA of the submodule pin, and `stacks/nod.yaml` references the same tag.
Bumping Nod is one commit that moves the submodule and the four tags.

Add a Renovate package rule next to the existing v3rt3p rule so the `nod-*`
images are not looked up as Docker tags.

*Superseded 2026-11-22; see section 14.* The submodule is gone and the image
tags carry the upstream release version.

### 4.2 Workflow `.github/workflows/nod-images.yml`

Modeled on `v3rt3p-images.yml`: pull requests build without pushing; pushes to
`master` push to GHCR; `workflow_dispatch` is available. Path filters:
`stacks/nod/**`, `stacks/nod.yaml`, the workflow file. Platform `linux/amd64`.

| Image | Build context | Dockerfile |
|---|---|---|
| `ghcr.io/salekseev/nod-server` | `stacks/nod/upstream` | `deployment/self-host/Dockerfile` |
| `ghcr.io/salekseev/nod-browser` | `stacks/nod/upstream` | `Dockerfile.browser` |
| `ghcr.io/salekseev/nod-workspace` | `stacks/nod/upstream` | `Dockerfile.workspace` |
| `ghcr.io/salekseev/nod-runtime` | `stacks/nod/upstream/deployment/self-host` | `stacks/nod/runtime.Dockerfile` (ours) |

`stacks/nod/runtime.Dockerfile` is the same digest-pinned
`node:24.21.0-bookworm-slim` base upstream uses for `runtime`, plus
`COPY docker-proxy.mjs /app/docker-proxy.mjs`. It replaces the relative bind
mount. Its context is narrower than the others because upstream's root
`.dockerignore` excludes `docker-proxy.mjs`.

The `server` healthcheck (`/app/healthcheck.mjs`) authenticates with
`NOD_AUTH_TOKEN`. Healthchecks see the container's configured environment, not
variables the entrypoint sourced, so the healthcheck command sources the same
secret file.

The packages must be public (or silverstone must be logged in to GHCR) before
the first deploy. Nod is Apache-2.0, so publishing the images is permitted.

## 5. `stacks/nod.yaml`

### 5.1 Services

Upstream hardening is kept verbatim on every service: `init`, `read_only`,
`cap_drop: [ALL]`, `no-new-privileges`, `pids_limit`, `mem_limit`, tmpfs mounts,
healthchecks, `depends_on` conditions.

| Service | Image | Notes |
|---|---|---|
| `server` | `nod-server:<sha>` | Port 4310, not published. Entrypoint wrapper sources the env secret (5.4). Networks: `backend`, `control`, `outbound`, `shared-services`, `nod-edge` |
| `postgres` | `postgres:18-alpine` (digest-pinned) | `user: 568:568`, `PGDATA=/var/lib/postgresql/data/pgdata`, password from secret file. Network: `backend` |
| `runtime` | `nod-runtime:<sha>` | Mounts `/var/run/docker.sock`. Allowlists `exec` and `inspect` on the two named containers only. Network: `control` |
| `browser` | `nod-browser:<sha>` | `container_name: nod-browser-nod`, `shm_size: 512m`. Network: `browser` |
| `workspace` | `nod-workspace:<sha>` | `container_name: nod-workspace-nod`, `network_mode: service:workspace-network` |
| `workspace-network` | `nod-workspace:<sha>` | `NET_ADMIN` firewall sidecar, DNS `1.1.1.1`/`8.8.8.8`. Upstream's `pull_policy: never` is dropped. Network: `workspace` |
| `cloudflared` | `cloudflare/cloudflared:2026.11.1` | Same shape as the codex-lb tunnel, without the Access block. Network: `nod-edge` |

Upstream's optional Caddy `https` service is omitted.

Memory limits use upstream defaults as literals: server `2g`, browser `3g`,
workspace `2g`.

### 5.2 Networks

- `backend` (internal): server ↔ postgres
- `control` (internal): server ↔ runtime
- `outbound`: server egress
- `browser`: browser egress
- `workspace`: workspace egress through the firewall sidecar
- `shared-services` (external): server → `codex-lb:2455`
- `nod-edge`: cloudflared ↔ server

No host ports are published. The workspace firewall blocks private IPv4
destinations, so the workspace and the browser cannot reach codex-lb or other
LAN services; only `server` joins `shared-services`.

### 5.3 Environment (non-secret, in the YAML)

```yaml
NODE_ENV: production
NOD_ENVIRONMENT: production
NOD_HOST: 0.0.0.0
PORT: "4310"
NOD_DATA_ROOT: /var/lib/nod
NOD_PUBLIC_URL: https://nod.alekseev.us
DOCKER_HOST: tcp://runtime:2375
WORKSPACE_CONTAINER: nod-workspace-nod
BROWSER_CONTAINER: nod-browser-nod
LLM_PROVIDER: compatible
OPENAI_COMPATIBLE_BASE_URL: http://codex-lb:2455/v1
LLM_MODEL: gpt-6.2-sol
NOD_ANALYTICS_ENABLED: "false"
NOD_FEEDBACK_ENABLED: "false"
NOD_ONBOARDING_EMAIL_URL: ""
```

`NOD_TRUST_MODEL` stays at its default (`selected`), so action checks also run
on `gpt-6.2-sol` through codex-lb. `LLM_MODEL` only sets the initial choice; a
model picked in Nod's UI takes priority.

The hostname `nod.alekseev.us` is an assumption that follows
`codex-lb.alekseev.us`.

### 5.4 Secrets

Two host files, declared as Compose `secrets` so the daemon resolves the paths:

| File | Owner, mode | Used by | Contents |
|---|---|---|---|
| `/mnt/spool/apps/config/nod/env` | `1000:1000`, `0600` | `server` | `NOD_AUTH_TOKEN`, `NOD_VAULT_KEY`, `NOD_POSTGRES_PASSWORD`, `OPENAI_COMPATIBLE_API_KEY` |
| `/mnt/spool/apps/config/nod/db_password` | `1000:568`, `0640` | `postgres` | the same Postgres password, via `POSTGRES_PASSWORD_FILE` |

uid 1000 is also the host admin account on silverstone, so these files are
editable without sudo; the uid 568 containers read through group 568. The two
dataset roots are `1000:568`, `0770`, and `config/nod/cloudflared` is setgid
(`2750`) so `tunnel.json` inherits group 568 (it needs mode `0640`).

The `server` entrypoint becomes:

```sh
set -a; . /run/secrets/nod_env; set +a
export DATABASE_URL="postgresql://nod:${NOD_POSTGRES_PASSWORD}@postgres:5432/nod"
exec node --import tsx src/server/index.ts
```

Generation, matching upstream `setup.sh` rules:

- `NOD_AUTH_TOKEN`: `openssl rand -hex 32`
- `NOD_VAULT_KEY`: `openssl rand -base64 32`. Never rotate it once data exists;
  it encrypts saved credentials.
- `NOD_POSTGRES_PASSWORD`: `openssl rand -hex 32` (URL-safe, so it can be
  embedded in `DATABASE_URL` unescaped)
- `OPENAI_COMPATIBLE_API_KEY`: created in the codex-lb dashboard (section 6)

Tunnel credentials live in `/mnt/spool/apps/config/nod/cloudflared/tunnel.json`
(`568:568`).

### 5.5 Storage

ZFS datasets under `/mnt/spool/apps/data/nod/`:

| Dataset dir | Mounted at | Owner |
|---|---|---|
| `server` | `server:/var/lib/nod` | `1000:1000` |
| `workspaces` | `server:/var/lib/nod/workspaces`, `workspace:/workspace` | `1000:1000` |
| `workspace-tools` | `workspace:/home/node` | `1000:1000` |
| `browser` | `browser:/data` | `1000:1000`, mode `0700` |
| `postgres` | `postgres:/var/lib/postgresql/data` | `568:568` |

The four Nod data directories are declared as named volumes with
`driver_opts: {type: none, o: bind, device: <path>}`, which keeps Docker's
copy-up into an empty volume. Postgres uses a plain bind like hindsight.

Backup: ZFS snapshots of `data/nod` together with `config/nod`. The database is
useless without `NOD_VAULT_KEY`.

## 6. codex-lb key

Created by hand in the codex-lb dashboard, named `nod`:

- allowed model: `gpt-6.2-sol` only
- a token limit chosen by the operator. Nod reports "No price" for compatible
  servers and does not count their usage toward its own spending limits, so the
  codex-lb limit is the only spend guard.

No change to `stacks/codex-lb.yaml`.

## 7. Security posture

This stack exposes an agent that has a shell, a browser and the operator's
connected accounts on a public hostname, protected by one bearer token.

- The token is 256 bits, so guessing is not the risk; leakage is. It grants
  full control. Rotate with `openssl rand -hex 32` and a redeploy.
- `runtime` holds the host Docker socket. Upstream's proxy refuses everything
  except `exec` and `inspect` on `nod-workspace-nod` and `nod-browser-nod`, and
  refuses privileged, TTY, detached or env-carrying execs. `server` reaches it
  only over the internal `control` network.
- Recommended from the first deploy: a Cloudflare WAF rule restricting
  `nod.alekseev.us` to known source IPs. It needs no stack change.
- Analytics, feedback and onboarding email are disabled. Composio connections,
  if used, route through `https://composio.n8n.cloud`.

## 8. Failure modes

| Failure | Effect | Handling |
|---|---|---|
| codex-lb down or key over limit | Chat fails; Nod retries a silent server for up to 30 min ×3 | Check codex-lb dashboard |
| `/v1/models` reports under 64k context for `gpt-6.2-sol` | Nod falls back to short instructions and one tool at a time | Caught in verification step 4 |
| codex-lb rejects Nod's tool-role message order | Tool calls fail | Caught in step 5; fix on the codex-lb side or pick another model |
| Wrong ownership on a dataset | Service crash-loops on start | Verification step 3 |
| `Host` mismatch | "This host is not permitted." | `NOD_PUBLIC_URL` must equal the tunnel hostname exactly |
| Postgres 18 incompatibility | Migrations fail at server start | Roll back to `postgres:17-alpine` before any data exists |

## 9. Verification

1. `docker compose -f stacks/nod.yaml config` passes
   (`scripts/validate-stack.sh nod` where `docker-compose` is installed).
2. The pull request's `nod images` workflow builds all four images.
3. After deploy, `docker compose ps` shows every service healthy and the
   dataset directories hold data with the expected owners.
4. From a container on `shared-services`, `GET http://codex-lb:2455/v1/models`
   with the nod key lists `gpt-6.2-sol` with a context window of at least 64k.
5. In Nod at `https://nod.alekseev.us`: token login works, a chat reply
   streams, one shell command runs in the workspace, one browser task completes.
6. The codex-lb dashboard shows the requests under the `nod` key.

## 10. Operator steps (not automatable from this repo)

1. Create the ZFS datasets and set ownership (5.5).
2. Write the two secret files (5.4).
3. Create the Cloudflare tunnel, its DNS record and `tunnel.json`; put the
   tunnel ID in `stacks/nod.yaml`.
4. Create the `nod` key in codex-lb (6).
5. After the pull request merges and the images are pushed, make the four GHCR
   packages public, then add the stack in Portainer.
6. Optional: Cloudflare WAF IP rule (7).

## 11. Rollback

Remove the stack in Portainer. State stays in the datasets. Before first real
use, rollback may also delete the datasets. After that, restoring means
restoring the ZFS snapshot of `data/nod` and `config/nod` together.

## 12. Follow-ups

- Nebula/defined.net access with its own TLS termination
- `postgres-backup-local` sidecar as in hindsight
- Telegram polling channel
- Voice, if a direct OpenAI key is ever acceptable
- Stealth browser binary. Upstream's `nod-browser` image installs Debian's
  `chromium` package and drives it with the `agent-browser` CLI through the
  wrapper `src/providers/container-browser/chromium.sh`, headed under Xvfb.
  Because this repo builds the image, a later overlay Dockerfile
  (`FROM nod-browser`, replace the binary the wrapper executes) can swap in a
  Chromium-compatible build such as CloakBrowser without forking Nod. Camoufox
  is Firefox-based and would need the browser worker's driver replaced, which
  is a fork.
  agent-browser's `obscura` engine (stealth mode) was researched on 2026-11-21
  and rejected. Nod pins agent-browser 0.39.2, which has the engine, but Nod
  hard-codes `--profile`, `--headed`, `--proxy-bypass` and `--args`
  (`src/providers/agent-browser/index.ts:554-587`), all of which agent-browser
  refuses under obscura, and Nod strips `AGENT_BROWSER_*` from the child
  environment (`src/providers/process.ts:17-34`), so it cannot be enabled from
  compose. Obscura also has no persistent profiles, so logins would not
  survive.
  Also researched on 2026-11-21 and rejected: Steel Browser (a session server
  on the same stock Debian `chromium`, with JS fingerprint injection) and
  rayobrowse (closed binary, no self-hosted persistent profiles, needs
  `seccomp=unconfined`). Both would need a patch to Nod's launch code.
  Fortress (`tiliondev/fortress`) is the only one that fits behind
  `chromium.sh`; its results are vendor-claimed only.
  Order to try, cheapest first, from a reading of `techinz/browsers-benchmark`
  (one run per engine, ten sites, no clicks, a different proxy per engine, so
  weak evidence): (1) measure the stock browser against the sites that matter;
  (2) overlay that installs `google-chrome-stable` and points `chromium.sh` at
  it, which is what every top-scoring engine in that benchmark runs;
  (3) remove Nod's 1440x900 viewport emulation
  (`src/providers/container-browser/config.ts:17`), a Nod patch; (4) Fortress,
  only if a specific site still fails. Headed mode, which Nod already uses, is
  the one factor that benchmark clearly separates.

## 13. As-built (2026-11-21)

Deployed from `master` through Portainer as stack `nod`; upstream pin `1b42e68`.

**Differences from the design above.**

- Host layout: two datasets (`spool/apps/data/nod`, `spool/apps/config/nod`) with plain subdirectories, not five child datasets. Ownership is as in 5.4 and the stack header.
- `NOD_AUTH_TOKEN`, `NOD_VAULT_KEY` and `NOD_POSTGRES_PASSWORD` were generated on the host with `openssl`.
- Tunnel `nod`, ID `f7bc333c-cd2b-4d7d-b98d-bc93d0cabd1c`, CNAME `nod.alekseev.us`. The account-wide `cert.pem` used to create it was shredded.
- The four GHCR packages were already public after the first push.
- The image workflows pin their actions by commit SHA.

**Verified.** All seven containers start; `nod-server`, `nod-postgres`, `nod-browser-nod` and `nod-workspace-network` report healthy. The owner signed in at `https://nod.alekseev.us` and chatted. codex-lb logs the requests under user agent `pi/1.5.2` with model `gpt-6.2-sol`. Postgres 18 ran the migrations.

**Not recorded.** Whether copy-up populated `workspace-tools`, the context window codex-lb reports for `gpt-6.2-sol`, a shell tool call, a browser task, and whether the WAF rule from section 7 exists. Step 6 of section 9 holds; steps 3 to 5 were not run as written.

**Behaviour observed through codex-lb.**

- *Cancelled requests are expected.* codex-lb logs some Nod requests as `cancelled / client_disconnected`, about 20 to 50 ms after the first token. Nod aborts them itself: stale onboarding suggestions (`src/server/onboarding-suggestions.ts`), and Pi's cache warmer, which sends a small request after a turn and aborts it when the next turn starts.
- *Little prompt caching and no upstream WebSocket.* Nod's `compatible` provider is hard-coded to Chat Completions and sends no session ID or `prompt_cache_key`, so codex-lb logs `sticky=False upstream_stream_transport=http`. Over the first 45 successful requests Nod sent 264,995 input tokens with 0 cached; hindsight, on `/v1/responses` with a session ID, had 41% cached over the same day.
  *Corrected 2026-11-22.* The missing key is not what prevents caching: codex-lb derives a `prompt_cache_key` itself, and three identical requests through it reached 5,504 of 5,619 input tokens cached. A capture of Nod's traffic showed its requests are cacheable: within a session the system prompt and tool definitions are byte-identical and messages are append-only. In that window 483 requests carried 966,166 input tokens, of which 140,288 were cached, all on the 24 requests over 10k tokens. Hits came after several consecutive requests of one session. Misses coincided with two sessions interleaving (main chat and a saved-task session with a different system prompt and tool set), with requests moving between the two upstream accounts after `account_response_create_cap`, and with errors. Which of these dominates is not established. 432 of the 483 requests were under 2k tokens; what sends them is not identified.
- *`account_response_create_cap` warnings are harmless.* Nod's bursts exceed four concurrent creates on one account and codex-lb moves the request to the other account.
- *The `pay` tool failed with 400 until codex-lb was patched.* See section 13 of `2026-11-17-codex-lb-gateway-design.md`.

**Follow-up: caching.** Upstream Nod has no issue or pull request for a Responses API mode on the compatible provider (searched 2026-11-21). Pi can already send `prompt_cache_key` and session-affinity headers (`x-session-id`, `session_id`) on Chat Completions, but only when the model's `compat` block enables them, and Nod's compatible provider does not (`src/providers/pi/models.ts:392`; Nod PR #385 says its cache key change "changes nothing for … OpenAI-compatible servers"). codex-lb reads both `prompt_cache_key` and the `session_id` header. Enabling those `compat` flags is therefore a smaller change than switching the provider to the Responses API. It is untested, and it is a patch to Nod's source either way.

## 14. Release tracking (2026-11-22)

The submodule `stacks/nod/upstream` is removed. The image tags in
`stacks/nod.yaml` are the only pin and carry the upstream release version, for
example `0.9.1`. `nod-images.yml` reads that version, refuses to build unless
every nod image has the same `X.Y.Z` tag, checks out `n8n-io/nod` at
`nod-vX.Y.Z` and tags the images `X.Y.Z`.

A Renovate regex custom manager in `renovate.json` reads the same tags and looks
up `n8n-io/nod` GitHub releases, stripping the `nod-v` prefix. A bump is one pull
request that changes the five tags; the pull-request build proves the release
still builds. The existing grouping and automerge rules name only the `docker`
and `github-tags` datasources, so Nod bumps are never automerged.

Why not keep the submodule: Renovate's submodule manager is opt-in beta and
would move only the submodule, not the tags in the stack file, so every bump
would still need a hand edit.

Costs accepted:

- A release tag is mutable where a commit SHA was not. A rebuild after upstream
  moves a tag would publish different code under the same image tag.
- The bump pull request does not show upstream's compose changes. Compare
  `deployment/` between the two tags before merging; the command is in the
  header of `stacks/nod.yaml`.
- The first pin under this scheme, `0.9.1`, is 32 commits older than the
  `1b42e68` pin it replaces. Those commits add three nullable columns and drop
  one index; nothing else in the schema changes.
