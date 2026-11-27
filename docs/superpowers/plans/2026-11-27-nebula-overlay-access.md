# Nebula Overlay Access to CLIProxyAPI and codex-lb — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CLIProxyAPI (`:8317`) and codex-lb (`:2455`) reachable from the user's own computers over the Managed Nebula overlay, without changing the `shared-services` paths or the Cloudflare Access dashboards.

**Architecture:** A new `stacks/nebula.yaml` runs `dnclient` in host network mode, so silverstone itself gets one IPv6 overlay address. `cliproxyapi` and `codex-lb` each publish their port bound to that address only. Nebula's firewall (role `silverstone`) admits each port only from hosts with that port's `access:*` tag. `net.ipv6.ip_nonlocal_bind=1` makes container start order irrelevant.

**Tech Stack:** Docker Compose (compose-spec), Portainer git-backed stacks, `definednet/dnclient:1.0.1`, Managed Nebula (defined.net, free plan, IPv6-only overlay), TrueNAS SCALE middleware (`midclt`).

**Spec:** `docs/superpowers/specs/2026-11-27-nebula-overlay-access-design.md`

**Branch:** `feat/nebula-overlay` in the worktree `/home/salekseev/src/github.com/salekseev/stacks-nebula-overlay` (spec commits `c11222f`, `e0d9802`). One PR.

---

## Environment notes for the implementer

- **Host:** `silverstone.local` (TrueNAS SCALE, Docker 29.0.4). ssh user `salekseev` has passwordless `sudo` but is **not** in the `docker` group: every docker command is `sudo docker ...`. The remote login shell is zsh; wrap anything with globs or loops in `sudo bash -c '...'`.
- **Workstation:** this machine is already on the overlay (`dnclient` service, interface `dn-302052`). Overlay probes in this plan run from here.
- **Do not pull or run any container image on the workstation.** Every runtime check that needs a container runs on silverstone.
- **Deployment:** Portainer deploys git-backed stacks from `master` with GitOps auto-update, so merging the PR redeploys `cliproxyapi` and `codex-lb`. Creating the new Portainer stack is a UI step for the user.
- **Local validation:** `./scripts/validate-stack.sh` needs `docker-compose`, which is not installed. Use `docker compose -f <file> config >/dev/null` (it does not check that secret files exist, and pulls nothing).
- **`[USER]` steps** need the defined.net or Portainer web UI, a dashboard login, or a secret. Hand them to the user and suggest the `! <command>` prefix for anything that must run in their shell.
- **Secrets hygiene:** never print env files, `config.yaml`, `/etc/defined` contents, enrollment codes or client keys. Print key names, lengths or file modes only. A redaction filter is not enough; select the fields you need instead.
- **codex-lb restarts** cause about five minutes of `400 model_not_found` (codex-lb spec §13). Hindsight fails over to vLLM; nod and yandex-station do not. The merge in Task 8 is that restart.
- **Ban-risk discipline (CPA test week):** no loops or load. Every model request in this plan is one deliberate call.
- **Image facts, read 2026-11-27 from `definednet/dnclient:1.0.1`:** Alpine base, runs as root, no `ENTRYPOINT`, `CMD ["/main.sh"]`, `/bin/sh` is busybox, `DNCLIENT_STATE_DIR=/etc/defined`. `/main.sh` enrolls with `DN_ENROLLMENT_CODE` only when `/etc/defined/dnclient.yml` is missing, and exits 1 if that enrollment fails. It creates `/dev/net/tun` itself if absent.
- **defined.net facts:** enrollment codes are single-use and expire after 24 h by default. In a local allow list, interface rules must all be allow or all be deny, and the default is the inverse, so allowing two interfaces denies the rest. Names are full-match regular expressions.

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `stacks/nebula.yaml` | Create | `dnclient` in host mode, one secret, state bind mount |
| `stacks/cliproxyapi.yaml` | Modify | `ports:` on the overlay address; header comment |
| `stacks/codex-lb.yaml` | Modify | `ports:` on the overlay address; header comment |
| `docs/superpowers/plans/2026-11-27-nebula-overlay-access.md` | Create | this plan |
| `docs/superpowers/specs/2026-11-27-nebula-overlay-access-design.md` | Modify (Task 10) | as-built section |

