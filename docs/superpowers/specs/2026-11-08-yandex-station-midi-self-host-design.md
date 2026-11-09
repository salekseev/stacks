# Yandex Station Midi self-hosted stand — Design Spec

- **Date:** 2026-11-08
- **Status:** Revised 2026-11-09. Backend selected as the **v3rt3p** stack (with the eMudhra `https-proxy`); the Phase-0 firmware gate and Phase-1 root unlock are unchanged and remain the load-bearing feasibility gate. The old approval marker did not establish firmware feasibility or approve this revision; no device or infrastructure change is authorized by updating this document.
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
| **v3rt3p stack** (selected) | 6-container Compose: `https-proxy` (eMudhra CA) + `quasar-server` + `processor` (LLM) + `quasistreaming-gigam` (ASR) + `supertonic-tts` (TTS) + `postgres` (+ optional `ntp-server`) | Multi-container; supplied container builds and **no mandatory GPU**; its stock `https-proxy` uses the **compromised eMudhra CA, which the station trusts out of the box** — this removes the firmware-dependent self-generated-CA step | More services/state to maintain; needs model assets (ONNX + TTS zip), prompts, Postgres, and NTP; the stock compromised-CA proxy is a deliberate security tradeoff (see §5.5/§11) |
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
| silverstone GPU | 4 GB → **GigaAM ASR** (CPU by default; optional CUDA) + **cloud LLM via `processor`** + **local supertonic TTS** |
| Router | OPNsense on a Lanner mini-PC (standard OPNsense) |
| Isolation tier | **Tier 1** — redirect the core activation domains; the rest of internet stays open (see §6 for the v3rt3p domain set) |

The Midi's own compute is irrelevant to the backend: the v3rt3p stack runs on silverstone's 4 GB, not on the speaker.

---

## 3. Current state (researched, not locally verified)

The customization is documented by independent community sources, cross-referenced:

- **`v3rt3p/v3rt3p.github.io`** + sibling repos — the **selected** self-hosted voice-assistant stack. `docker-compose.yml` wires six container builds: `https-proxy` (from `v3rt3p/https-proxy`), `quasar-server` (`v3rt3p/quasar-server`), `quasistreaming-gigam` (`v3rt3p/quasistreaming-gigam`), `supertonic-tts` (`v3rt3p/supertonic-tts`), `processor` (`v3rt3p/processor`), and the base image `postgres:17`, plus the public `cturra/ntp`. GPL-3.0. The docs (`en/`) describe a CPU-first "getting-started" compose and a GPU path.
- **`v3rt3p/https-proxy`** — the HTTPS reverse proxy. NGINX on `:80`/`:443` with the **eMudhra intermediate CA**, generating per-domain **P-384 EC** certs at runtime from `domains/yandex.txt`, forwarding to a configurable upstream (`YANDEX_UPSTREAM_URL`), and passing anything else straight through. Build patches Nginx for optional TLS key-logging (disabled by default). The project **deliberately ships no eMudhra key of its own** — the station is expected to already trust it (see §5.5).
- **`Marker284/yandex-station-extended`** (`hackalice.me`) — the wiki. Documents the **DNS-unlock** method, the **SSH/OTA-disable** follow-up, device dossiers, and self-hosted **recipe** pages (`recipes/quasard`, `recipes/v3rt3p`). CC-BY-4.0.
- **`krevetkqqq/lite-kit`** (MIT) — the "own update server" stand that yields root ADB (unchanged from the earlier design; see §5.3).
- **`amirilivice/quasard`** (superseded baseline) — the earlier self-hosted backend, kept here only for traceability.

**Source note:** the v3rt3p builds use Compose `build:` from **remote git URLs** (`https://github.com/v3rt3p/<repo>.git`). That works with modern Docker BuildKit but is frequently disabled by policy; the stack must vend the build repos locally (git submodule or clone on silverstone) to stay a self-contained, offline-usable stack (see §5.1/§5.2).

### 3.1 Firmware risk (re-estimated after the trust change)

