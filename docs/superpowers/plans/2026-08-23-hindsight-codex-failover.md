# Hindsight ChatGPT-Subscription Primary LLM with vLLM Failover — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make hindsight's default LLM `gpt-5.6-luna` on a ChatGPT/Codex subscription, falling back to vLLM `gemma-4-12b` on `192.168.1.147:8080`, and delete the now-unused `hindsight-litellm` proxy.

**Architecture:** Hindsight's native multi-LLM chain replaces the proxy hop. The unindexed `HINDSIGHT_API_LLM_*` vars configure the primary (`openai-codex` provider reading `$CODEX_HOME/auth.json`); `HINDSIGHT_API_LLM_1_*` configures the vLLM member; `HINDSIGHT_API_LLM_STRATEGY={"mode":"failover"}` orders them. No code — this is a Docker Compose stack change plus host-side credential placement.

**Tech Stack:** Docker Compose (compose-spec), Portainer git-backed stack deploy, `ghcr.io/vectorize-io/hindsight:0.9.1-slim`, vLLM, Cloudflare Tunnel, PostgreSQL (vchord).

**Spec:** `docs/superpowers/specs/2026-08-23-hindsight-codex-failover-design.md`

**Working branch:** `feature/hindsight-codex-failover` (already created; the spec commit is staged but unsigned-blocked — see Task 0).

---

## Environment notes for the implementer

- Repo lives at `/home/salekseev/src/github.com/salekseev/stacks`. The path `/home/salekseev/stacks` is a **different, near-empty directory** — do not edit there.
- Commits in this repo are SSH-signed via the 1Password agent (`commit.gpgsign=true`). If the 1Password app is locked, `git commit` fails with `error: 1Password: failed to fill whole buffer`. Unlock the app; do not disable signing.
- The assistant cannot ssh to silverstone (same locked-agent problem). Every step marked **[USER SHELL]** must be run by the user, prefixed with `!` in the Claude Code prompt so output lands in the conversation.
- silverstone is reachable as `silverstone` (in `known_hosts`) or `100.77.121.38` (Tailscale, needs `-o StrictHostKeyChecking=accept-new` the first time).
- The vLLM box is `192.168.1.147` and is *not* silverstone.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `stacks/hindsight.yaml` | The whole stack: hindsight all-in-one, db, backup, TEI embed/rerank, cloudflared, configs, secrets | Modify — LLM env block, add codex volume, delete `litellm` service, delete its ingress line, delete `litellm` schema from db-init |
| `docs/superpowers/specs/2026-08-23-hindsight-codex-failover-design.md` | Approved design | Already written, staged, needs committing |
| `docs/superpowers/plans/2026-08-23-hindsight-codex-failover.md` | This plan | Created by this task set |
| `/mnt/spool/apps/config/hindsight/codex/auth.json` (host, silverstone) | Codex OAuth token, dedicated `CODEX_HOME` | Created in Task 2 |
| `/mnt/spool/apps/config/hindsight/env` (host, silverstone) | `hindsight_env` Docker secret, sourced **after** compose `environment:` so it overrides | Audited in Task 1, pruned if it carries stale `HINDSIGHT_API_LLM_*` vars |

---

## Task 0: Commit the approved spec

**Files:**
- Commit: `docs/superpowers/specs/2026-08-23-hindsight-codex-failover-design.md` (already staged)

- [ ] **Step 1: Confirm the 1Password app is unlocked**

Run:
```bash
SSH_AUTH_SOCK=$HOME/.1password/agent.sock ssh-add -l
```
Expected: three keys listed, including `id_ed25519_alekseev`. Listing works even when locked, so also run the signing smoke test in Step 2 rather than trusting this.

- [ ] **Step 2: Verify the branch and staged state**

Run:
```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git branch --show-current
git status --short
```
Expected: branch `feature/hindsight-codex-failover`; `A  docs/superpowers/specs/2026-08-23-hindsight-codex-failover-design.md` and `M  .serena/project.yml` (leave `.serena/project.yml` alone — it is unrelated local churn and must stay out of every commit in this plan).

- [ ] **Step 3: Commit the spec**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git commit -m "docs(hindsight): design spec for ChatGPT-subscription primary LLM with vLLM failover

Switch hindsight's default LLM from the local litellm proxy to hindsight's
native multi-LLM failover chain: openai-codex/gpt-5.6-luna primary against a
dedicated CODEX_HOME, falling back to vLLM gemma-4-12b on 192.168.1.147.