Renovate needs no change: its `docker-compose` manager matches `stacks/*.yaml`, and docker versioning does not offer the suffixed test tags (`1.1.0-networkstest7`, `-apiservertest0`) to a plain `1.0.1`.

Host only, never in git:

| Path | Holds |
|---|---|
| `/mnt/spool/apps/config/nebula/dnclient/` | enrolled host config and keys (`/etc/defined`), root, 0700 |
| `/mnt/spool/apps/config/nebula/nebula.env` | `DN_ENROLLMENT_CODE`, root, 0400; emptied after enrollment |

In this plan, `OVERLAY_V6` stands for silverstone's overlay IPv6 address, recorded in Task 3 Step 5. It is a private overlay address, not a secret, and goes into git.

---

## Task 1: Preflight on silverstone (read-only)

**Files:** none.

- [ ] **Step 0: Image signature (registry query only, nothing runs)**

```bash
command -v cosign && cosign verify --key https://dl.defined.net/docker-cosign.pub definednet/dnclient:1.0.1 >/dev/null && echo verified
```
Expected: `verified`. If `cosign` is not installed on the workstation, record that the check was skipped and continue; do not install it or pull the image here.

- [ ] **Step 1: Where `ip_nonlocal_bind` comes from**

```bash
ssh silverstone.local 'sysctl net.ipv6.ip_nonlocal_bind; sudo midclt call tunable.query | python3 -c "import json,sys; [print(t[\"var\"], t[\"value\"], t[\"enabled\"]) for t in json.load(sys.stdin)]"; sudo grep -rn nonlocal_bind /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null'
```
Expected: `net.ipv6.ip_nonlocal_bind = 1`. Record whether a TrueNAS tunable for `net.ipv6.ip_nonlocal_bind` already exists (enabled, value `1`). If it does, Task 2 Step 1 is skipped.

- [ ] **Step 2: Underlay interfaces and the listen port**

```bash
ssh silverstone.local 'ip -br addr show eno1; ip -br addr show ens1f0np0; sudo ss -ulpn | grep -w 4242 || echo "4242/udp free"'
```
Expected: both interfaces `UP` with LAN addresses, and `4242/udp free`. If 4242 is taken, use the next free port from 4243 upwards wherever this plan says 4242.

- [ ] **Step 3: Ports 8317 and 2455 are not yet bound on the host**

```bash
ssh silverstone.local 'sudo ss -ltn | grep -E ":(8317|2455)\b" || echo "not bound"'
```
Expected: `not bound`.

- [ ] **Step 4: The IPv6 network on each container**

```bash
ssh silverstone.local 'for c in cliproxyapi codex-lb; do sudo docker inspect $c --format "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} v6={{\$v.GlobalIPv6Address}} gwprio={{\$v.GwPriority}}{{\"\n\"}}{{end}}"; done'
```
Expected: on each container, only `shared-services` has a `v6=` address (`fdd0:0:0:a::7` and `fdd0:0:0:a::2`). Docker makes the first endpoint with IPv6 connectivity the IPv6 gateway, and an IPv6 published port is DNATed to that endpoint, so no `gw_priority` is needed. If either container has a second IPv6 network, add `gw_priority: 1` under its `shared-services` entry in Task 5.

- [ ] **Step 5: codex-lb's client-IP firewall `[USER]`**

