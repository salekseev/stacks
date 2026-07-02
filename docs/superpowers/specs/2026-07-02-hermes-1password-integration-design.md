# Hermes 1Password Integration — Design Spec

**Date:** 2026-07-02
**Status:** Approved for implementation
**Stack:** `stacks/hermes.yaml`

---

## 1. Problem

Hermes routines that need service credentials (currently: Gixen eBay sniper; future: any authenticated web service) receive them as plaintext Portainer stack env vars. Each new credential requires a Portainer UI edit and a stack redeploy. Credentials are visible in the Portainer dashboard.

## 2. Goals

- Routine credentials live in 1Password, not in Portainer.
- Adding a new credential to a routine requires only a 1Password vault change — no compose edit, no redeploy.
- The Hermes agent can fetch credentials on demand when executing routines.
- Gateway-only infra secrets move from Portainer to `/opt/data/.env` on-disk (not visible in Portainer UI, no redeploy to rotate).
- Cross-container secrets (`CAMOFOX_SHARED_KEY`, `HERMES_API_SERVER_KEY`) and compose-level vars (`HERMES_TUNNEL_ID`) remain in Portainer — unchanged.

## 3. Non-Goals

- Migrating infra/stack secrets to 1Password (explicitly out of scope; see §8).
- 1Password Connect or MCP server (too complex, not suitable for headless; already rejected).
- 1Password Environments local `.env` file or agent hook (requires desktop app running on host; TrueNAS Scale is an immutable OS with no durable host package installs).
- Moving cross-container secrets (`CAMOFOX_SHARED_KEY`, `HERMES_API_SERVER_KEY`) or compose-level vars (`HERMES_TUNNEL_ID`) out of Portainer — they have no alternative injection path.

## 4. Architecture

```
/opt/data/.env on-disk (silverstone volume mount)
  ANTHROPIC_TOKEN
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  HERMES_DASHBOARD_BASIC_AUTH_SECRET
  HINDSIGHT_API_KEY
  OP_SERVICE_ACCOUNT_TOKEN          ◄── new
         │
         ▼ (Hermes reads .env at startup, exports all vars)
hermes-gateway process env
         │
         ▼ (forwarded via skill's required_environment_variables)
Hermes terminal sessions
         │
         ▼
op CLI (installed at runtime via Hermes install-and-remember)
         │
         ▼  op read "op://hermes/gixen/username"
1Password cloud (hermes vault, read-only service account)
```

Portainer only holds cross-container/compose-level vars: `CAMOFOX_SHARED_KEY`, `HERMES_API_SERVER_KEY`, `HERMES_TUNNEL_ID`.

The Hermes `security-1password` skill handles both the `op` installation and the forwarding of `OP_SERVICE_ACCOUNT_TOKEN` to terminal sessions. No config.yaml edits are needed on the host for Phase 1.

## 5. Components

### 5a. `stacks/hermes.yaml` change (repo-side)

Remove four gateway-only secrets from the `hermes-gateway` environment block (they move to `.env`):
- `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${HERMES_DASHBOARD_PASSWORD}`
- `HERMES_DASHBOARD_BASIC_AUTH_SECRET=${HERMES_DASHBOARD_SECRET}`
- `ANTHROPIC_TOKEN=${ANTHROPIC_TOKEN}`
- `HINDSIGHT_API_KEY=${HINDSIGHT_API_KEY}`

Replace with inline comments noting they are set in `/opt/data/.env`. Update the header comment block to document the two-tier secret split. `OP_SERVICE_ACCOUNT_TOKEN` is written directly to `.env` — no compose line needed.

No bind-mount. No derived image. `op` is installed inside the container by the skill.

### 5b. `/opt/data/.env` on silverstone (user edits once)

File path: `/mnt/spool/apps/data/hermes/gateway/.env` (already exists, currently `700` perms).
Tighten to `600`: `chmod 600 /mnt/spool/apps/data/hermes/gateway/.env`

Add the following lines (values sourced from current Portainer env then removed from there):
```
ANTHROPIC_TOKEN=<sk-ant-oat-...>
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<current HERMES_DASHBOARD_PASSWORD value>
HERMES_DASHBOARD_BASIC_AUTH_SECRET=<current HERMES_DASHBOARD_SECRET value>
HINDSIGHT_API_KEY=<current HINDSIGHT_API_KEY value>
OP_SERVICE_ACCOUNT_TOKEN=<ops_...>
```