Records the host recon that corrected two stale assumptions: the in-repo
comment claiming hindsight-default routes to chatgpt/gpt-5.4-mini (it routes
to vLLM gemma, with a Copilot/OpenAI-key fallback), and the assumption that
the litellm proxy was unused (its Copilot token refreshed Aug 17). Also
documents why the built-in LiteLLM Router was rejected: litellm's chatgpt/
provider does not serve gpt-5.6 models for non-codex_cli_rs originators.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
Expected: commit succeeds. If it prints `error: 1Password: failed to fill whole buffer`, the app is locked — unlock it in the desktop UI and re-run. Do not add `-c commit.gpgsign=false`.

- [ ] **Step 4: Commit this plan**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add docs/superpowers/plans/2026-08-23-hindsight-codex-failover.md
git commit -m "docs(hindsight): implementation plan for codex/vLLM failover chain

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
Expected: two commits on the branch, `git log --oneline -2` shows both.

---

## Task 1: Audit the `hindsight_env` secret for stale LLM overrides

**Why this is first:** the container entrypoint is `sh -c "set -a; . /run/secrets/hindsight_env; set +a; exec /app/start-all.sh"`. The secret is sourced **after** compose `environment:` is applied, so any `HINDSIGHT_API_LLM_*` var in that file **silently overrides** everything this plan sets in YAML. The proxy setup very likely put `HINDSIGHT_API_LLM_API_KEY` (the litellm master key) there.

**Files:**
- Inspect: `/mnt/spool/apps/config/hindsight/env` (host: silverstone)

- [ ] **Step 1: List the LLM-related keys in the secret [USER SHELL]**

```bash
! ssh silverstone 'sudo grep -nE "^[A-Z_]*(LLM|CODEX|CHATGPT|LITELLM)[A-Z_]*=" /mnt/spool/apps/config/hindsight/env | sed "s/=.*/=<redacted>/"'
```
Expected: a list of variable **names** only (values redacted by the `sed`). Likely hits: `HINDSIGHT_API_LLM_API_KEY`. Possible: `HINDSIGHT_API_LLM_MODEL`, `HINDSIGHT_API_LLM_BASE_URL`, `HINDSIGHT_API_LLM_PROVIDER`.

- [ ] **Step 2: Decide per variable**

Apply this rule — do not improvise:

| Found in secret | Action |
|---|---|
| `HINDSIGHT_API_LLM_API_KEY` | **Delete the line.** It held the litellm master key; the `openai-codex` primary uses OAuth and member 1 gets `HINDSIGHT_API_LLM_1_API_KEY: none` from YAML. Leaving it set injects a bogus key into the primary. |
| `HINDSIGHT_API_LLM_MODEL` / `_BASE_URL` / `_PROVIDER` | **Delete the line.** These would override the YAML and silently keep the old routing. |
| `HINDSIGHT_API_LLM_TIMEOUT` / `_MAX_CONCURRENT` / `_MAX_RETRIES` | **Delete the line.** Same override hazard; the YAML is the single source of truth for tuning. |
| Anything else (tenant API key, DB URL, CP keys) | **Leave untouched.** Out of scope. |

- [ ] **Step 3: Back up, then prune [USER SHELL]**

```bash
! ssh silverstone 'sudo cp -a /mnt/spool/apps/config/hindsight/env /mnt/spool/apps/config/hindsight/env.bak-2026-08-23 && sudo sed -i -E "/^HINDSIGHT_API_LLM_(API_KEY|MODEL|BASE_URL|PROVIDER|TIMEOUT|MAX_CONCURRENT|MAX_RETRIES)=/d" /mnt/spool/apps/config/hindsight/env && echo PRUNED'
```
Expected: `PRUNED`. The `.bak-2026-08-23` copy is the rollback for this step.

- [ ] **Step 4: Verify nothing LLM-related remains [USER SHELL]**

```bash
! ssh silverstone 'sudo grep -cE "^HINDSIGHT_API_LLM_" /mnt/spool/apps/config/hindsight/env || echo 0'
```
Expected: `0`.

- [ ] **Step 5: Confirm the secret file is still well-formed [USER SHELL]**

```bash
! ssh silverstone 'sudo sh -c ". /mnt/spool/apps/config/hindsight/env && echo SOURCEABLE"'
```
Expected: `SOURCEABLE`. If it errors, restore from `env.bak-2026-08-23` and stop — a broken secret file breaks the container entrypoint.