| Build | Date | Trust status (eMudhra CA) |
|---|---|---|
| `0.369.1.46…20261013` | Oct 13 | ✅ trusted (verified on Midi) |
| `0.369.1.50…20261021` | Oct 21 | ✅ trusted |
| **`0.373.1.16…20261104`** (**the user's build**) | **Nov 4** | ✅ **expected to trust** eMudhra (a vendor/partner CA pre-bundled in the device; this is what the whole v3rt3p path relies on). **Not yet locally verified.** |

Two consequences:

1. **The trust step is no longer the load-bearing unknown.** The older quasard design depended on a self-generated CA being rooted into the station's trust store via a firmware-dependent exploit — and the Nov-4 build was shown to reject self-signed servers. v3rt3p sidesteps that entirely: the station trusts the `https-proxy` because the eMudhra CA is **already in the device**, so there is no new firmware trust step. The residual firmware question is narrow: *does 0.373 still validate the eMudhra CA?* — which is very likely but must be confirmed in Phase 0.
2. **Phase 0 is still required.** The root unlock (Phase 1) and the reset/downgrade gate are unchanged. A new Phase-0-adjacent requirement is that **NTP works**: the station cannot be reset or properly used unless `ntp.yantp.net` resolves to silverstone (§6).

---

## 4. Architecture

```
Yandex Station Midi (192.168.1.<MIDI>)
  │ HTTPS (:443) to quasar.yandex.net … scbh.yandex.net … (the https-proxy domain set)
  │ NTP (:123/udp) to ntp.yantp.net  (required to reset / keep clock)
  ▼
 OPNsense / Unbound host-overrides  ──►  192.168.1.10 :80 / :443  (+ ntp.yantp.net → :123/udp)
  │
  ├── Phase 1  lite-kit stand (TEMPORARY)  :53 / :80 / :443
  │      /get_sync_info → adbd.remoteActivation=true  →  speaker opens tcp/5555
  │      /check_updates → auto-serve downgrade to a trusted build
  │      (stopped before v3rt3p starts — handoff on :80/:443)
  │
  └── Phase 2  v3rt3p stack (PERSISTENT)  :80 / :443 on https-proxy
        https-proxy (eMudhra CA)
          → quasar-server (:31115) ──► processor (cloud OpenAI-compatible LLM)
          → quasistreaming-gigam (ASR, GigaAM)          · postgres (state)
          → supertonic-tts (TTS)                         · ntp-server (optional)
```

**Phase separation is a handoff, not concurrency.** lite-kit binds `:53/:80/:443`; the v3rt3p `https-proxy` needs `:80/:443`. lite-kit runs only during the unlock + downgrade; it is **stopped before v3rt3p starts**, so the two never contend for ports. OPNsense owns DNS permanently; silverstone's `:53` is not needed long-term. The v3rt3p stack also needs `udp/123` for its optional NTP server.

---

## 5. Repo-change design & convention compliance

### 5.1 Stack file & repository conventions

New stack at `stacks/yandex-station.yaml`, following `stacks/hindsight.yaml` / `stacks/media.yaml` shape (multi-service, persistent DB, secrets out of YAML):

- `# $schema:` header (compose-spec) as the repository requires.
- **Build sources vendored locally.** The v3rt3p images are built from six remote git repos. To keep the stack self-contained and offline-usable (the repo's model), **vendor them as git submodules** under the stack directory (or clone them on silverstone to a documented path and reference `build.context: <path>`), rather than depending on remote `build:` URLs at deploy time. The `postgres` and `ntp` images pull from registry normally.
- Config/data on the standard layout:
  - `/mnt/spool/apps/config/yandex-station/v3rt3p/` — the compose file, `.env`, `domains/yandex.txt`, prompt templates, and generated cert material.
  - `/mnt/spool/apps/data/yandex-station/v3rt3p/` — Postgres data + GigaAM model cache.
  - `/mnt/spool/apps/config/yandex-station/models/` — **read-only** ASR (ONNX) and TTS (model zip) assets.
- Secrets **out of YAML** — `POSTGRES_PASSWORD`, the LLM `OPENAI_API_KEY` sourced from host files, not embedded.
- Run unprivileged where the image allows.

### 5.2 Intentional deviation: a LAN-facing backend (host/network ports)

The repository's default exposure model publishes **no host ports** and routes everything through a `cloudflared` tunnel. **This stack deliberately departs** because the *speaker* lives on the **LAN** and must reach `silverstone` on `:80/:443` (+ `udp/123` for NTP) — a tunnel cannot serve a device that never leaves the home network. Two mitigations make this acceptable:

1. **Established precedent:** `stacks/plex.yaml` and `stacks/scrypted.yaml` already use `network_mode: host` for LAN-reachable edge services. The stack follows that, not a novel pattern. (Either `network_mode: host` or `ports:` bound to `192.168.1.10` is acceptable; the `https-proxy` must bind the **LAN IP**, not loopback, and never the Tailscale address.)
2. **Source-scoped firewall** (see §5.6): `:80/:443` are reachable from the LAN but *only the Midi's IP is authorized to use the impersonation backend*, so the exposure surface is the device, not the whole subnet.

### 5.3 lite-kit as the Phase 1 stand (temporary)

`krevetkqqq/lite-kit` is **not** a Compose service in this repo's sense — it is a host-stand run on silverstone during the unlock. It is recorded here because it is a runtime prerequisite and it shares ports with Phase 2. It provides:

- `/get_sync_info` with `adbd.remoteActivation=true` in every config branch;
- automatic downgrade via `/check_updates` when the installed firmware is newer than the served build;
- logs (`log/local.log`, `log/server.log`) proving the unlock path.

It is **removed/stopped** before v3rt3p takes over `:80/:443`.

### 5.4 v3rt3p as the Phase 2 backend

Six cooperating services (from the v3rt3p docs), one job each:

- **`https-proxy`** — public entry: NGINX on `:80`/`:443` using the eMudhra CA, per-domain certs generated at runtime, forwards Yandex domains to `quasar-server:31115`, passes everything else through.
- **`quasar-server`** — the "maind" protocol server; receives device HTTPS-terminated traffic, handles activation/sync/dialogue, talks to ASR/TTS/processor/Postgres. Exposes an internal control `API_PORT:31116`.
- **`processor`** — the brain: builds prompts and calls the configured **OpenAI-compatible cloud LLM** (`OPENAI_BASE_URL`/`OPENAI_API_KEY`/`OPENAI_MODEL`, e.g. OpenRouter/OpenAI/Groq); can call function/state/MCP servers.
- **`quasistreaming-gigam`** — ASR: streaming Russian transcripts via Sber **GigaAM** (ONNX), CPU by default or CUDA; VAD-tunable.
- **`supertonic-tts`** — TTS: a self-hosted OpenAI-compatible speech service (voice `M1`–`M5`/`F1`–`F6`), model assets mounted read-only.
- **`postgres`** — persistent speaker/state DB; **`ntp-server`** (`cturra/ntp`, public image) optional but required for reset.

**VRAM budget on the 4 GB box:** the LLM is cloud (off-device) and TTS is low-VRAM, so the GPU is free; GigaAM ASR can run on **CPU** (simplest, zero GPU) or on **CUDA** if the user wants to offload it. This differs from the superseded quasard plan, which used cloud Edge TTS and local only-ASR; v3rt3p self-hostes TTS too, so the TTS model assets and prompt templates must be staged.

### 5.5 Trust path — eMudhra CA (now solved by design, not firmware)

Two trust mechanisms, one per phase:

- **Phase 1:** lite-kit serves a cert; if the station rejects it, lite-kit's downgrade lands the speaker on a trusted build. (Separate from, and earlier than, the backend trust.)
- **Phase 2 (now the easy one):** the v3rt3p `https-proxy` terminates the station's HTTPS with a certificate signed by the **eMudhra/emSign intermediate CA**, generating P-384 EC certs per domain at runtime. The station **already trusts this CA** because it is a vendor/partner CA pre-bundled in the device — so impersonation works **without installing any certificate** and **without the firmware-dependent root exploit** the old quasard path needed. This is the decisive reason v3rt3p is the lower-risk backend on the Nov-4 build.

  **Tradeoff (owner chose this knowingly):** the eMudhra/emSign intermediate CA is **broken by design, not stolen**: the community `ca.key` is a P-384 key whose secret scalar is **all zeros**, and it is key-paired with the bundled trusted `ca.crt` (verified locally 2026-11-09; upstream README: "eMudhra intermediate CA with broken keys"). The private key is therefore public knowledge — anyone can forge certificates for these domains, which is exactly why the CA (a vendor/partner CA pre-bundled in the device) is distrusted globally and why Yandex devices only accept it opportunistically. Consequences for us: the weakness is real and permanent, so exposure must stay LAN-only and source-scoped; but there is **no secrecy to protect** — the key material may be published, mirrored in CI, and baked into public images without leaking anything confidential, and there is nothing to "rotate". The older self-generated-CA route still exists but needs the firmware-dependent root step and is *less* likely to work on 0.373.

### 5.6 Isolation tier & security

- **Domain scope:** the `https-proxy` intercepts every domain in its `domains/yandex.txt` (e.g. `quasar.yandex.net/.ru`, `scbh.yandex.net`, `rpc.alice.yandex.net`, `uniproxy.alice.yandex.net`, `certificate.mobile.yandex.net`, `login`/`oauth.yandex.ru`, `clck.yandex.net`, telemetry/appmetrica hosts, `ws.api.music.yandex.net`) — so Tier 1 here is **broader** than the old minimal three-domain redirect, and telemetry domains that used to leak are now intercepted. Wildcard CDN/music-stream hosts (`*.s3`, `*.svc.cdn`, `*.strm`) are passed through unchanged.
- **Source-scoped firewall:** a LAN-side `allow <MIDI_IP> → 192.168.1.10 ports 80,443,123/udp` rule; keep the default LAN→LAN allow intact.
- **Passwordless SSH is a hazard:** Dropbear starts with `-B` (root has an **empty password**, visible to the whole LAN). Mitigations: a firewall rule restricting `:2222`/`:5555` to trusted sources, and never port-forwarding them. Optional later hardening: `/root/.ssh/authorized_keys` + remove `-B`.
- **Do not expose `:80/:443/:123/udp` to the WAN.** Keep the Midi off any guest/external network.
- **Compromised-CA hygiene (§11):** do not reuse the eMudhra approach for any device outside this one; keep the proxy local; rotate/lock the key-log dir if TLS key-logging is enabled.

---

## 6. Routing via OPNsense (design)

The station resolves its Yandex domains (and NTP) through OPNsense **Unbound** → `silverstone`:

- **Host overrides (A-only), IP `192.168.1.10`** — cover the full `https-proxy` domain set, not just three. The core ones to add are `quasar`/`yandex.net`, `quasar`/`yandex.ru`, `scbh`/`yandex.net`, but **all** names listed in the vendored `domains/yandex.txt` (and `rpc.alice`, `uniproxy.alice`, `certificate.mobile`, etc.) should be redirected so activation and dialogue actually work. A tool to expand `domains/yandex.txt` into per-host A overrides is preferred over hand-typing them.
- **`ntp.yantp.net` → `192.168.1.10` (A-only)** — **required**: the station cannot be reset or kept on time without it, and reset is required before the backend is usable.
- **A-only, no AAAA** — a stray IPv6 record would let the station escape to real Yandex over IPv6.
- **DHCP reservation** for the Midi → DNS server = OPNsense LAN IP. Scope it to the **Midi only**, not a network-wide switch (network-wide redirection can break the setup phone's Yandex requests).
- **NTP:** the `ntp-server` service binds `udp/123` on silverstone; the firewall rule permits it from the Midi.
- **Full detach (Tier 2, optional, future):** also block egress to real Yandex IPs (already largely unnecessary since the proxy passes unknown hosts straight through) — documented as a known limitation of Tier 1 telemetry if any non-proxied Yandex host is still contacted.

---

## 7. Failure modes

| Condition | Behavior | Mitigation |
|---|---|---|
| 0.373 still validates eMudhra CA (expected) | v3rt3p impersonation just works; no trust step to iterate. | Confirm in Phase 0/5; if it fails, fall back to the self-generated-CA path (less likely to work on 0.373). |
| eMudhra CA rejected on 0.373 | The station won't complete activation through the proxy. | Re-run Phase 0 to land a build known to trust eMudhra; accept the older self-generated-CA route (firmware-dependent). |
| NTP (`ntp.yantp.net`) does not resolve | The station cannot be reset or kept on time → backend unusable. | Point `ntp.yantp.net` at silverstone; bring the `ntp-server` container up before/with the stack. |
| Remote `build:` from git URL is blocked | `docker compose build` fails on the six build contexts. | Vendored local submodules + `build.context`; images are also pre-built by CI as public ghcr packages, so deploy pulls instead of builds. |
| No transcript | `quasistreaming-gigam` failed (model download, audio format, CPU/RAM). | Inspect that service; pre-stage ONNX models; check CPU memory if ASR runs on CPU. |
| No answer / no speech | `processor` (LLM URL/key/model) or `supertonic-tts` (assets/voice) misconfigured. | Inspect each service; verify `OPENAI_*` and TTS voice (`M1`–`F6`). |
| lite-kit not stopped before v3rt3p start | `:80/:443` conflict; the stack won't bind. | Stop lite-kit, free the ports, then start (Task 5). |
| ADB torn down by a cloud sync | `Deactivate adb by quasmodrom config` on some builds. | OTA disabled (Phase 1) + `chattr +i` markers; do Phase 1 fully before restoring DNS. |
| 80/443 already in use on 192.168.1.10 | v3rt3p `https-proxy` cannot bind. | Audit before Phase 1; sequence the handoff. |
| Station on a guest/network with client isolation | ADB/DNS/NTP redirects don't reach silverstone. | Keep station + silverstone on the same LAN. |

---

## 8. Verification

1. **Phase 0 — firmware gate [before anything destructive]:** factory-reset the Midi, bring it up, run `adb connect <MIDI_IP>:5555` → `adb shell id` (expect `uid=0`) and `adb shell getprop ro.build.display.id`. ADB up ⇒ firmware is unlocked. Confirm eMudhra trust on the build; ADB down, no downgrade ⇒ **stop** and re-evaluate.
2. **Phase 1 lock-in:** `adb shell sh /data/opt/yandex-noupdate.sh status` shows 3-of-3; a reboot preserves `uid=0`; `ssh -p 2222 root@<MIDI_IP>` works.
3. **Static:** `./scripts/validate-stack.sh yandex-station` (repository validator, run from repo root).
4. **Runtime:** `docker compose -f stacks/yandex-station.yaml up -d`, `ps`, and confirm `https-proxy` listens on `192.168.1.10:80/:443` and the optional `ntp-server` on `udp/123`.
5. **Trust:** `openssl s_client -connect 192.168.1.10:443 -servername quasar.yandex.net` presents an eMudhra-signed cert for the expected domain (not a self-generated one).
6. **End-to-end:** ask the Midi something; v3rt3p should ASR (gigam) → LLM (processor) → TTS (supertonic) back, and `:5555` should still be up.
7. **DNS:** `drill @127.0.0.1 quasar.yandex.net A` and `ntp.yantp.net A` → `192.168.1.10` from OPNsense.

---

## 9. Rollback

- **OPNsense:** delete the Unbound host overrides (all proxied domains + `ntp.yantp.net`) and the DHCP reservation; restore normal DNS. Non-destructive.
- **silverstone:** `docker compose -f stacks/yandex-station.yaml down` (keep the git branch to revert). Stop lite-kit.
- **Midi:** a factory reset wipes `/data` and cannot revert the firmware version. If a build cannot be brought under control, the reset path is the only documented escape and is irreversible at the firmware layer.
- **Leak:** never publish `/data/quasar/devices.json`, device keys, MAC, serial, or Wi-Fi password — these are read from the device once rooted. Also do not leak the vendored `domains/yandex.txt` or the proxy config to untrusted parties.

---

## 10. Follow-ups (explicitly out of scope here)

- GigaAM ASR on **CUDA** (GPU build) to offload CPU — see the v3rt3p `services/quasistreaming-gigam` guide.
- `processor` **function/state/MCP servers** and `services/home-functions` (home automation) — the stack's extension surface.
- Full cloud detach (Tier 2: egress block).
- Optional SSH hardening (key-only, drop `-B`).

---

## 11. Security actions (out of band, not part of the stack change)

- Root opens **passwordless** LAN SSH (`-B`) and an unauthenticated network ADB on `:5555`. Neither may be port-forwarded or placed on an untrusted network. This is accepted by design for a home device; firewall source scoping is the mitigation, not encryption.
- The v3rt3p `https-proxy` **intentionally uses the known-compromised eMudhra/emSign CA**. This is device- and domain-scoped: keep the proxy LAN-only, source-scoped to the Midi, and **do not reuse it on any other device or public host**. TLS key-logging in the proxy is disabled by default; enable it only in authorized test environments and lock/remove the log file.
- The eMudhra tradeoff is a deliberate owner choice made knowingly, overriding the earlier recommendation to use a self-generated CA; it is documented here so a future reader understands both the rationale and the weakness.