In the codex-lb dashboard → Settings → Firewall: record whether an IP allowlist is enabled. If it is, the overlay prefix (`fdef:c0:c0:9189:b06a::/80`, the workstation's `/80`) must be added before Task 8 Step 3's codex-lb checks. Change nothing now.

---

## Task 2: Host preparation

**Files:** host only.

- [ ] **Step 1: Make `ip_nonlocal_bind` a TrueNAS tunable** (skip if Task 1 Step 1 found one)

```bash
ssh silverstone.local 'sudo midclt call -j tunable.create "{\"type\": \"SYSCTL\", \"var\": \"net.ipv6.ip_nonlocal_bind\", \"value\": \"1\", \"comment\": \"stacks/nebula.yaml: lets Docker publish ports on the Nebula overlay address before dnclient is up\"}" >/dev/null; sudo midclt call tunable.query "[[\"var\", \"=\", \"net.ipv6.ip_nonlocal_bind\"]]" | python3 -c "import json,sys; t=json.load(sys.stdin)[0]; print(t[\"var\"], t[\"value\"], t[\"enabled\"])"'
```
Expected: `net.ipv6.ip_nonlocal_bind 1 True`. If `-j` is rejected, run it without `-j`. If the middleware rejects the call, the user adds it in System → Advanced Settings → Sysctl `[USER]`.

- [ ] **Step 2: Create the dataset**

```bash
ssh silverstone.local 'sudo midclt call pool.dataset.create "{\"name\": \"spool/apps/config/nebula\", \"share_type\": \"APPS\", \"atime\": \"OFF\"}" >/dev/null; zfs list -H -o name,mountpoint,atime spool/apps/config/nebula'
```
Expected: `spool/apps/config/nebula	/mnt/spool/apps/config/nebula	off`.

- [ ] **Step 3: Strip the Apps-preset ACL**

The Apps preset grants `group:builtin_users` read/write through inherited NFSv4 ACEs, which `chmod` does not remove.
```bash
ssh silverstone.local 'sudo midclt call -j filesystem.setacl "{\"path\": \"/mnt/spool/apps/config/nebula\", \"dacl\": [], \"options\": {\"stripacl\": true, \"recursive\": true}}" >/dev/null; sudo nfs4xdr_getfacl /mnt/spool/apps/config/nebula'
```
Expected: only `owner@`, `group@` and `everyone@` entries, no `group:builtin_users`.

- [ ] **Step 4: Owner, mode and the state directory**

```bash
ssh silverstone.local 'sudo bash -c "set -e; N=/mnt/spool/apps/config/nebula; chown 0:0 \$N; chmod 0700 \$N; install -d -o 0 -g 0 -m 0700 \$N/dnclient; ls -lnd \$N \$N/dnclient; nfs4xdr_getfacl \$N/dnclient | grep -c builtin_users || true"'
```
Expected: both `drwx------ ... 0 0`, and `0` (no `builtin_users` entries on `dnclient/`).

---

## Task 3: Configure defined.net `[USER]`

All in the defined.net web UI. Role names cannot be renamed later.

- [ ] **Step 1: Underlay tag `[USER]`**

Tags → create `docker:host`. Host advanced config → local allow list, interface rules, **allow** `eno1` and **allow** `ens1f0np0`, no deny rules. Every other interface (`docker0`, `br-*`, `veth*`, `tailscale0`, `truenasbr0`, `macvtap*`, `ens1f*v*`) is then excluded.

- [ ] **Step 2: Access tags `[USER]`**

Create tags `access:cpa` and `access:codex-lb`. Add both to this workstation's host entry. Add them to other machines only when you want them to have access; the work laptop only if your employer's policy allows.

- [ ] **Step 3: Role `[USER]`**

Roles → create `silverstone`. Inbound rules:
- TCP `8317`, allowed tag `access:cpa`;
- TCP `2455`, allowed tag `access:codex-lb`.

Keep the default ICMP rule. No other rules. Save role.

- [ ] **Step 4: Host `[USER]`**

Hosts → add host `silverstone`, role `silverstone`, tag `docker:host`. Accept the assigned IPv6 overlay address or pick one in the network's range; it does not change afterwards. Advanced → listen port `4242` (or Task 1 Step 2's choice). Copy the enrollment code; it is single-use and expires in 24 h.

- [ ] **Step 5: Hand over the address and the code `[USER]`**

Tell the implementer the overlay address (not secret). That value is `OVERLAY_V6` from here on. Write the code to silverstone in your own shell; it never enters the transcript:
```bash
! read -rs -p "enrollment code: " C; echo; printf 'DN_ENROLLMENT_CODE=%s\n' "$C" | ssh silverstone.local 'sudo sh -c "umask 0377; cat > /mnt/spool/apps/config/nebula/nebula.env"'; unset C
```

- [ ] **Step 6: File written, value not shown**

```bash
ssh silverstone.local 'sudo ls -ln /mnt/spool/apps/config/nebula/nebula.env; sudo sed "s/=.*//" /mnt/spool/apps/config/nebula/nebula.env'
```
Expected: `-r-------- 1 0 0 ...` and the single line `DN_ENROLLMENT_CODE`.

---

## Task 4: Write `stacks/nebula.yaml`

**Files:**
- Create: `stacks/nebula.yaml`

- [ ] **Step 1: Validation fails before the file exists**

Run: `docker compose -f stacks/nebula.yaml config >/dev/null`
Expected: error, `no such file or directory`.