---

## Task 2: Place the Codex token in a dedicated `CODEX_HOME` on silverstone

**Files:**
- Create: `/mnt/spool/apps/config/hindsight/codex/` (host: silverstone), owner `568:568`, mode `0700`
- Create: `/mnt/spool/apps/config/hindsight/codex/auth.json`, owner `568:568`, mode `0600`

- [ ] **Step 1: Identify a machine with a live codex login**

On the candidate machine, run:
```bash
stat -c '%n %y %s' ~/.codex/auth.json
```
Expected: a recent mtime. Known state as of 2026-08-23: the `192.168.1.147` box has an auth.json dated **May 30** (stale), and silverstone has an unused orphan dated **Jun 10** under `.../litellm/chatgpt-tokens/`. Pick the freshest live login — per the spec that is expected to be the user's Mac. Do not use the Jun 10 orphan.

- [ ] **Step 2: Create the directory [USER SHELL]**

```bash
! ssh silverstone 'sudo install -d -o 568 -g 568 -m 700 /mnt/spool/apps/config/hindsight/codex && ls -lad /mnt/spool/apps/config/hindsight/codex'
```
Expected: `drwx------ ... 568 568 ... /mnt/spool/apps/config/hindsight/codex` (may display as `apps apps`).

- [ ] **Step 3: Copy the token from the source machine [USER SHELL]**

From the machine holding the live login:
```bash
! scp ~/.codex/auth.json silverstone:/tmp/codex-auth.json
! ssh silverstone 'sudo install -o 568 -g 568 -m 600 /tmp/codex-auth.json /mnt/spool/apps/config/hindsight/codex/auth.json && sudo rm -f /tmp/codex-auth.json && sudo ls -la /mnt/spool/apps/config/hindsight/codex/'
```
Expected: `-rw------- 1 apps apps <~4600> ... auth.json`, and `/tmp/codex-auth.json` gone.

- [ ] **Step 4: Sanity-check the token shape without printing secrets [USER SHELL]**

```bash
! ssh silverstone 'sudo python3 -c "import json;d=json.load(open(\"/mnt/spool/apps/config/hindsight/codex/auth.json\"));print(sorted(d.keys()));t=d.get(\"tokens\",{});print(sorted(t.keys()) if isinstance(t,dict) else type(t))"'
```
Expected: top-level keys including `tokens` (and typically `last_refresh` / `OPENAI_API_KEY`), with `tokens` containing `access_token`, `refresh_token`, `id_token`, `account_id`. If the shape differs wildly, the source was not a codex CLI login — stop and re-do Step 1.

- [ ] **Step 5: Record the pre-deploy mtime [USER SHELL]**

```bash
! ssh silverstone 'sudo stat -c "%n %y" /mnt/spool/apps/config/hindsight/codex/auth.json'
```
Expected: today's timestamp. Save this value — Task 8 compares against it to prove the container can write its rotated token back.

---

## Task 3: Rewrite the LLM env block in `stacks/hindsight.yaml`

**Files:**
- Modify: `stacks/hindsight.yaml` — the `hindsight` service `environment:` block (currently lines ~44-59, the comment + five `HINDSIGHT_API_LLM_*`/`BASE_URL`/`MODEL` entries)

- [ ] **Step 1: Read the current block to get exact context**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
sed -n '40,62p' stacks/hindsight.yaml
```
Expected: the `# API: default LLM (recall, reflect, consolidation) via local litellm proxy.` comment, `HINDSIGHT_API_LLM_PROVIDER: openai`, `HINDSIGHT_API_LLM_BASE_URL: http://hindsight-litellm:4000/v1`, `HINDSIGHT_API_LLM_MODEL: hindsight-default`, the llama.cpp tuning comment, `HINDSIGHT_API_LLM_TIMEOUT: "600"`, `HINDSIGHT_API_LLM_MAX_CONCURRENT: "1"`.

- [ ] **Step 2: Replace that block**

Delete everything from the `# API: default LLM ...` comment through `HINDSIGHT_API_LLM_MAX_CONCURRENT: "1"` inclusive, and put this in its place (keep the surrounding 6-space indentation of sibling keys):