### 5c. 1Password vault setup (user, one-time)

| Step | Detail |
|---|---|
| Create vault | Name: `hermes` |
| Add item | Type: Login, Title: `gixen`, fields: `username` / `password` |
| Create service account | Name: `hermes-gateway`, scoped read-only to `hermes` vault only |
| Copy token | `OP_SERVICE_ACCOUNT_TOKEN=ops_…` → write to `.env` (see §5b) |

### 5d. Portainer stack env vars

Remove (moved to `.env`): `ANTHROPIC_TOKEN`, `HERMES_DASHBOARD_PASSWORD`, `HERMES_DASHBOARD_SECRET`, `HINDSIGHT_API_KEY`
Remove (moved to 1Password): `GIXEN_USERNAME`, `GIXEN_PASSWORD`
Remove (hardcoded in compose — not a secret): `HERMES_TUNNEL_ID`
Keep: `CAMOFOX_SHARED_KEY`, `HERMES_API_SERVER_KEY`

### 5e. Hermes skill enablement (user, one-time)

In the Hermes dashboard → Skills → Optional → Security → enable `security-1password`. On first activation the skill prompts for `OP_SERVICE_ACCOUNT_TOKEN` (already in container env — confirm/skip) and installs `op` CLI via `apt`. Hermes remembers the install command; after each container restart it reinstalls `op` when next needed.

## 6. Data Flow for a Routine

1. Routine needs Gixen credentials.
2. Agent calls `op read "op://hermes/gixen/username"` and `op read "op://hermes/gixen/password"`.
3. `op` authenticates with `OP_SERVICE_ACCOUNT_TOKEN` (already in env, forwarded by skill).
4. 1Password returns values; agent uses them in the HTTP call to Gixen API.
5. Values are not cached to disk; each `op read` is a fresh authenticated fetch.

Secret naming convention: `op://<vault>/<item-title>/<field-name>` — e.g.:
- `op://hermes/gixen/username`
- `op://hermes/gixen/password`
- `op://hermes/some-future-service/api key`

## 7. Error Handling

| Failure | Behaviour |
|---|---|
| `op` not yet installed (cold container start) | Skill re-runs install on next use; routine should surface a clear error if `op` is missing |
| Invalid / expired service account token | `op read` returns non-zero; agent logs warning, routine fails gracefully |
| Item not found in vault | `op read` exits 1; agent surfaces `op://…` reference in error so user knows which item to add |
| Network unreachable to 1Password | `op` times out; agent propagates error; infra secrets (ANTHROPIC_TOKEN etc.) are unaffected |

## 8. Explicit Exclusions

Infrastructure secrets that are correctly kept in Portainer (unchanged by this spec):
`CAMOFOX_SHARED_KEY`, `HERMES_API_SERVER_KEY`, `HERMES_DASHBOARD_PASSWORD`,
`HERMES_DASHBOARD_SECRET`, `ANTHROPIC_TOKEN`, `HERMES_TUNNEL_ID`, `HINDSIGHT_API_KEY`

## 9. Phase 2 Migration Path (future)

PR [NousResearch/hermes-agent#36896](https://github.com/NousResearch/hermes-agent/pull/36896) adds a native 1Password secret source backend. When merged:

1. Bump hermes-gateway image to the first tag containing the merge commit.
2. Add to `/mnt/spool/apps/data/hermes/gateway/config.yaml` on silverstone:

```yaml
secrets:
  onepassword:
    enabled: true
    env:
      GIXEN_USERNAME: "op://hermes/gixen/username"
      GIXEN_PASSWORD: "op://hermes/gixen/password"
```

3. Hermes resolves credentials at startup and injects as `os.environ` — agent no longer needs to call `op read` manually. The skill-based fetch pattern becomes optional.

## 10. Testing

| Check | Method |
|---|---|
| `op` installed | `docker exec hermes-gateway op --version` |
| Token forwarded | `docker exec hermes-gateway env \| grep OP_SERVICE` (expect present) |
| Secret fetch works | `docker exec hermes-gateway op read "op://hermes/gixen/username"` (expect username value) |
| Routine uses creds | Run Gixen routine manually; confirm it logs in without GIXEN_* env vars |
| Old env vars gone | `docker exec hermes-gateway env \| grep -i gixen` (expect empty) |