- [ ] **Step 2: Write the file**

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Silverstone's identity on the Managed Nebula overlay (defined.net).
# See docs/superpowers/specs/2026-11-27-nebula-overlay-access-design.md
#
# Host network mode: the overlay interface (dn-*) and silverstone's overlay
# address live in the host's own namespace. A stack that should be reachable
# from the overlay publishes a port bound to that address only, e.g.
#   "[OVERLAY_V6]:8317:8317"   (stacks/cliproxyapi.yaml)
#   "[OVERLAY_V6]:2455:2455"   (stacks/codex-lb.yaml)
# Nebula's firewall (role "silverstone" in the defined.net UI) admits each port
# only from hosts carrying that port's access:* tag; nothing else is open.
# net.ipv6.ip_nonlocal_bind=1 (a TrueNAS sysctl tunable) lets those ports bind
# before this container has created the interface, so start order is irrelevant.
#
# Host state (ZFS dataset spool/apps/config/nebula, root-owned, 0700):
#   /mnt/spool/apps/config/nebula/dnclient/    -> /etc/defined (enrolled host config and keys)
#   /mnt/spool/apps/config/nebula/nebula.env   0400 -> DN_ENROLLMENT_CODE. Read only while
#     dnclient.yml is missing (first run). Single-use, 24 h; emptied after enrollment.
#
# Underlay addresses advertised to the lighthouse are limited by the docker:host
# tag (allow eno1, ens1f0np0) so Docker bridges and tailscale0 are never used.

services:

  dnclient:
    image: definednet/dnclient:1.0.1
    container_name: nebula
    network_mode: host
    # Root is required: the image runs as root and creates the tun device.
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    # env_file: is resolved at compose-parse time, which fails inside Portainer.
    # A Docker secret defers the path to the daemon (same as hindsight and nod).
    # The image has no ENTRYPOINT; its CMD is /main.sh.
    entrypoint:
      - sh
      - -c
      - set -a; . /run/secrets/nebula_env; set +a; exec /main.sh
    secrets:
      - nebula_env
    environment:
      TZ: America/New_York
    volumes:
      - /mnt/spool/apps/config/nebula/dnclient:/etc/defined
    restart: unless-stopped

secrets:
  nebula_env:
    file: /mnt/spool/apps/config/nebula/nebula.env
```

Replace both `OVERLAY_V6` in the comment with the real address.

- [ ] **Step 3: Validate**

Run: `docker compose -f stacks/nebula.yaml config >/dev/null && echo ok`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add stacks/nebula.yaml
git commit -m "feat(nebula): put silverstone on the Managed Nebula overlay" -m "Host-mode dnclient gives silverstone one IPv6 overlay address that other stacks publish ports on. Enrollment code arrives as a Docker secret; state lives on spool/apps/config/nebula." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 5: Publish CPA and codex-lb on the overlay address

**Files:**
- Modify: `stacks/cliproxyapi.yaml` (header lines 10–11 and 22–27; `cliproxyapi` service after `expose:`)
- Modify: `stacks/codex-lb.yaml` (header lines 16–21; `codex-lb` service after `expose:`)

- [ ] **Step 1: Baseline: no host ports in either rendered stack**

```bash
for f in cliproxyapi codex-lb; do docker compose -f stacks/$f.yaml config --format json | python3 -c "import json,sys; s=json.load(sys.stdin)['services']; print('$f', {k: v.get('ports') for k, v in s.items() if v.get('ports')})"; done
```
Expected: `cliproxyapi {}` and `codex-lb {}`.

- [ ] **Step 2: `stacks/cliproxyapi.yaml` header**

Replace
```
# Consumers (later) on the external shared-services network call
#   http://cliproxyapi:8317/v1   (OpenAI-compatible; Bearer = a key in access.api-keys)
```
with
```
# Consumers on the external shared-services network call
#   http://cliproxyapi:8317/v1   (OpenAI-compatible; Bearer = a key in access.api-keys)
# Machines on the Nebula overlay tagged access:cpa call
#   http://[OVERLAY_V6]:8317     (Claude Code: ANTHROPIC_BASE_URL; one key per machine)
```
and replace
```
# Nothing published to host; CPA's OAuth callback ports are never published.
# OMC is reachable only through cloudflared (Cloudflare Access, origin JWT check),
# then its own login (= the CPA management key). OMC is NOT on shared-services.
# Accepted exposure: CPA serves /v1 and /v8/management on one port, and OMC needs
# management.allow-remote, so the management API is reachable from shared-services,
# guarded by the management key only.
```
with
```
# Published only on silverstone's Nebula overlay address (stacks/nebula.yaml),
# port 8317; nothing on LAN or public addresses. CPA's OAuth callback ports are
# never published.
# OMC is reachable only through cloudflared (Cloudflare Access, origin JWT check),
# then its own login (= the CPA management key). OMC is NOT on shared-services.
# Accepted exposure: CPA serves /v1 and /v8/management on one port, and OMC needs
# management.allow-remote, so the management API is reachable from shared-services
# and from admitted overlay machines, guarded by the management key only.
```

- [ ] **Step 3: `stacks/cliproxyapi.yaml` port**

In the `cliproxyapi` service, replace
```yaml
    expose:
      - "8317"
    healthcheck:
      # Debian image without curl or wget: speak HTTP through bash's /dev/tcp.