```yaml
      # API: default LLM (recall, reflect, consolidation) via Hindsight's native
      # multi-LLM failover chain — no proxy hop.
      #
      # Primary: ChatGPT/Codex subscription, gpt-5.6-luna, through the native
      # openai-codex transport. LiteLLM's chatgpt/ provider is deliberately NOT
      # used: it documents no gpt-5.6 models, and third-party originators get
      # "Model not found gpt-5.6-luna-free-1p-codexswic-ev3" over ChatGPT OAuth
      # while the Codex originator succeeds on the same credentials
      # (openai/codex#31967). The native provider carries that originator.
      HINDSIGHT_API_LLM_PROVIDER: openai-codex
      HINDSIGHT_API_LLM_MODEL: gpt-5.6-luna
      # Dedicated Codex auth home. Codex refresh tokens are single-use and
      # rotate, so a long-running service sharing ~/.codex/auth.json with an
      # interactive CLI ends up holding a stale token: reflect then fails with
      # refresh_token_reused while recall and /health stay green.
      CODEX_HOME: /codex
      # Member 1: local vLLM on the 192.168.1.147 box (that host is NOT
      # silverstone). REASONING_EFFORT=none because gemma-4 otherwise emits a
      # thinking block that burns tokens on fact extraction.
      HINDSIGHT_API_LLM_1_PROVIDER: openai
      HINDSIGHT_API_LLM_1_BASE_URL: http://192.168.1.147:8080/v1
      HINDSIGHT_API_LLM_1_MODEL: gemma-4-12b
      HINDSIGHT_API_LLM_1_API_KEY: none
      HINDSIGHT_API_LLM_1_REASONING_EFFORT: none
      HINDSIGHT_API_LLM_STRATEGY: '{"mode": "failover"}'
      # Failover advances only after a member exhausts its own retries; the
      # default of 3 would burn three luna attempts per call under a 429.
      HINDSIGHT_API_LLM_MAX_RETRIES: "1"
      HINDSIGHT_API_LLM_TIMEOUT: "600"
      # Was 1, tuned for llama.cpp --parallel 1. vLLM batches continuously and
      # the primary is a remote API, so serial calls were leaving both idle.
      HINDSIGHT_API_LLM_MAX_CONCURRENT: "4"
```

- [ ] **Step 3: Add the codex volume to the `hindsight` service**

The `hindsight` service currently has **no** `volumes:` key. Insert one immediately after the `secrets:` block (`      - hindsight_env`) and before `    environment:`:

```yaml
    volumes:
      # Dedicated Codex auth home (CODEX_HOME=/codex). NOT :ro — the provider
      # writes the rotated refresh token back, and a read-only mount breaks
      # refresh on the first rotation.
      - /mnt/spool/apps/config/hindsight/codex:/codex
```

- [ ] **Step 4: Verify the edit shape**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
grep -nE "HINDSIGHT_API_LLM_|CODEX_HOME|/codex" stacks/hindsight.yaml
```
Expected exactly these, in order: `HINDSIGHT_API_LLM_PROVIDER: openai-codex`, `HINDSIGHT_API_LLM_MODEL: gpt-5.6-luna`, `CODEX_HOME: /codex`, `HINDSIGHT_API_LLM_1_PROVIDER`, `_1_BASE_URL`, `_1_MODEL`, `_1_API_KEY`, `_1_REASONING_EFFORT`, `HINDSIGHT_API_LLM_STRATEGY`, `HINDSIGHT_API_LLM_MAX_RETRIES`, `HINDSIGHT_API_LLM_TIMEOUT`, `HINDSIGHT_API_LLM_MAX_CONCURRENT`, plus the `- /mnt/spool/apps/config/hindsight/codex:/codex` volume line. **No** `HINDSIGHT_API_LLM_BASE_URL` (unindexed) may remain.

- [ ] **Step 5: Commit**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add stacks/hindsight.yaml
git commit -m "feat(hindsight): route default LLM through native codex/vLLM failover chain

Primary is the ChatGPT subscription (gpt-5.6-luna) via the native openai-codex
provider reading a dedicated CODEX_HOME; member 1 is vLLM gemma-4-12b on
192.168.1.147. MAX_RETRIES drops to 1 so a 429 falls through after one attempt,
and MAX_CONCURRENT rises from 1 to 4 now that the serial llama.cpp backend is
no longer in the path.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
Expected: commit succeeds.

---

## Task 4: Delete the `litellm` proxy service

**Files:**
- Modify: `stacks/hindsight.yaml` — remove the `litellm:` service block (~lines 148-190), one `cloudflared` ingress entry, and one line in the `hindsight-db-init` config

- [ ] **Step 1: Locate the three regions**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
grep -nE "^  litellm:|hindsight-litellm|CREATE SCHEMA IF NOT EXISTS litellm" stacks/hindsight.yaml
```
Expected: the `  litellm:` service key, `container_name: hindsight-litellm`, the ingress `hostname: hindsight-litellm.alekseev.us` + its `service: http://hindsight-litellm:4000`, and the `CREATE SCHEMA IF NOT EXISTS litellm AUTHORIZATION postgres;` line.

