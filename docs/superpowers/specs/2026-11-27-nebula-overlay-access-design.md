# Remote access to CLIProxyAPI and codex-lb over the Nebula overlay — Design Spec

- **Date:** 2026-11-27
- **Status:** Draft for user review.
- **Stack files:** `stacks/nebula.yaml` (new); `stacks/cliproxyapi.yaml` and `stacks/codex-lb.yaml` (one `ports:` entry each, and their header comments)
- **Author:** brainstormed with Claude Code
- **Host facts:** checked on silverstone 2026-11-27 unless marked *(verify)*; the plan checks every *(verify)* item.

---

## 1. Goal & framing

Let Claude Code, Codex and other clients on the user's other personal computers use both subscription gateways, CLIProxyAPI (CPA) and codex-lb, over the user's Managed Nebula network (defined.net).

Requirements:

1. **Existing paths keep working unchanged.** Internal consumers (hindsight, nod and other stacks) reach `http://cliproxyapi:8317` and `http://codex-lb:2455` on `shared-services`. The Oh My CPA (OMC) dashboard at `cpa.alekseev.us` and the codex-lb dashboard stay behind their own cloudflared and Cloudflare Access.
2. **No defined.net routes.** The free plan allows 2; this design uses none. It uses one host (of 100).
3. **IPv6-only overlay.** The network has no IPv4 range, and this design does not add one.
4. **No proxy.** The user accepts that each gateway's whole port is reachable from overlay hosts that the Nebula firewall admits: CPA's `/v1` and `/v8/management` (guarded by the management key), and codex-lb's proxy routes and dashboard (proxy routes need an API key; the dashboard offers only its local login, password plus TOTP, as on `shared-services` today).
5. **Works for every overlay member, including the work laptop,** where Tailscale does not work but Nebula does. Tailscale keeps running side by side on other machines and plays no part here.

Not a goal: overlay DNS, publishing OMC (`8080`) or codex-lb's OAuth callback port (`1455`) on the overlay.

## 2. Decision: silverstone joins the overlay; services publish on its overlay address only

Compared 2026-11-27:

| | Host-mode dnclient + overlay-bound `ports:` (**chosen**) | dnclient sidecar in a bridge network + reverse proxy | Service shares dnclient's network namespace |
|---|---|---|---|
| Containers | 1, in its own stack | 2 per exposed stack | 1 per exposed stack |
| Documented by defined.net | Yes (`--network host`) | No | No |
| Each extra service | One `ports:` line + one firewall rule | Another sidecar pair | Rewire that service's networks |
| Weak point | TrueNAS host gets an overlay address; Nebula's firewall is the only gate on it | More moving parts; NAT'd underlay | dnclient restart drops the service's network until it is recreated |

The sidecar's main advantage, filtering `/v8/management` out, is no longer needed (§1, requirement 4). Tailscale was not considered further because it does not work on the work laptop.

## 3. Topology

```
hindsight / nod / tools ─ shared-services ──────► cliproxyapi:8317, codex-lb:2455     (unchanged)
Cloudflare Access ─► cliproxyapi-cloudflared ─ cpa-edge ─► omc:8080                   (unchanged)
Cloudflare Access ─► codex-lb-cloudflared ─ codex-lb-edge ─► codex-lb:2455            (unchanged)

laptop (dnclient, tags access:cpa / access:codex-lb)
  ══ Nebula (direct UDP or managed-lighthouse relay) ══► silverstone dn-* interface
       [<SILVERSTONE_OVERLAY_V6>]:8317 ─ Docker DNAT ─► cliproxyapi  (shared-services, fdd0:0:0:a::7)
       [<SILVERSTONE_OVERLAY_V6>]:2455 ─ Docker DNAT ─► codex-lb     (shared-services, fdd0:0:0:a::2)
```

- `stacks/nebula.yaml` gives silverstone itself one overlay identity, in the host network namespace. Every stack that wants overlay access publishes a port bound to that one address.
- `shared-services` is the only IPv6 network on either container (`cpa-internal` and `codex-lb-edge` are IPv4-only), so Docker DNATs the overlay IPv6 address to the container's `shared-services` address; no IPv4 translation is involved. That Docker picks `shared-services` as codex-lb's IPv6 gateway endpoint, given its second network `codex-lb-edge` *(verify)*; if not, `gw_priority` on `shared-services` fixes it.
- Clients keep their overlay source address through the DNAT. codex-lb trusts the Cloudflare Access identity header only from `172.31.255.248/29` (`codex-lb-edge`), so a header forged by an overlay client is ignored, as one forged on `shared-services` is today.
- **Boot order does not matter.** `net.ipv6.ip_nonlocal_bind=1` is already set on silverstone, so Docker can bind the published ports to the overlay address before dnclient has created the interface. Without it, `cliproxyapi` and `codex-lb` would fail to start whenever dnclient came up second, taking their internal paths down too; §6 covers keeping it set.
- Nothing is published on LAN or public addresses. OMC, CPA's OAuth callback ports and codex-lb's `1455` stay unpublished.