```
with
```yaml
    expose:
      - "8317"
    ports:
      # Overlay address only (stacks/nebula.yaml). Nebula's firewall admits
      # machines tagged access:cpa. ip_nonlocal_bind lets this bind before
      # dnclient is up.
      - "[OVERLAY_V6]:8317:8317"
    healthcheck:
      # Debian image without curl or wget: speak HTTP through bash's /dev/tcp.
```

- [ ] **Step 4: `stacks/codex-lb.yaml` header**

Replace
```
# Nothing published to host. SSO identity (the Cf-Access header) is honoured only
# from cloudflared, which validates the Access JWT. Port 2455 is also reachable
# from shared-services; there the dashboard offers only the break-glass local
```
with
```
# Published only on silverstone's Nebula overlay address (stacks/nebula.yaml),
# port 2455, for machines tagged access:codex-lb; nothing on LAN or public
# addresses. SSO identity (the Cf-Access header) is honoured only
# from cloudflared, which validates the Access JWT. Port 2455 is also reachable
# from shared-services and the overlay; there the dashboard offers only the break-glass local
```

- [ ] **Step 5: `stacks/codex-lb.yaml` port**

In the `codex-lb` service, replace
```yaml
    expose:
      - "2455"
```
with
```yaml
    expose:
      - "2455"
    ports:
      # Overlay address only (stacks/nebula.yaml). Nebula's firewall admits
      # machines tagged access:codex-lb. Never publish 1455 (OAuth callback).
      - "[OVERLAY_V6]:2455:2455"
```

Replace every `OVERLAY_V6` from Steps 2–5 with the real address. If Task 1 Step 4 found a second IPv6 network on either container, also add `gw_priority: 1` under that service's `shared-services` network entry.

- [ ] **Step 6: Rendered ports are exactly the two overlay bindings**

```bash
for f in cliproxyapi codex-lb; do docker compose -f stacks/$f.yaml config --format json | python3 -c "import json,sys; s=json.load(sys.stdin)['services']; print('$f', {k: [(p.get('host_ip'), p.get('published'), p.get('target')) for p in v['ports']] for k, v in s.items() if v.get('ports')})"; done
```
Expected: `cliproxyapi {'cliproxyapi': [('OVERLAY_V6', '8317', 8317)]}` and `codex-lb {'codex-lb': [('OVERLAY_V6', '2455', 2455)]}`, with the real address, and no other service with ports.

- [ ] **Step 7: Commit**

```bash
git add stacks/cliproxyapi.yaml stacks/codex-lb.yaml
git commit -m "feat(nebula): publish CLIProxyAPI and codex-lb on the overlay address" -m "Each gateway publishes its port bound only to silverstone's Nebula address; Nebula's firewall admits it per access:* tag. shared-services and the Cloudflare Access dashboards are unchanged; codex-lb's 1455 stays unpublished." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 6: Commit the plan, push and open the PR

- [ ] **Step 1: Commit the plan**

