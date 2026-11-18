# Yandex Station Midi self-hosted stand — Design Spec

- **Date:** 2026-11-08
- **Status:** Revised 2026-11-09. Backend selected as the **v3rt3p** stack (with the eMudhra `https-proxy`); the Phase-0 firmware gate and Phase-1 root unlock are unchanged and remain the load-bearing feasibility gate. The procedure below is the corrected sequence: OPNsense forwards the Yandex zones to dnsmasq on silverstone port 1153, one button reset follows while lite-kit is listening on `:80/:443`, then lock-in, then the permanent stack. DNS stays on OPNsense for the whole procedure. This plan does not downgrade firmware and does not factory-reset a second time. The old approval marker did not establish firmware feasibility or approve this revision; no device or infrastructure change is authorized by updating this document.
- **Stack file:** `stacks/yandex-station.yaml` (v3rt3p backend + eMudhra proxy)
- **Author:** brainstormed with Claude Code, grounded against `hackalice.me`, `Marker284/yandex-station-extended`, `krevetkqqq/lite-kit`, the **`v3rt3p`** project set (`v3rt3p.github.io`, `https-proxy`, `quasar-server`, `quasistreaming-gigam`, `supertonic-tts`, `processor`), and the repo's knowledge pages
- **Host facts verified:** silverstone LAN `192.168.1.10`, Midi firmware `0.373…20261104`, 4 GB GPU — user-provided 2026-11-08
- **External protocol facts:** researched from the community sources below; **not** locally verified against this user's Midi. The Phase-0 firmware gate is the load-bearing unknown.

---

## 1. Goal & framing

Give a **Yandex Station Midi** (`cucumber`) a self-hosted life so it no longer depends on Yandex cloud, and so the user controls the assistant's "brain" (LLM), voice (TTS), and data (telemetry cut). This is expressed as **two goals in one pipeline**, both in scope, executed in order:

- **(A) Root ADB via DNS unlock** — a one-time network exploit that makes the speaker open a **root ADB listener on `tcp/5555`**, then locks it in (immutable ADB markers, OTA disabled, SSH/Dropbear on `tcp/2222`). This is the mature, well-documented half.
- **(B) Self-hosted backend** — a persistent **v3rt3p** stack on `silverstone` that impersonates Yandex cloud for the station's activation, sync, dialogue, and audio requests. This is the always-on half.

Not a goal: a custom firmware ROM (there is no flashable lineage-style build for these devices — "quasmodrom" is slang for the post-root launcher state), a fully local LLM (the 4 GB GPU is not meant to hold one; the LLM stays cloud), or full cloud isolation out of the box (see §6).

### 1.1 Backend selection

The owner asked for a comparison; **the v3rt3p Compose stack was selected** as the Phase-2 backend. The earlier quasard source-build baseline is superseded for this project and recorded here only for traceability.

| Backend | What it is | Why v3rt3p was chosen | Residual cost |
|---|---|---|---|
| **v3rt3p stack** (selected) | Compose: `https-proxy` (eMudhra CA) + `quasar-server` + `processor` (LLM) + `quasistreaming-gigam` (ASR) + `supertonic-tts` (TTS) + `postgres`. `ntp.yantp.net` is a Host Override to OPNsense `192.168.99.1` | Multi-container; supplied container builds and **no mandatory GPU**; its stock `https-proxy` uses the **compromised eMudhra CA, which the station trusts out of the box** — this removes the firmware-dependent self-generated-CA step | More services/state to maintain; needs the Supertonic 3 tree from Hugging Face, prompts, Postgres, and the Host Overrides; the stock compromised-CA proxy is a deliberate security tradeoff (see §5.5/§11) |
| quasard source build (superseded) | Single Python app on silverstone (`uv`+`torch`), Yandex Music + cloud Edge TTS; a self-generated CA in the station's trust store | Smaller runtime but a self-generated CA needs a **firmware-dependent root exploit** the Nov-4 build may not accept | Baseline draft only; kept in §3/§11 for traceability |
| Host Python + systemd | Fewer containers, but a second deployment lifecycle outside this repo's stack convention | Not recommended | — |