## 4. Changes

### 4.1 `stacks/nebula.yaml` (new)

| Item | Value |
|---|---|
| Image | `definednet/dnclient:1.0.1` (latest release, 2026-11-23); signed, verify with `cosign verify --key https://dl.defined.net/docker-cosign.pub` |
| Container | `nebula`, `network_mode: host`, `restart: unless-stopped` |
| Privileges | `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun]` (present on silverstone); runs as the image's user, root *(verify)* |
| State | `/mnt/spool/apps/config/nebula` → `/etc/defined`; new dataset `spool/apps/config/nebula`, created like the others, ACL stripped, `0700` |
| Enrollment | `DN_ENROLLMENT_CODE` is needed on the first run only. It reaches the container as a Docker secret sourced by an entrypoint wrapper, the hindsight/nod pattern; nothing in git or Portainer env. Needs a shell in the image and its real entrypoint *(verify)*. After enrollment the secret file is emptied (the code is single-use *(verify)*) |
| Renovate | Default rules. Docker versioning ignores the suffixed test tags (`1.1.0-networkstest7`, `-apiservertest0`). A bad patch breaks overlay access only |

### 4.2 defined.net (user, in the web UI)

1. **Host** `silverstone` with a fixed IPv6 overlay address, `<SILVERSTONE_OVERLAY_V6>`, picked at creation. It goes into git (a private overlay address, not a secret). Advanced tab: fixed listen port `4242/udp`.
2. **Underlay allow list**, as a tag on silverstone, e.g. `docker:host`. Allow only `eno1` and `ens1f0np0`, the two LAN-facing interfaces. Everything else is excluded: `docker0`, `br-*`, `veth*` (about 25 bridges; the lighthouse tracks only 20 addresses per host), `tailscale0` (so Nebula never rides inside Tailscale), `truenasbr0`, `macvtap*`, the `ens1f*v*` virtual functions. Whether listing only allowed interfaces implicitly denies the rest *(verify)*; if not, deny each pattern.
3. **Role** `silverstone` (role names cannot be renamed later). Inbound rules: TCP `8317` from tag `access:cpa`; TCP `2455` from tag `access:codex-lb`. No other inbound rule apart from the default ICMP, so SSH, the TrueNAS web UI and SMB stay closed on the overlay address.
4. **Tags** `access:cpa` and `access:codex-lb` on each computer that may use that gateway. A machine is opted in per gateway by tagging it. The work laptop gets a tag only if the employer's policy allows its code and prompts to go through that gateway's personal subscriptions.

### 4.3 `stacks/cliproxyapi.yaml`

```yaml
    ports:
      # Overlay address only (stacks/nebula.yaml). Nebula's firewall admits
      # hosts tagged access:cpa. ip_nonlocal_bind lets this bind before dnclient is up.
      - "[<SILVERSTONE_OVERLAY_V6>]:8317:8317"
```

`expose: ["8317"]` and both networks stay. The header comment "Nothing published to host" becomes "Published on the Nebula overlay address only (port 8317); nothing on LAN or public addresses". OMC and cloudflared are untouched.

### 4.4 `stacks/codex-lb.yaml`

```yaml
    ports:
      # Overlay address only (stacks/nebula.yaml). Nebula's firewall admits
      # hosts tagged access:codex-lb. Never publish 1455 (OAuth callback).
      - "[<SILVERSTONE_OVERLAY_V6>]:2455:2455"
```

`expose`, both networks and the trusted-header settings stay. The header comment "Nothing published to host" becomes "Published on the Nebula overlay address only (port 2455); nothing on LAN or public addresses", and the sentence about the break-glass login on `shared-services` extends to the overlay. Whether codex-lb's own client-IP firewall has an allowlist set that would refuse overlay addresses *(verify, read-only, in the dashboard settings)*.

Redeploying codex-lb causes about five minutes of `400 model_not_found` (2026-11-17 spec §13). Hindsight fails over to vLLM; nod and yandex-station do not. Deploy it at a quiet time.

## 5. Clients and authentication

Two gates, in order: the Nebula certificate plus the firewall tag (machine level), then the gateway's own client key (request level).