```bash
git add docs/superpowers/plans/2026-11-27-nebula-overlay-access.md
git commit -m "docs(nebula): implementation plan for overlay access" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/nebula-overlay
gh pr create --base master --title "feat(nebula): reach CLIProxyAPI and codex-lb over the Nebula overlay" --body-file <scratchpad>/nebula-pr.md
```
PR body:
```markdown
## Summary

New `stacks/nebula.yaml` puts silverstone on the Managed Nebula overlay (host-mode `dnclient`). `cliproxyapi` publishes `8317` and `codex-lb` publishes `2455`, each bound only to silverstone's overlay IPv6 address.

- Nebula's firewall (role `silverstone`) admits 8317 from tag `access:cpa` and 2455 from `access:codex-lb`; nothing else is open on the overlay address.
- `shared-services` paths and the Cloudflare Access dashboards are unchanged. OMC, CPA's OAuth callback ports and codex-lb's 1455 stay unpublished.
- No defined.net routes are used; one host of the free plan's 100.
- `net.ipv6.ip_nonlocal_bind=1` (TrueNAS tunable) makes start order irrelevant.

Design: `docs/superpowers/specs/2026-11-27-nebula-overlay-access-design.md`
Plan: `docs/superpowers/plans/2026-11-27-nebula-overlay-access.md`

## Merge timing

Merging redeploys codex-lb, which returns `400 model_not_found` for about five minutes after any restart. Merge at a quiet time.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

---

## Task 7: Merge and deploy `[USER]`

- [ ] **Step 1: Merge at a quiet time `[USER]`**

Merge the PR. GitOps redeploys `cliproxyapi` and `codex-lb`.

- [ ] **Step 2: Create the Portainer stack `[USER]`**

Portainer → Stacks → Add stack → **Repository**: this repo, `refs/heads/master`, compose path `stacks/nebula.yaml`, stack name `nebula`, no environment variables, same GitOps setting as the other stacks. Deploy within 24 h of Task 3 Step 4. If the code has expired, generate a new one on the host's page in defined.net and repeat Task 3 Steps 5–6.

- [ ] **Step 3: Existing stacks redeployed healthy, with the bindings**

```bash
ssh silverstone.local 'sudo docker ps --filter name=cliproxyapi --filter name=codex-lb --format "{{.Names}}\t{{.Status}}"; sudo docker port cliproxyapi; sudo docker port codex-lb'
```
Expected: `cliproxyapi`, `cliproxyapi-omc` and `codex-lb` `(healthy)`, both cloudflared containers `Up`; `8317/tcp -> [OVERLAY_V6]:8317` and `2455/tcp -> [OVERLAY_V6]:2455`, nothing else.

- [ ] **Step 4: dnclient enrolled and up**

```bash
ssh silverstone.local 'sudo docker ps --filter name=^nebula$ --format "{{.Names}}\t{{.Status}}"; sudo docker logs --tail 40 nebula 2>&1 | grep -iE "enroll|error|fail|handshake|started" | grep -viE "code|key" | tail -10; ip -br addr | grep "^dn-"; sudo ls -ln /mnt/spool/apps/config/nebula/dnclient | sed -E "s/ +/ /g" | cut -d" " -f1,3,4,9'
```
Expected: `nebula` `Up` and not restarting; no enrollment failure in the logs; a `dn-*` interface carrying `OVERLAY_V6`; `dnclient.yml` present in the state directory, owned by `0 0`.

**If the container restarts with "Enrollment failed.":** the code was used or expired. Generate a new code (Task 3 Step 4's host page), repeat Task 3 Steps 5–6, and restart the container: `ssh silverstone.local 'sudo docker restart nebula'`.

- [ ] **Step 5: Empty the enrollment code**

```bash
ssh silverstone.local 'sudo sh -c ": > /mnt/spool/apps/config/nebula/nebula.env"; sudo ls -ln /mnt/spool/apps/config/nebula/nebula.env'
```
Expected: size `0`, mode still `-r--------`, owner `0 0`.

- [ ] **Step 6: Overlay listeners only**

```bash
ssh silverstone.local 'sudo ss -ltn | grep -E ":(8317|2455)\b"'
```
Expected: exactly two lines, `[OVERLAY_V6]:8317` and `[OVERLAY_V6]:2455` (or none if Docker uses only NAT rules; then Task 8 Step 3 is the proof).

---

## Task 8: Verify (spec §7)

All overlay probes run on the workstation. Replace `OVERLAY_V6` with the real address; `curl -g` is needed for the bracketed literal.

- [ ] **Step 1: Internal paths unchanged**

```bash
ssh silverstone.local 'for u in http://cliproxyapi:8317/healthz http://codex-lb:2455/health/ready; do sudo docker run --rm --network shared-services curlimages/curl:8.17.0 -s -o /dev/null -m 5 -w "$u %{http_code}\n" $u; done'
```
Expected: both `200`.

- [ ] **Step 2: Dashboards unchanged `[USER]`**

`https://cpa.alekseev.us` and the codex-lb hostname each show the Cloudflare Access login, then their dashboard.