- [ ] **Step 2: Delete the whole `litellm:` service block**

Remove from `  litellm:` through its final `    restart: unless-stopped`, inclusive — that is the `image`, `container_name`, `entrypoint`, `user`, `cap_drop`, `security_opt`, `secrets`, `environment` (`GITHUB_COPILOT_TOKEN_DIR`, `CHATGPT_TOKEN_DIR`, `PRISMA_BINARY_CACHE_DIR`, `XDG_CACHE_HOME`, `LITELLM_MIGRATION_DIR`), `tmpfs`, `volumes`, `depends_on`, `healthcheck`, `restart`. Leave the neighbouring services untouched.

- [ ] **Step 3: Delete the cloudflared ingress entry**

Remove these two lines from the `cloudflared` config content:

```yaml
        - hostname: hindsight-litellm.alekseev.us
          service: http://hindsight-litellm:4000
```

Leave the `hindsight.alekseev.us` entries and the trailing `- service: http_status:404` catch-all intact.

- [ ] **Step 4: Delete the litellm schema line from db-init**

Remove this line from the `hindsight-db-init` config content:

```sql
      CREATE SCHEMA IF NOT EXISTS litellm AUTHORIZATION postgres;
```

Keep every other statement (the `CREATE EXTENSION` calls, the `ALTER DATABASE ... search_path`, the `create_tokenizer` call).

- [ ] **Step 5: Verify no references survive**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
grep -niE "litellm" stacks/hindsight.yaml
```
Expected: **no output**, exit status 1. Any hit is a leftover — the `depends_on` of other services, a comment, or the secrets list.

- [ ] **Step 6: Confirm nothing else in the repo referenced the proxy**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
grep -rniE "hindsight-litellm" stacks/ scripts/ || echo "no references"
```
Expected: `no references`.

- [ ] **Step 7: Commit**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add stacks/hindsight.yaml
git commit -m "feat(hindsight)!: remove the litellm proxy service

Hindsight now routes through its own failover chain, so the proxy has no
consumer inside this stack. Removes the service, its cloudflared ingress for
hindsight-litellm.alekseev.us, and the litellm schema grant in db-init.

BREAKING: the Copilot route, the claude-*/gpt-5-mini/gpt-4o-mini aliases, the
OpenAI-keyed embedding deployment and litellm's Postgres spend logging all go
away with it. Host files under /mnt/spool/apps/config/hindsight/litellm/ and
the existing litellm schema are deliberately left in place so a revert
restores the previous routing without further host work.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
Expected: commit succeeds.

---

## Task 5: Validate the compose file statically

**Files:**
- Verify: `stacks/hindsight.yaml`

- [ ] **Step 1: Run the repo's validator**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
./scripts/validate-stack.sh hindsight
```
Expected: `Validating stacks/hindsight.yaml...` then `Validation successful for stacks/hindsight.yaml`.

If it fails with `docker-compose: command not found`, the host only has the v2 plugin — run the equivalent directly and treat success as equivalent:
```bash
docker compose -f stacks/hindsight.yaml config > /dev/null && echo "Validation successful"
```

- [ ] **Step 2: Assert the rendered config has the chain and no proxy**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
docker compose -f stacks/hindsight.yaml config 2>/dev/null | grep -E "HINDSIGHT_API_LLM_(PROVIDER|MODEL|1_PROVIDER|1_MODEL|STRATEGY|MAX_RETRIES|MAX_CONCURRENT)|CODEX_HOME|/codex"
docker compose -f stacks/hindsight.yaml config 2>/dev/null | grep -ci litellm || echo "0 litellm refs"
```
Expected: the first command lists the chain vars with `openai-codex` / `gpt-5.6-luna` / `openai` / `gemma-4-12b` / `{"mode": "failover"}` / `1` / `4`, plus the `/codex` bind mount. The second prints `0 litellm refs`.