- **One key per machine per gateway**, named after the machine, so one machine can be revoked without touching the others, and each dashboard shows which machine used what. CPA keys go in `access.api-keys` through OMC; codex-lb keys are created in its dashboard, with a model allowlist and traffic class like the per-stack keys. The user delivers keys to the machines, never through this repo.
- **codex-lb clients** (Codex CLI and other OpenAI-compatible tools) use `http://[<SILVERSTONE_OVERLAY_V6>]:2455/v1` with that machine's codex-lb key, as the stacks on `shared-services` do.
- **Claude Code settings** for CPA on each machine (`~/.claude/settings.json` `env`):
  - `ANTHROPIC_BASE_URL=http://[<SILVERSTONE_OVERLAY_V6>]:8317`
  - `ANTHROPIC_AUTH_TOKEN=<that machine's key>`
  - model mapping through `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` to models CPA lists in `/v1/models`. CPA's Claude-format `/v1/messages` endpoint *(verify)*.
- Plain HTTP: Nebula encrypts and mutually authenticates the hop.
- **Test phase:** the CPA test week (2026-11-26 spec §8) is still running. Building the overlay does not send traffic; pointing a machine's Claude Code at it does, and adds agentic volume to two test accounts. When to do that is the user's call.

## 6. Failure modes

| Failure | Effect | Handling |
|---|---|---|
| dnclient down, or defined.net unreachable at start | Overlay access lost | Internal and dashboard paths unaffected; `restart: unless-stopped` |
| `ip_nonlocal_bind` lost after a reboot or TrueNAS upgrade | `cliproxyapi` and `codex-lb` fail to start if dnclient is not up yet, which breaks their internal paths too | Make it a TrueNAS sysctl tunable (System → Advanced → Sysctl) instead of relying on whatever sets it now *(verify which)* |
| Overlay address changed in the UI | Published ports bound to a stale address; overlay access lost | Address is fixed at creation; changing it means editing both stack files |
| An overlay machine is lost or stolen | Its Nebula certificate and gateway keys work until revoked | Delete the host in defined.net, then its keys in OMC and codex-lb |
| A firewall rule widened to "any" | TrueNAS SSH, web UI and SMB exposed to every overlay host | Rules are per port and per tag; the verification probes those ports |
| Docker bridge addresses leak to the lighthouse | Peers try unreachable endpoints; slow or relayed connections | Underlay allow list (§4.2 item 2) |
| Work network blocks direct UDP | Traffic relayed through the managed lighthouse | Acceptable latency for API calls |

## 7. Verification

1. **Internal paths, unchanged:** from `nod-server` (on `shared-services`), `GET http://cliproxyapi:8317/healthz` and `GET http://codex-lb:2455/health/ready` return 200.
2. **Dashboards, unchanged:** `https://cpa.alekseev.us` and the codex-lb hostname show the Access login, then the dashboard.
3. **Overlay, allowed:** from the workstation, tagged with both tags:
   - CPA: `/healthz` → 200; `/v1/models` without a key → 401, with that machine's key → 200;
   - codex-lb: `/health/ready` → 200; `/v1/models` without a key → 401; `/api/accounts` with a forged `Cf-Access-Authenticated-User-Email` → 401, the same as with no header.
4. **Overlay, denied:** from an overlay host without the tags, connecting to 8317 and 2455 times out; with only `access:cpa`, 2455 times out.
5. **Overlay, other ports:** from the workstation, silverstone's overlay address on TCP 22, 80, 443, 445 and 1455 times out.
6. **Not on the LAN:** `192.168.1.10` and silverstone's global IPv6 refuse on 8317 and 2455.
7. **Underlay:** the defined.net host page lists only `eno1`/`ens1f0np0` addresses.
8. **Boot order:** stop `nebula`, recreate `cliproxyapi`; it starts and passes step 1; start `nebula` again and step 3 passes. (codex-lb is not recreated for this test, to avoid its five-minute warm-up; it uses the same mechanism.)
9. **Clients:** one short `claude -p` round-trip through CPA, and one `/v1/responses` call through codex-lb, from the workstation over the overlay; each dashboard shows it under that machine's key.

## 8. Rollback

Remove the `ports:` entries and redeploy `cliproxyapi` and `codex-lb`; stop the `nebula` stack; delete the host in defined.net. Internal and dashboard paths never depended on it.

## 9. Naming

| Thing | Name |
|---|---|
| Stack, container | `nebula` |
| defined.net host, role | `silverstone` |
| Underlay tag | `docker:host` |
| Access tags | `access:cpa`, `access:codex-lb` |
| Dataset | `spool/apps/config/nebula` |

## 10. Follow-ups (explicitly out of scope)

- A name for the overlay address (`/etc/hosts` on clients, or overlay DNS).
- nod over Nebula (its 2026-11-21 spec defers it).