- [ ] **Step 3: Overlay, allowed (workstation has both tags)**

```bash
V6=OVERLAY_V6
for u in /healthz /v1/models; do curl -g -s -o /dev/null -m 10 -w "cpa $u %{http_code}\n" "http://[$V6]:8317$u"; done
for u in /health/ready /v1/models; do curl -g -s -o /dev/null -m 10 -w "codex-lb $u %{http_code}\n" "http://[$V6]:2455$u"; done
curl -g -s -o /dev/null -m 10 -w "codex-lb forged-header %{http_code}\n" -H "Cf-Access-Authenticated-User-Email: someone@example.com" "http://[$V6]:2455/api/accounts"
curl -g -s -o /dev/null -m 10 -w "codex-lb no-header %{http_code}\n" "http://[$V6]:2455/api/accounts"
```
Expected: `cpa /healthz 200`, `cpa /v1/models 401`, `codex-lb /health/ready 200`, `codex-lb /v1/models 401`, forged-header and no-header both `401`.
If codex-lb returns `403` here and Task 1 Step 5 found an IP allowlist, add the overlay `/80` there `[USER]` and repeat.

- [ ] **Step 4: Overlay, denied by tag `[USER]` + probe**

The user removes both `access:*` tags from the workstation host in defined.net and waits about a minute for the change to reach the hosts. Then:
```bash
V6=OVERLAY_V6; for p in 8317 2455; do curl -g -s -o /dev/null -m 8 "http://[$V6]:$p/"; echo "$p exit=$?"; done
```
Expected: `exit=28` (timeout) for both. The user adds back `access:cpa` only; re-run: `8317` returns exit `0`, `2455` still `exit=28`. The user adds back `access:codex-lb`; Step 3 passes again.

- [ ] **Step 5: Other ports closed on the overlay address**

```bash
V6=OVERLAY_V6; for p in 22 80 443 445 1455; do timeout 8 bash -c "exec 3<>/dev/tcp/$V6/$p" 2>/dev/null; echo "$p exit=$?"; done
```
Expected: `exit=124` (timeout, dropped by Nebula) for every port. `exit=0` on any port means the role has an extra rule: stop and fix the role.

- [ ] **Step 6: Not reachable on LAN or public addresses**

```bash
for h in 192.168.1.10 "[2600:4040:5b42:2501:ae1f:6bff:fe2c:abf6]"; do for p in 8317 2455; do curl -g -s -o /dev/null -m 5 "http://$h:$p/"; echo "$h:$p exit=$?"; done; done
```
Expected: `exit=7` (connection refused) for all four.

- [ ] **Step 6b: Accepted paths around Nebula (spec §3)**

From a container on silverstone that is not on `shared-services`:
```bash
ssh silverstone.local 'sudo docker run --rm --network bridge curlimages/curl:8.17.0 -g -s -o /dev/null -m 5 -w "%{http_code}\n" "http://[OVERLAY_V6]:8317/healthz"'
```
Expected: `200` (accepted exposure, recorded in the as-built). From the LAN, bypassing this machine's own overlay route with a temporary `/128` `[USER]`:
```bash
! sudo ip -6 route add OVERLAY_V6/128 via 2600:4040:5b42:2501:ae1f:6bff:fe2c:abf6 dev eno1; curl -g -s -o /dev/null -m 5 -w "%{http_code}\n" "http://[OVERLAY_V6]:8317/healthz"; sudo ip -6 route del OVERLAY_V6/128
```
Expected: `200`, then the route is gone (`ip -6 route get OVERLAY_V6` shows the `dn-*` interface again).

- [ ] **Step 7: Underlay addresses `[USER]`**

defined.net → host `silverstone`: the advertised addresses come only from `eno1` and `ens1f0np0` (LAN IPv4 `192.168.1.10`, the `2600:4040:5b42:2501::/64` addresses, and the public address the lighthouse sees). No `172.*`, `fdd0:*`, `100.*` or `fd7a:*` addresses.