Technical recommendations here are the agent's calls, not a claimed record of earlier user decisions. The Phase-0 firmware gate decides feasibility for **either** backend; the trust section (§5.5) explains why v3rt3p is the lower-risk trust path on the Nov-4 build.

---

## 2. Target facts (confirmed 2026-11-08)

| Item | Value |
|---|---|
| Device | Yandex Station Midi, codename `cucumber` (`amlogic a5`, kernel 5.4, ~1 GB RAM, eMMC, **no GPU** on the speaker) |
| Midi firmware | `0.373.1.16.4829676750.20261104.164` (built **Nov 4 2026**) |
| silverstone LAN IP | `192.168.1.10` (also `silverstone.local` / `100.77.121.38` Tailscale) |
| OPNsense LAN | `ix2`, `192.168.1.1/24`, also IPv6 `2600:4040:5b42:2501::/64` |
| OPNsense IoT | `opt1`, VLAN 99 on `ix2` (`ix2_vlan99`), `192.168.99.1/24`, IPv6 `2600:4040:5b42:2599::/64` via WAN prefix delegation. Speakers live here. Russian (`192.168.98.0/24`), CCTV, and DMZ do not |
| silverstone GPU | 4 GB → **GigaAM ASR** (CPU by default; optional CUDA) + **codex-lb via `processor`** + **local supertonic TTS** |
| Router | OPNsense on a Lanner mini-PC (standard OPNsense) |
| Isolation tier | **Tier 1** — redirect the core activation domains; the rest of internet stays open (see §6 for the v3rt3p domain set) |

The Midi's own compute is irrelevant to the backend: the v3rt3p stack runs on silverstone's 4 GB, not on the speaker.

---

## 3. Current state (researched, not locally verified)

The customization is documented by independent community sources, cross-referenced:

- **`v3rt3p/v3rt3p.github.io`** + sibling repos — the **selected** self-hosted voice-assistant stack. `docker-compose.yml` wires six container builds: `https-proxy` (from `v3rt3p/https-proxy`), `quasar-server` (`v3rt3p/quasar-server`), `quasistreaming-gigam` (`v3rt3p/quasistreaming-gigam`), `supertonic-tts` (`v3rt3p/supertonic-tts`), `processor` (`v3rt3p/processor`), and the base image `postgres:17`, plus the public `cturra/ntp`. This repo's stack pins stock `postgres:18` on an empty data directory. GPL-3.0. The docs (`en/`) describe a CPU-first "getting-started" compose and a GPU path.
- **`v3rt3p/https-proxy`** — NGINX on `:80`/`:443` with the **eMudhra intermediate CA** (`certs/ca.crt` paired with `certs/ca.key`, scalar 56). It generates per-domain **P-384 EC** certs at runtime from `domains/yandex.txt`. `YANDEX_UPSTREAM_URL` replaces the first-line upstream. Names without a `!` are forwarded to quasar-server. A `!` name is still terminated locally and then proxied to the real origin. TLS key-logging is disabled by default.
- **`Marker284/yandex-station-extended`** (`hackalice.me`) — the wiki. Documents the **DNS-unlock** method, the **SSH/OTA-disable** follow-up, device dossiers, and self-hosted **recipe** pages (`recipes/quasard`, `recipes/v3rt3p`). CC-BY-4.0.
- **`krevetkqqq/lite-kit`** (MIT) — the "own update server" stand that yields root ADB (unchanged from the earlier design; see §5.3).
- **`amirilivice/quasard`** (superseded baseline) — the earlier self-hosted backend, kept here only for traceability.

**Source note:** five of the v3rt3p images are built from git (`https-proxy`, `quasar-server`, `quasistreaming-gigam`, `supertonic-tts`, `processor`). `postgres` and `cturra/ntp` are registry images. Remote Compose `build:` URLs are frequently disabled by policy, so the five git repos are vendored as submodules under `stacks/yandex-station/` (see §5.1).

### 3.1 Firmware risk (re-estimated after the trust change)