- [ ] **Step 3: Assert the strategy JSON parses**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
python3 -c "import json,subprocess,yaml,sys; y=yaml.safe_load(subprocess.check_output(['docker','compose','-f','stacks/hindsight.yaml','config'])); e=y['services']['hindsight']['environment']; print(json.loads(e['HINDSIGHT_API_LLM_STRATEGY']))"
```
Expected: `{'mode': 'failover'}`. A YAML quoting slip here would otherwise only surface as a runtime config error inside the container.

- [ ] **Step 4: Commit nothing**

This task changes no files. If validation forced a fix, amend the relevant Task 3/4 commit rather than adding a "fix validation" commit.

---

## Task 6: Open the pull request

**Files:**
- Push: branch `feature/hindsight-codex-failover`

- [ ] **Step 1: Confirm the branch contents**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git log --oneline origin/master..HEAD
git diff --stat origin/master..HEAD
```
Expected: four commits (spec, plan, env chain, proxy removal); diffstat touches only `stacks/hindsight.yaml` and the two `docs/superpowers/` files. `.serena/project.yml` must **not** appear.

- [ ] **Step 2: Push**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git push -u origin feature/hindsight-codex-failover
```
Expected: branch created on `origin`.

- [ ] **Step 3: Open the PR**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
gh pr create --title "feat(hindsight): ChatGPT-subscription primary LLM with vLLM failover, drop litellm proxy" --body "$(cat <<'BODY'
## Summary

Hindsight's default LLM moves from the local litellm proxy to Hindsight's own multi-LLM failover chain:

- **Primary:** ChatGPT/Codex subscription, `gpt-5.6-luna`, via the native `openai-codex` provider with a dedicated `CODEX_HOME` bind-mounted rw (refresh tokens rotate and must be writable).
- **Member 1:** vLLM `gemma-4-12b` on `192.168.1.147:8080`, `reasoning_effort=none`.
- `HINDSIGHT_API_LLM_MAX_RETRIES` 3 → 1 so a 429 falls through after one attempt; `MAX_CONCURRENT` 1 → 4 now that the serial llama.cpp backend is gone.

The `litellm` proxy service, its `hindsight-litellm.alekseev.us` ingress and the db-init `litellm` schema grant are removed.

**Breaking:** the Copilot route, `claude-*`/`gpt-5-mini`/`gpt-4o-mini` aliases, the OpenAI-keyed embedding deployment and proxy spend logging go away. Host files under `/mnt/spool/apps/config/hindsight/litellm/` and the existing Postgres schema are left in place so a revert restores prior routing with no host work.

**Why not the built-in LiteLLM Router:** litellm's `chatgpt/` provider documents no `gpt-5.6` models, and third-party originators get `Model not found gpt-5.6-luna-free-1p-codexswic-ev3` over ChatGPT OAuth while the Codex originator succeeds on the same credentials (openai/codex#31967).

Design: `docs/superpowers/specs/2026-08-23-hindsight-codex-failover-design.md`
Plan: `docs/superpowers/plans/2026-08-23-hindsight-codex-failover.md`

## Deploy prerequisites (host, already done in Tasks 1-2)

- `/mnt/spool/apps/config/hindsight/codex/auth.json` in place, `568:568`, `0600`.
- Stale `HINDSIGHT_API_LLM_*` lines pruned from the `hindsight_env` secret — it is sourced *after* compose `environment:` and would otherwise override this config silently.

## Post-merge verification

Probe that the primary actually serves `gpt-5.6-luna` from this account/host (it has never been exercised here). If not, pin `gpt-5.5` or `gpt-5.3-codex`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
Expected: PR URL printed.

---

## Task 7: Deploy and probe that the primary actually serves luna

**This task gates the whole change.** Nothing on this host has ever served `gpt-5.6-luna` over OAuth.

- [ ] **Step 1: Merge and let Portainer pull**

Merge the PR to `master`, then trigger/await the Portainer stack update for `hindsight`.

- [ ] **Step 2: Confirm the containers came up and the proxy is gone [USER SHELL]**

```bash
! ssh silverstone 'docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "hindsight"'
```
Expected: `hindsight`, `hindsight-db`, `hindsight-db-backup`, `hindsight-tei-embed`, `hindsight-tei-reranker`, `hindsight-cloudflared` — and **no** `hindsight-litellm`.

- [ ] **Step 3: Confirm the chain landed in the container's env [USER SHELL]**

```bash
! ssh silverstone 'docker exec hindsight env | grep -E "^(HINDSIGHT_API_LLM_|CODEX_HOME)" | sed "s/\(API_KEY=\).*/\1<redacted>/" | sort'
```
Expected: `CODEX_HOME=/codex`, `HINDSIGHT_API_LLM_PROVIDER=openai-codex`, `HINDSIGHT_API_LLM_MODEL=gpt-5.6-luna`, the four `_1_*` vars, `HINDSIGHT_API_LLM_STRATEGY={"mode": "failover"}`, `MAX_RETRIES=1`, `TIMEOUT=600`, `MAX_CONCURRENT=4`. If a value differs from the YAML, Task 1 missed an override in the secret file.

- [ ] **Step 4: Confirm the container can read the token [USER SHELL]**

```bash
! ssh silverstone 'docker exec hindsight sh -c "ls -la /codex && head -c 1 /codex/auth.json >/dev/null && echo READABLE"'
```
Expected: the file listed as owned by `568`, then `READABLE`.

- [ ] **Step 5: Health check [USER SHELL]**

```bash
! ssh silverstone 'docker exec hindsight sh -c "curl -fsS http://localhost:8888/api/health"'
```
Expected: a healthy JSON response.

- [ ] **Step 6: Exercise the primary and watch which member serves it [USER SHELL]**

Start a log tail in one shell:
```bash
! ssh silverstone 'timeout 180 docker logs -f --since 1m hindsight 2>&1 | grep -iE "codex|luna|gemma|192.168.1.147|failover|member|refresh|429|model not found"'
```
Then drive a real LLM call — a reflect through the MCP/API path, or a retain of a short document via the dataplane API.

Expected: log lines showing the **primary** (`openai-codex` / `gpt-5.6-luna`) answering. 

**Failure signature to look for:** `Model not found gpt-5.6-luna...` or an immediate advance to `192.168.1.147` on every call. That means luna is unavailable to this originator/account — go to Step 7.

- [ ] **Step 7: If luna is rejected, pin a supported model**

Change `HINDSIGHT_API_LLM_MODEL` to `gpt-5.5`, commit, redeploy, and repeat Step 6. If that also fails, try `gpt-5.3-codex`. If no Codex model works, the token or account is the problem, not the model — do a fresh `codex login` into `/mnt/spool/apps/config/hindsight/codex` on silverstone and repeat. Only after both avenues fail should the litellmrouter-with-originator-spoof fallback from spec §3 be considered; that is a new design decision, not a step here.

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git commit -am "fix(hindsight): pin <model> — gpt-5.6-luna unavailable to this Codex account

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 8: Verify refresh-token rotation is durable

**Why:** the whole design depends on the container writing its rotated refresh token back to the bind mount. A silent failure here works fine until the access token expires, then breaks reflect days later.

- [ ] **Step 1: Compare mtime against the Task 2 Step 5 baseline [USER SHELL]**

```bash
! ssh silverstone 'sudo stat -c "%n %y" /mnt/spool/apps/config/hindsight/codex/auth.json'
```
Expected: mtime **newer** than the baseline recorded in Task 2, proving a rotation was written. If it is unchanged, the access token may simply still be valid — that is acceptable at this point; re-check after 24 hours.

- [ ] **Step 2: Prove the mount is writable from inside the container [USER SHELL]**

```bash
! ssh silverstone 'docker exec hindsight sh -c "touch /codex/.writetest && rm /codex/.writetest && echo WRITABLE"'
```
Expected: `WRITABLE`. If this fails, the volume was mounted `:ro` or ownership is wrong — fix and redeploy before considering the change done.

- [ ] **Step 3: Watch for the shared-chain failure [USER SHELL]**

```bash
! ssh silverstone 'docker logs --since 24h hindsight 2>&1 | grep -ciE "refresh_token_reused|permanently invalid" || echo 0'
```
Expected: `0`. A non-zero count means the source machine's codex CLI rotated the shared chain — the accepted risk from spec §6.3. Remedy: fresh `codex login` into `/mnt/spool/apps/config/hindsight/codex` on silverstone, which ends the sharing.

---

## Task 9: Verify failover actually fires

- [ ] **Step 1: Break the primary temporarily [USER SHELL]**

```bash
! ssh silverstone 'sudo mv /mnt/spool/apps/config/hindsight/codex/auth.json /mnt/spool/apps/config/hindsight/codex/auth.json.hidden && docker restart hindsight'
```
Expected: container restarts. The primary now has no credential.

- [ ] **Step 2: Drive a call and confirm member 1 serves it [USER SHELL]**

```bash
! ssh silverstone 'timeout 120 docker logs -f --since 30s hindsight 2>&1 | grep -iE "codex|192.168.1.147|gemma|failover|auth"'
```
Then issue a retain or reflect.

Expected: the primary fails, then vLLM (`192.168.1.147` / `gemma-4-12b`) answers and the operation **succeeds**. A hard failure instead means the chain is misconfigured — most likely `HINDSIGHT_API_LLM_STRATEGY` not parsed or a non-contiguous member index.

- [ ] **Step 3: Restore the primary [USER SHELL]**

```bash
! ssh silverstone 'sudo mv /mnt/spool/apps/config/hindsight/codex/auth.json.hidden /mnt/spool/apps/config/hindsight/codex/auth.json && sudo chown 568:568 /mnt/spool/apps/config/hindsight/codex/auth.json && sudo chmod 600 /mnt/spool/apps/config/hindsight/codex/auth.json && docker restart hindsight'
```
Expected: container restarts. Re-run Task 7 Step 6 and confirm the primary is serving again.

- [ ] **Step 4: Confirm the reverse case is understood, not tested**

Do **not** stop the vLLM box to test the other direction — with the primary healthy it changes nothing, and with both down the operation fails by design (spec §7). No step here.

---

## Task 10: Rotate the credentials exposed during recon

**Not part of the stack change; tracked here so it does not get dropped.** Reading the proxy config during design printed live secrets into a session transcript.

- [ ] **Step 1: Revoke the OpenAI service-account key**

The `sk-svcacct-…` key appears twice in `/mnt/spool/apps/config/hindsight/litellm/config.yaml` (on `openai/gpt-5.4-mini` and `openai/text-embedding-3-small`). Revoke it in the owning OpenAI account. The commented-out `openai.prod.ai-gateway.quantumblack.com` base URL beside it indicates it may be employer-issued, which makes this mandatory.

- [ ] **Step 2: Rotate the litellm master key**

`general_settings.master_key` in that same file, reused verbatim as `ui_password`. The proxy is gone, so nothing needs the new value — this is revocation, not reconfiguration. Confirm no other client still presents the old key.

- [ ] **Step 3: Confirm neither secret is in git**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git log --all -S "sk-svcacct" --oneline | head
git log --all -S "master_key" --oneline | head
```
Expected: no output for the first. If either returns commits, history rewriting is a separate task — stop and raise it.