- [ ] **Step 8: Start order**

```bash
ssh silverstone.local 'sudo docker stop nebula; ip -br addr | grep -c "^dn-"; sudo docker restart cliproxyapi; sleep 20; sudo docker ps --filter name=^cliproxyapi$ --format "{{.Status}}"; sudo docker port cliproxyapi'
```
Expected: `0` (no overlay interface), `cliproxyapi` `Up` (healthy once its healthcheck runs), `8317/tcp -> [OVERLAY_V6]:8317`. Then re-run Step 1 (both `200`) and:
```bash
ssh silverstone.local 'sudo docker start nebula'
```
After about 30 s, Step 3's `cpa /healthz` line returns `200`. codex-lb is not restarted for this test (its five-minute warm-up); it uses the same mechanism.

- [ ] **Step 9: One request per gateway with a per-machine key `[USER]`**

1. OMC → API keys: create a client key named after this workstation. codex-lb dashboard → API keys: create one named after this workstation, allowlist the models it may use, traffic class `foreground`.
2. CPA models, then one Claude Code call (one request; the model id comes from the list):
```bash
! read -rs -p "cpa key: " K; echo; curl -g -s -H "Authorization: Bearer $K" "http://[OVERLAY_V6]:8317/v1/models" | python3 -c 'import json,sys; print("\n".join(m["id"] for m in json.load(sys.stdin)["data"]))'; unset K
```
```bash
! read -rs -p "cpa key: " K; echo; M=<MODEL_ID>; ANTHROPIC_BASE_URL="http://[OVERLAY_V6]:8317" ANTHROPIC_AUTH_TOKEN="$K" ANTHROPIC_MODEL="$M" ANTHROPIC_DEFAULT_HAIKU_MODEL="$M" claude -p "Reply with the single word: pong"; unset K M
```
3. One codex-lb Responses call, with a model the key allows:
```bash
! read -rs -p "codex-lb key: " K; echo; curl -g -s -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d '{"model":"gpt-6-luna","input":"Reply with the single word: pong"}' "http://[OVERLAY_V6]:2455/v1/responses" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("status"), [c.get("text") for o in r.get("output",[]) for c in o.get("content",[]) if c.get("type")=="output_text"])'; unset K
```
Expected: a model list; `pong` from Claude Code; `completed ['pong']` from codex-lb. Each dashboard shows the request under the workstation's key.

---

## Task 9: Client setup on other machines `[USER]`

Per machine, after tagging it in defined.net and creating its own keys. Nothing here goes into this repo.

- [ ] **Step 1: Claude Code through CPA**

`~/.claude/settings.json`:
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://[OVERLAY_V6]:8317",
    "ANTHROPIC_AUTH_TOKEN": "<this machine's CPA key>",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "<model id from /v1/models>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "<model id from /v1/models>",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "<model id from /v1/models>"
  }
}
```

- [ ] **Step 2: Codex CLI through codex-lb**

`~/.codex/config.toml`, key in the `CODEX_LB_API_KEY` environment variable:
```toml
model_provider = "codex-lb"

[model_providers.codex-lb]
name = "codex-lb"
base_url = "http://[OVERLAY_V6]:2455/v1"
env_key = "CODEX_LB_API_KEY"
wire_api = "responses"
```

---

## Task 10: Record the result

**Files:**
- Modify: `docs/superpowers/specs/2026-11-27-nebula-overlay-access-design.md` (append `## 11. As-built (<date>)`)

- [ ] **Step 1: Write the as-built section**

Record, from Tasks 1–8: the overlay address; whether the `ip_nonlocal_bind` tunable already existed or was created; whether `gw_priority` was needed; whether codex-lb had an IP allowlist; each Task 8 step's actual result; the enrollment path (first try or a regenerated code); any deviation from this plan and why. Mark *(verify)* items in the spec as confirmed or corrected here.

- [ ] **Step 2: Commit and PR**

```bash
git switch -c docs/nebula-as-built origin/master
git add docs/superpowers/specs/2026-11-27-nebula-overlay-access-design.md
git commit -m "docs(nebula): as-built for overlay access" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin docs/nebula-as-built
gh pr create --base master --title "docs(nebula): as-built for overlay access" --body "As-built record for the Nebula overlay access change.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