| Build | Date | Trust status (eMudhra CA) |
|---|---|---|
| `0.369.1.46…20261013` | Oct 13 | ✅ trusted (verified on Midi) |
| `0.369.1.50…20261021` | Oct 21 | ✅ trusted |
| **`0.373.1.16…20261104`** (**the user's build**) | **Nov 4** | ✅ **expected to trust** eMudhra (a vendor/partner CA pre-bundled in the device; this is what the whole v3rt3p path relies on). **Not yet locally verified.** |

Two consequences:

1. **The trust step is no longer the load-bearing unknown.** The older quasard design depended on a self-generated CA being rooted into the station's trust store via a firmware-dependent exploit — and the Nov-4 build was shown to reject self-signed servers. v3rt3p sidesteps that entirely: the station trusts the `https-proxy` because the eMudhra CA is **already in the device**, so there is no new firmware trust step. The residual firmware question is narrow: *does 0.373 still validate the eMudhra CA?* — which is very likely but must be confirmed in Phase 0.
2. **Phase 0 is still required, and it is an unlock gate.** The root unlock (Phase 1) is unchanged. NTP is required once the station uses the local backend: the Host Override for `ntp.yantp.net` is OPNsense at `192.168.99.1`, which already answers UDP 123. lite-kit's own DNS is not what the speaker queries.

---

## 4. Architecture

```
Yandex Station Midi (and later speakers) on IoT 192.168.99.0/24
  │ DNS to OPNsense 192.168.99.1, for the whole procedure
  │ during unlock: HTTPS to quasar.yandex.net / .ru and scbh.yandex.net
  │ after cutover: HTTPS to the https-proxy domain set, NTP to ntp.yantp.net
  ▼
 OPNsense Query Forwarding
        Yandex zones and the speaker names → 192.168.1.10 port 1153
        every Unbound client gets these answers
 silverstone 192.168.1.10
  │
  ├── dnsmasq on host port 1153 (can stay up through the unlock)
  │      speaker names → 192.168.1.10, other names in those zones recurse
  │
  ├── Phase 1  lite-kit (TEMPORARY)  HTTPS :80/:443
  │      /get_sync_info → adbd.remoteActivation=true  →  speaker opens tcp/5555
  │      firmware/ stays empty and run/no_downgrade is set, so no OTA is served
  │      its host dnsmasq also starts; IoT does not query it
  │      stopped after root is locked in
  │
  └── Phase 2  stacks/yandex-station.yaml (PERSISTENT)
        https-proxy :80/:443 (eMudhra CA)
          → quasar-server (:31115, control API :31116)
          → processor (cloud OpenAI-compatible LLM)
          → quasistreaming-gigam (ASR, GigaAM)   · supertonic-tts
          · postgres
          NTP: ntp.yantp.net → OPNsense 192.168.99.1 (not a container)
```

**Phase separation is a handoff of :80 and :443, not of DNS.** The Host Overrides are in place before the button reset and stay. lite-kit binds `:80/:443` on `SPEAKER_IP` until root is locked in, then it is **stopped before** `docker compose up` of https-proxy. `https-proxy` takes those ports. `ntp.yantp.net` stays on OPNsense `192.168.99.1` through the unlock and the cutover.

---

## 5. Repo-change design & convention compliance

### 5.1 Stack file & repository conventions

New stack at `stacks/yandex-station.yaml`, following `stacks/hindsight.yaml` / `stacks/media.yaml` shape (multi-service, persistent DB, secrets out of YAML):

- `# $schema:` header (compose-spec) as the repository requires.
- **Build sources vendored locally.** Five images are built from git. Vendor them as git submodules under `stacks/yandex-station/` and pin `image:` to each submodule's short SHA. `postgres` and `cturra/ntp` pull from the registry.
- Config/data on the standard layout:
  - The Compose file stays at `stacks/yandex-station.yaml`. It is not copied into the config directory.
  - `domains/yandex.txt` stays inside the `https-proxy` image. Speaker DNS is OPNsense Host Overrides, recorded in `stacks/yandex-station/unbound-host-overrides.csv`. HTTPS names are `192.168.99.10`. `ntp.yantp.net` is `192.168.99.1`. Do not install a Query Forwarding file or an Unbound view.
  - `/mnt/spool/apps/config/yandex-station/v3rt3p/.env` — `POSTGRES_PASSWORD` and `OPENAI_API_KEY` (the codex-lb `yandex` key). Owned by the deploying user, mode `600`. Leave `OPENAI_BASE_URL` and `OPENAI_MODEL` unset so Compose uses `http://codex-lb:2455/v1` and `gpt-6-luna`.
  - `/mnt/spool/apps/config/yandex-station/v3rt3p/prompts/` — the three processor handlebars files from the pinned processor commit.
  - `/mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/` — **read-only** Supertonic 3 tree (`onnx/` and `voice_styles/` at the mount root), from Hugging Face revision `aafc6e32416a594460b32413efc49d7fe4ce6d46`.
  - `/mnt/spool/apps/data/yandex-station/v3rt3p/postgres-data/` and `gigaam-cache/`. GigaAM downloads `v3_e2e_rnnt` into the cache on first start. Do not pre-copy legacy ONNX or token files.
- Secrets **out of YAML** — `POSTGRES_PASSWORD` and `OPENAI_API_KEY` come from `--env-file`. Compose does not auto-read the config-dir `.env`.
- Run unprivileged where the image allows. The pinned GigaAM and Supertonic Dockerfiles have no `USER`, so those processes run as root in the container and can write the cache mounts.

### 5.2 Intentional deviation: a LAN-facing backend (host/network ports)

The repository's default exposure model publishes **no host ports** and routes everything through a `cloudflared` tunnel. **This stack deliberately departs** because the *speaker* lives on IoT and must reach `silverstone` on `:80/:443` and `udp/123`. A tunnel cannot serve that device. DNS stays on OPNsense. This stack publishes dnsmasq on `192.168.1.10` port `1153`, not port `53`. `stacks/plex.yaml` and `stacks/scrypted.yaml` are the existing LAN exceptions, and they use `network_mode: host`. This stack does **not** follow that mode. Host mode would also listen on the Tailscale address `100.77.121.38`. Every published socket is bound to `192.168.1.10` instead: TCP `80`, `443`, `31116`, `1153`, and UDP `123` and `1153`.

### 5.3 lite-kit as the Phase 1 stand (temporary)

`krevetkqqq/lite-kit` is a host stand on silverstone, not a Compose service. Linux `start.sh` starts the distro `dnsmasq` package plus `scripts/equasar_server.py`, listening on `LOCAL_IP` (set to `192.168.1.10`) and on `127.0.0.1`. Its DNS template hijacks only `quasar.yandex.net`, `quasar.yandex.ru`, and `scbh.yandex.net` on port `53`. The speaker does not use that resolver. OPNsense forwards those names to the stack dnsmasq on port `1153`. lite-kit is here for HTTPS: `/get_sync_info` with `adbd.remoteActivation=true`. The unlock log line is in `log/server.log`.

This plan does not downgrade. `firmware/` stays empty, and `run/no_downgrade` is created before `start.sh`. Current `equasar_server.py` auto-serves a zip when one exists for the platform unless that flag file is present. `run/downgrade` only changes the server's banner; it is not the switch this plan uses.

The stand is stopped with `stop.sh` after root is locked in and has survived a reboot. `stop.sh` prints an instruction to put router DNS back on automatic. Ignore that line. IoT DHCP DNS stays on OPNsense.

### 5.4 v3rt3p as the Phase 2 backend

Six cooperating services from the v3rt3p docs. NTP is OPNsense, not a container:

- **`https-proxy`** — NGINX on `:80`/`:443` using the eMudhra CA. Per-domain certs are generated at runtime. `YANDEX_UPSTREAM_URL` replaces the `quasar:31120` directive, and listed names are forwarded to `quasar-server:31115`. A `!` name that arrives at the proxy is still terminated and then proxied to the real origin; this plan keeps those names on public DNS so they never arrive.
- **`quasar-server`** — activation, sync, and dialogue. Device traffic arrives on `31115`. The control API on `31116` is published on `192.168.1.10` and is part of the firewall scope in §5.6.
- **`processor`** — prompts and codex-lb (`http://codex-lb:2455/v1` on the external `shared-services` network, bearer key `yandex`, model `gpt-6-luna`, reasoning effort `low`).
- **`quasistreaming-gigam`** — ASR via Sber GigaAM `v3_e2e_rnnt`, CPU by default. The checkpoint downloads into the mounted cache on first start and needs outbound HTTPS that once.
- **`supertonic-tts`** — local OpenAI-compatible TTS. Voices at the pinned README are `M1`–`M5` and `F1`–`F5`. Assets are the Hugging Face Supertonic 3 tree mounted read-only at `/assets`.
- **`postgres`** — speaker and state DB.
- **`dnsmasq`** — `4km3/dnsmasq:2.90-r3`, published on `192.168.1.10` port `1153`. Speaker names answer `192.168.1.10`. Every other name in a forwarded zone goes to `1.1.1.1` and `1.0.0.1`.
- **NTP** — OPNsense on the IoT gateway `192.168.99.1` (UDP 123, stratum 3). The Host Override for `ntp.yantp.net` names that address. The stack does not run `ntp-server`.

**VRAM budget on the 4 GB box:** the LLM is codex-lb and TTS is local and small, so the GPU stays free unless GigaAM is switched to CUDA. Prompt templates and the Supertonic 3 tree are staged on the host before `up`.

### 5.5 Trust path — eMudhra CA (now solved by design, not firmware)

Two trust mechanisms, one per phase:

- **Phase 1:** lite-kit serves its own eMudhra certificate for the three unlock names. This plan has no downgrade if that certificate is rejected. ADB absent after the app Wi-Fi join is a stop.
- **Phase 2 (now the easy one):** the v3rt3p `https-proxy` terminates the station's HTTPS with a certificate signed by the **eMudhra intermediate CA** (`CN=EM EV TLS CA - G3C`, issued by AAA Certificate Services), generating P-384 EC certs per domain at runtime. The station **already trusts this CA** because it is pre-bundled in the device — so impersonation works **without installing any certificate** and **without the firmware-dependent root exploit** the old quasard path needed. This is the decisive reason v3rt3p is the lower-risk backend on the Nov-4 build.

  **Tradeoff (owner chose this knowingly):** the eMudhra intermediate CA is **broken by design, not stolen**: the community `ca.key` at submodule `b4dc462` matches `ca.crt` and is a P-384 key whose secret scalar is **56** (the scalar is 48 bytes, and the only nonzero byte is `0x38`). The private key is therefore public knowledge — anyone can forge certificates for these domains, which is exactly why the CA is distrusted globally and why Yandex devices only accept it opportunistically. Consequences for us: the weakness is real and permanent, so exposure must stay LAN-only; but there is **no secrecy to protect** — the key material may be published, mirrored in CI, and baked into public images without leaking anything confidential, and there is nothing to "rotate". The older self-generated-CA route still exists but needs the firmware-dependent root step and is *less* likely to work on 0.373.

  **Proxy alternatives considered (2026-11-09).** Evaluated mature OSS options against this contract (SNI-routed TLS terminated with the bundled pre-trusted CA + blind passthrough for everything else + the `http://upstream/$host$request_uri` path-prefix contract quasar-server expects): **proxify** — forward MITM proxy with an auto-generated CA and no custom-CA input; requires client-side CA installation, the exact thing this design avoids — unqualified. **Modlishka** — single-target phishing reverse proxy that rewrites URLs to one proxy domain; breaks the per-domain Host + path-prefix contract — unqualified. **mitmproxy** — technically capable of matching (custom CA via `confdir`, scripted per-SNI routing, `ignore_hosts` for blind passthrough) but replaces a static nginx with a Python MITM engine and diverges from the community recipe that hackalice/v3rt3p troubleshooting assumes — kept as a *development-time* companion for protocol inspection, not a replacement. **VEY/vey-proxy** (G3 successor; Apache-2.0, active, LTS policy) — the closest architectural fit: first-class SNI proxy (blind passthrough), site-group TLS reverse proxy with per-site certs, and `vey-dcgen` signs leaf certs dynamically from your own CA files, covering 3 of 4 contract points; fails the 4th — the site config reference (reviewed in full, v1.15) has address-only upstreams and no path/URI rewrite, and quasar-server provably routes on the `/$host/` path prefix (nginx rewrites Host to the upstream). Adopting VEY would still require a path-prefix shim, i.e. another proxy — not adopted. `https-proxy` stays: ~259 lines of nginx + POSIX sh, vendored pinned, CI-built, trivially forkable; its abandonment risk is already mitigated.

### 5.6 Isolation tier & security

- **Domain scope:** OPNsense Query Forwarding sends `kinopoisk.ru`, `yandex.ru`, `strm.yandex.ru`, `ott.yandex.ru`, `yandex.net`, `yastatic.net`, and each speaker name to dnsmasq on `192.168.1.10` port `1153`. The Host Override for `ntp.yantp.net` is `192.168.99.1`. An `address=` line with only an IPv4 answer leaves AAAA empty for that name. Other names inside the parent zones recurse to `1.1.1.1`. These rows apply to every client of this Unbound. The disabled blank-domain rows and the DNS-over-TLS `.` forward stay.
- **Firewall, for packets that ingress OPNsense.** On LAN, above the default allow: pass `192.168.1.10` to the speaker TCP `2222,5555`; reject other LAN sources to the speaker on those ports. Speaker HTTPS stays on the IoT VLAN (`SPEAKER_IP` TCP `80`, `443`, `31116`). NTP is the speaker talking to OPNsense at `192.168.99.1` UDP `123`, so there is no IoT-to-LAN pass for port `123`. No pass for port `53` to silverstone. No WAN forward of `80`, `443`, `123`, `31116`, `2222`, or `5555`.
- **VLAN 99 crosses the firewall.** silverstone is on untagged LAN. The speaker is on VLAN 99. Packets between them ingress OPNsense, so the rules above see them. Binding to `192.168.1.10` keeps the sockets off the Tailscale address.
- **Passwordless SSH is a hazard:** Dropbear starts with `-B` (root has an **empty password**). Never port-forward `:2222` or `:5555`. Optional later hardening: `/root/.ssh/authorized_keys` and remove `-B`.
- **Do not expose the silverstone ports to the WAN.** Keep the Midi off any guest or external network.
- **Compromised-CA hygiene (§11):** do not reuse the eMudhra approach for any device outside this one; keep the proxy local; lock or remove the key-log dir if TLS key-logging is enabled.

---

## 6. Routing

OPNsense Unbound Host Overrides are server-wide. They are the speaker DNS: HTTPS names answer `192.168.99.10`, and `ntp.yantp.net` answers `192.168.99.1`. The record is `stacks/yandex-station/unbound-host-overrides.csv`. Query Forwarding and an Unbound view are not used. `interface-view` on `ix2_vlan99` took the resolver down.

```
forward-zone:
  name: "quasar.yandex.net"
  forward-addr: 192.168.1.10@1153
```

A longer name wins over `yandex.net` and `yandex.ru`. The same forward applies on IPv4 and IPv6 because every client asks this Unbound. IoT DHCP DNS stays `192.168.99.1`. A reservation on `opt1` may pin the Midi's MAC to a stable address. It does not set a different DNS server.

Order:

1. The Query Forwarding rows point at `192.168.1.10` port `1153`. dnsmasq is listening there. Install the §5.6 passes. `dig @192.168.99.1 quasar.yandex.net A` prints `192.168.1.10` and the AAAA query prints nothing. The same A query from a LAN host also prints `192.168.1.10`.
2. `sudo LOCAL_IP=192.168.1.10 ./start.sh` in `~/lite-kit`. IoT still asks OPNsense. lite-kit's dnsmasq on port `53` is unused by the speaker.
3. Button reset, then the in-app Wi-Fi join onto IoT, while lite-kit is still listening on `:80/:443`. Root ADB is checked only after that join. All `adb` commands run on silverstone, so there is one ADB server.
4. Lock in root (markers, OTA disable, Dropbear) and confirm a reboot still yields `uid=0`.
5. `stop.sh`. Leave the forwarding rows and the IoT DHCP DNS in place.
6. `docker compose up` the stack. https-proxy takes the speaker address the Host Overrides already name.
7. From any host, `dig @192.168.99.1 ntp.yantp.net A` prints `192.168.99.1`.
8. Reboot the Midi. This is a normal reboot, not the button factory reset. `/data` has to survive. Ask it a question and confirm `:5555` still answers `uid=0`.

A second button factory reset wipes `/data` and removes the lock-in. If the local backend cannot be reached without one, stop and treat a new unlock cycle as a deliberate repeat of steps 2–4, with lite-kit listening on `:80/:443` again. The forwarding rows stay. The root-ADB payload comes from lite-kit, so do not factory-reset while only https-proxy is answering those names.

---

## 7. Failure modes

| Condition | Behavior | Mitigation |
|---|---|---|
| 0.373 still validates the eMudhra CA (expected) | Local impersonation works without installing a CA. | Confirm with `openssl s_client` after the stack is up, then with a spoken request. |
| eMudhra CA rejected on 0.373 | Activation through the proxy fails. | Stop. This plan does not downgrade and does not install a replacement CA. |
| No `uid=0` after the app Wi-Fi join | The unlock did not take. | Stop. `firmware/` is empty on purpose, so there is no OTA-AUTO path to wait for. |
| `ntp.yantp.net` still resolves publicly | The Host Override is missing or still names another address. | `dig @192.168.99.1 ntp.yantp.net A` must print `192.168.99.1`. OPNsense on that address already answers UDP 123. |
| First GigaAM start has no egress | The checkpoint never lands in the cache. | Allow outbound HTTPS once, or pre-warm the cache as the gigam README describes. Do not copy legacy ONNX files into it. |
| No transcript | gigam failed (download, audio format, CPU/RAM). | Inspect `v3rt3p-gigam`. |
| No answer / no speech | `processor` cannot reach codex-lb, or Supertonic assets/voice are missing. | `OPENAI_API_KEY` is the codex-lb `yandex` key. `403 model_not_allowed` means `gpt-6-luna` is not on that key. Voice is `M1`–`M5` or `F1`–`F5`. `onnx/` and `voice_styles/` must sit directly under the assets mount. |
| lite-kit still bound to :80/:443 | The stack does not bind. | `stop.sh`, then `up`. |
| A second button reset after lock-in | `/data` is wiped and root is gone. | Reboot only. Repeat the unlock on purpose if a wipe already happened. |
| ADB torn down by a cloud sync | `Deactivate adb by quasmodrom config` on some builds. | Finish the lock-in before stopping lite-kit. |
| Station placed on a guest SSID | It cannot reach silverstone, and it may not use this Unbound. | Join it to IoT. The §5.6 pass is what lets that VLAN reach silverstone. |

---

## 8. Verification

1. **Forwards, before the button reset:** `dig @192.168.1.10 -p 1153 quasar.yandex.net A +short` and `dig @192.168.99.1 quasar.yandex.net A +short` print `192.168.1.10`. The AAAA query prints nothing. A LAN query of the same name also prints `192.168.1.10`.
2. **Unlock:** after the button reset and the in-app Wi-Fi join, on silverstone, `adb connect <MIDI_IP>:5555` and `adb shell id` print `uid=0(root)`. Record `ro.build.display.id` and `ro.product.cpu.abi`. Anything else is a stop.
3. **Lock-in:** `adb shell sh /data/opt/yandex-noupdate.sh status` reports updates removed, the applier stubbed, and the OTA key replaced, and `maind --updatesd` is not running. After a reboot, `uid=0` and `ssh -p 2222 root@<MIDI_IP>` still work.
4. **Static:** from the repo root, `./scripts/validate-stack.sh yandex-station`.
5. **Runtime:** `docker compose -f stacks/yandex-station.yaml --env-file /mnt/spool/apps/config/yandex-station/v3rt3p/.env up -d`, then `ps`. Services report `Up`. This stack defines no healthchecks, so Compose will not say `healthy`. `https-proxy` holds `SPEAKER_IP` on TCP 80 and 443. Nothing in this stack listens on port `53` or UDP `123`. NTP is OPNsense at `192.168.99.1`.
6. **Trust:** `openssl s_client -connect 192.168.1.10:443 -servername quasar.yandex.net` shows a leaf whose issuer is `EM EV TLS CA - G3C`.
7. **DNS after cutover:** `dig @192.168.99.1 quasar.yandex.net A +short` prints `SPEAKER_IP` (`192.168.99.10`). `dig @192.168.99.1 ntp.yantp.net A +short` prints `192.168.99.1`. The AAAA query prints nothing.
8. **End-to-end:** reboot the Midi (not a factory reset), ask it a question, and confirm `adb shell id` is still `uid=0(root)`.

---

## 9. Rollback

- **OPNsense:** delete the Query Forwarding rows that point at `192.168.1.10` port `1153`, and delete the §5.6 passes. Host Overrides were not given Yandex names. IoT DHCP DNS was already OPNsense.
- **silverstone:** `docker compose -f stacks/yandex-station.yaml --env-file /mnt/spool/apps/config/yandex-station/v3rt3p/.env down`. Stop lite-kit if it is still running. Ignore `stop.sh`'s advice to return router DNS to automatic.
- **Midi:** a factory reset wipes `/data` and cannot revert the firmware version. If a build cannot be brought under control, the reset path is the only documented escape and is irreversible at the firmware layer.
- **Leak:** never publish `/data/quasar/devices.json`, device keys, MAC, serial, or Wi-Fi password. The domain list and `ca.key` are already public upstream; the device identity is not.

---


## 10. Follow-ups (explicitly out of scope here)

- GigaAM ASR on **CUDA** (GPU build) to offload CPU — see the v3rt3p `services/quasistreaming-gigam` guide.
- `processor` **function/state/MCP servers** and `services/home-functions` (home automation) — the stack's extension surface.
- Full cloud detach (Tier 2: egress block).
- Optional SSH hardening (key-only, drop `-B`).
- Upstream contributions submitted (2026-11-09): v3rt3p/https-proxy issue #2 + PR #3 — optional sslkeylog Nginx patch at build time via `ARG SSL_KEYLOG` (tested locally: `SSL_KEYLOG=false` builds in ~2 s with a byte-identical distro binary; steady-state deployments then ride distro CVE updates). If merged: bump the submodule pin and the ghcr images retag per the SHA-tag contract. Also v3rt3p/supertonic-tts issue #2 — its `src/supertonic.js` is **byte-identical** (same sha256 `073f028c…`, 559 lines, empty `diff`) to `nodejs/helper.js` from **MIT-licensed** `supertone-oss-archive/supertonic` (Copyright 2025 Supertone Inc.) with the notice stripped: asks for MIT attribution (LICENSE + source header crediting supertone-oss-archive/supertonic). The model weights are a separate matter: HF `supertone-oss-archive/supertonic-3` (the README-pinned revision) is **OpenRAIL**, not MIT — but weights are not baked into any image; the deployer downloads them from HF directly, so OpenRAIL compliance sits with the deployer (home TTS, no impersonation — comfortably in scope).

---

## 11. Security actions (out of band, not part of the stack change)

- Root opens **passwordless** SSH (`-B`) and an unauthenticated network ADB on `:5555`. Neither may be port-forwarded or placed on an untrusted network. OPNsense rules in §5.6 cover traffic from LAN to the speaker and from IoT to silverstone.
- The v3rt3p `https-proxy` **intentionally uses the known-compromised eMudhra/emSign CA**. The Query Forwarding rows send every client of this Unbound to that proxy for the speaker names. **The same proxy is not reused for any public host.** TLS key-logging in the proxy is disabled by default; enable it only in authorized test environments and lock/remove the log file.
- The eMudhra tradeoff is a deliberate owner choice made knowingly, overriding the earlier recommendation to use a self-generated CA; it is documented here so a future reader understands both the rationale and the weakness.