---

## Task 11: Clean up (after the change is proven)

- [ ] **Step 1: Delete the Cloudflare DNS record**

Remove the `hindsight-litellm.alekseev.us` record in the Cloudflare dashboard. With the ingress gone the tunnel already answers `http_status:404`, so this is tidiness. Manual UI step, outside this repo.

- [ ] **Step 2: Remove the stale host directory [USER SHELL]**

Only once the change has run for a few days and Task 10 rotation is done:
```bash
! ssh silverstone 'sudo mv /mnt/spool/apps/config/hindsight/litellm /mnt/spool/apps/config/hindsight/litellm.removed-2026-08-23 && ls -la /mnt/spool/apps/config/hindsight/'
```
Expected: directory renamed, not deleted — keeps the rollback path alive one more step. Deleting it outright is a later decision.

- [ ] **Step 3: Note the remaining follow-ups**

Left open by design (spec §11): re-homing the Copilot/`claude-*`/embedding aliases if consumers appear; dropping the historical `litellm` Postgres schema; adding per-operation chains (`HINDSIGHT_API_{RETAIN,CONSOLIDATION}_LLM_*` with vLLM primary) if luna-for-everything proves too expensive under sustained 429s.

---

## Rollback

Any point after Task 7:

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git revert --no-edit <proxy-removal-sha> <env-chain-sha>
git push
```
Then redeploy in Portainer. The proxy's host config, Copilot tokens and Postgres schema were never removed, so previous routing returns intact. If Task 1 pruned the `hindsight_env` secret, also restore it:

```bash
! ssh silverstone 'sudo cp -a /mnt/spool/apps/config/hindsight/env.bak-2026-08-23 /mnt/spool/apps/config/hindsight/env'
```

The only non-reverting side effect is any Codex token refresh already written into the new `CODEX_HOME`.
