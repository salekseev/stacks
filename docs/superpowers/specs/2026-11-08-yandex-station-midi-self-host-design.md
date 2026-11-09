# Yandex Station Midi self-hosted stand — Design Spec

- **Date:** 2026-11-08
- **Status:** ✅ **APPROVED 2026-11-08** — Design review passed. Ready for implementation planning. Gated on Phase 0 firmware test.
- **Stack file:** `stacks/yandex-station.yaml` (quasard backend)
- **Author:** brainstormed with Claude Code, grounded against `hackalice.me`, `Marker284/yandex-station-extended`, `krevetkqqq/lite-kit`, `amirilivice/quasard`, and the repo's knowledge pages
- **Host facts verified:** silverstone LAN `192.168.1.10`, Midi firmware `0.373…20261104`, 4 GB GPU — user-provided 2026-11-08
- **External protocol facts:** researched from community sources below; **not** locally verified against this user's Midi. Firmware trust behavior is the load-bearing unknown.

---

## 1. Goal & framing

Give a **Yandex Station Midi** (`cucumber`) a self-hosted life so it no longer depends on Yandex cloud, and so the user controls the assistant's "brain" (LLM), voice (TTS), and data (telemetry cut). This is expressed as **two goals in one pipeline**, both in scope, executed in order:

- **(A) Root ADB via DNS unlock** — a one-time network exploit that makes the speaker open a **root ADB listener on `tcp/5555`**, then locks it in (immutable ADB markers, OTA disabled, SSH/Dropbear on `tcp/2222`). This is the mature, well-documented half.
- **(B) Self-hosted backend** — a persistent **quasard** server on `silverstone` that answers the station's activation, sync, dialogue, and music requests, impersonating Yandex cloud. This is the always-on half. It is **❔ not verified** on the Midi and is the part most likely to require iteration.

Not a goal: a custom firmware ROM (there is no flashable lineage-style build for these devices — "quasmodrom" is slang for the post-root launcher state), a local LLM (the 4 GB GPU cannot hold one comfortably), or full cloud isolation out of the box (see §6).

---

## 2. Target facts (confirmed 2026-11-08)

| Item | Value |
|---|---|
| Device | Yandex Station Midi, codename `cucumber` (`amlogic a5`, kernel 5.4, ~1 GB RAM, eMMC, **no GPU** on the speaker) |
| Midi firmware | `0.373.1.16.4829676750.20261104.164` (built **Nov 4 2026**) |
| silverstone LAN IP | `192.168.1.10` (also `silverstone.local` / `100.77.121.38` Tailscale) |
| silverstone GPU | 4 GB → **local GigaAM ASR (~1 GB VRAM)** + **cloud LLM** + **cloud Edge TTS** |
| Router | OPNsense on a Lanner mini-PC (standard OPNsense) |
| Isolation tier | **Tier 1** — redirect only the core activation domains; internet stays open |

The Midi's own compute is irrelevant to quasard: quasard runs on silverstone's 4 GB, not on the speaker.

---

## 3. Current state (researched, not locally verified)

The customization is documented by two independent community sources, cross-referenced:

- **`Marker284/yandex-station-extended`** (`hackalice.me`) — the wiki. Documents the **DNS-unlock** method (`start/root`), the **SSH/OTA-disable** follow-up (`start/ssh`), device dossiers, and the self-hosted **recipe** pages (`recipes/quasard`, `recipes/v3rt3p`, `recipes/bekend-self-hosted`). CC-BY-4.0.
- **`krevetkqqq/lite-kit`** (MIT) — the "own update server" stand that yields root ADB. Python source, **no published image**. Raises DNS + HTTPS and answers `/get_sync_info` with `adbd.remoteActivation=true`; when the installed firmware is newer than a build it can serve, it **auto-downgrades**.
- **`amirilivice/quasard`** (source, no image) — the self-hosted backend. Python 3.12 + `uv` + `torch`. Listens on **`tcp/80` and `tcp/443`**, impersonates the cloud, does local ASR (GigaAM + Silero VAD), streams LLM responses, and can play Yandex Music. The wiki marks its Midi status **❔ not verified**.

**Trust model (the crux of both halves):** the station speaks HTTPS to `quasar.yandex.net`. To impersonate it, silverstone must present a certificate the station **trusts**. Historically this was done with the leaked **eMudhra/emSign CA** key; the sources deliberately do not ship that key (it would compromise TLS for any site). The recommended route is a **self-generated CA installed into the station's trust store** — which requires root and is **firmware-dependent**. lite-kit and quasard both rely on this trust working.

### 3.1 Firmware risk (load-bearing)

The wiki and lite-kit have **only** verified builds up to the **~Oct 20–21 2026** update:

| Build | Date | Trust status |
|---|---|---|
| `0.369.1.46…20261013` | Oct 13 | ✅ trusted (verified on Midi) |
| `0.369.1.50…20261021` | Oct 21 | ✅ trusted |
| **`0.373.1.16…20261104`** (**the user's build**) | **Nov 4** | ❌ rejects self-signed local server (`unknown_ca`, TLS alert 48) |

For post-Oct-21 builds the documented recovery is **factory reset → a factory image the server trusts → automatic downgrade** (proven on Mini 2: `0.372…20261021.302` → reset → server dispenses `.46`). **The one thing not yet established** is whether a factory reset on the **Nov-4 Midi** lands on a factory image lite-kit/quasard will trust. Phase 0 exists to determine this *before* any stack is written.

---

## 4. Architecture

```
Yandex Station Midi (192.168.1.<MIDI>)
   │  DNS: quasar.yandex.net / quasar.yandex.ru / scbh.yandex.net
   ▼
 OPNsense / Unbound host-overrides  ──►  resolves to  192.168.1.10 :80 / :443
   │
   ├── Phase 1  lite-kit stand (TEMPORARY)  :53 / :80 / :443
   │      /get_sync_info → adbd.remoteActivation=true  →  speaker opens tcp/5555
   │      /check_updates → auto-serve downgrade to a trusted build
   │      (stopped once root is locked + quasard is serving)
   │
   └── Phase 2  quasard backend (PERSISTENT)  :80 / :443
          activation + sync + dialogue + music, impersonating Yandex cloud
```

**Phase separation is a handoff, not concurrency.** lite-kit binds `:53/:80/:443`; quasard needs `:80/:443`. lite-kit runs only during the unlock + downgrade; it is **stopped before quasard starts**, so the two never contend for ports. OPNsense owns DNS permanently; silverstone's `:53` (used only by lite-kit during unlock) is not needed long-term.

---

## 5. Repo-change design & convention compliance

### 5.1 Stack file & repository conventions

New stack at `stacks/yandex-station.yaml`, following `stacks/hindsight.yaml` / `stacks/media.yaml` shape:

- `# $schema:` header (compose-spec) as the repository requires.
- Config/data on the standard layout:
  - `/mnt/spool/apps/config/yandex-station/quasard` (quasard `config.toml`, certs)
  - `/mnt/spool/apps/data/yandex-station/quasard` (runtime state)
- Secrets **out of YAML** — API keys sourced from host files, not embedded.
- Run unprivileged where the image allows.

### 5.2 Intentional deviation: a LAN-facing backend (host/network ports)

The repository's default exposure model publishes **no host ports** and routes everything through a `cloudflared` tunnel. **This stack deliberately departs** because the *speaker* lives on the **LAN** and must reach `silverstone` on `:80/:443` — a tunnel cannot serve a device that never leaves the home network. Two mitigations make this acceptable:

1. **Established precedent:** `stacks/plex.yaml` and `stacks/scrypted.yaml` already use `network_mode: host` for LAN-reachable edge services. The stack follows that, not a novel pattern.
2. **Source-scoped firewall** (see §5.6): `:80/:443` are reachable from the LAN but *only the Midi's IP is authorized to use the impersonation backend*, so the exposure surface is the device, not the whole subnet.

Quasard binds to `192.168.1.10` (the LAN IP), never `127.0.0.1` (same-host only) and never the Tailscale address (the speaker is not on the tailnet).

### 5.3 lite-kit as the Phase 1 stand (temporary)

`krevetkqqq/lite-kit` (Python 3.8+, `dnsmasq`/`openssl`/`dnsutils`, MIT) is **not** a Compose service in this repo's sense — it is a host-stand run on silverstone during the unlock. It is recorded here because it is a runtime prerequisite and it shares ports with Phase 2. It provides:

- `/get_sync_info` with `adbd.remoteActivation=true` in every config branch;
- automatic downgrade via `/check_updates` when the installed firmware is newer than the served build;
- logs (`log/local.log`, `log/server.log`) proving the unlock path.

It is **removed/stopped** before quasard takes over `:80/:443`.

### 5.4 quasard as the Phase 2 backend

`amirilivice/quasard` is a **source build** (no published image). The stack builds a `uv` venv on silverstone and runs `alice_server`, configured for the 4 GB budget:

- **ASR:** local GigaAM v3 + Silero VAD (~1 GB VRAM).
- **LLM:** cloud OpenAI-compatible (Groq/OpenAI) via env key — keeps model weights off-device.
- **TTS:** `edge` (cloud, online) as default; `f5` clone (≈3.4 GB VRAM) only if the user wants a voice clone and tolerates the VRAM.
- **Music:** Yandex Music via `yandex-music-api` (online, needs a login token from `tools/music_login.py`).

### 5.5 Trust path (firmware-dependent — the hardest step)

Two trust mechanisms, one per phase:

- **Phase 1:** lite-kit serves a cert; if the station rejects it (`unknown_ca`), lite-kit's downgrade lands the speaker on a trusted build (factory-6 / factory-9 / `.46`) that accepts it.
- **Phase 2:** quasard MITMs HTTPS, so the station must trust quasard's cert too. Per quasard's own `TRAFFIC_CAPTURE.md`, the recommended mechanism is a **self-generated CA installed into the station's trust store** — which **requires root and is firmware-dependent**. This is the step most likely to need iteration on the Nov-4 build and is why quasard is ❔ on the Midi.

### 5.6 Isolation tier & security

- **Tier 1 (minimal):** redirect only `quasar.yandex.net`, `quasar.yandex.ru`, `scbh.yandex.net`. Internet stays open for everything else. Correct starting point for the one-time unlock.
- **Passwordless SSH is a hazard:** Dropbear starts with `-B` (root has an **empty password**, visible to the whole LAN). Mitigations: a firewall rule restricting `:2222`/`:5555` to trusted sources, and never port-forwarding them. Optional later hardening: `/root/.ssh/authorized_keys` + remove `-B`.
- **Do not expose `:80/:443` or `:2222/:5555` to the WAN.** Keep the Midi off any guest/external network.
- **Telemetry is not fully stopped in Tier 1.** `clck.yandex.net` etc. still leak unless extended overrides or full detach (§6) are applied.

---

## 6. Routing via OPNsense (design)

The station resolves its Yandex domains through OPNsense **Unbound** → `silverstone`:

- **Host overrides** (A-only), IP `192.168.1.10`:
  - `quasar` / `yandex.net`
  - `quasar` / `yandex.ru`
  - `scbh` / `yandex.net`
- **A-only, no AAAA** — a stray IPv6 record would let the station escape to real Yandex over IPv6.
- **DHCP reservation** for the Midi → DNS server = OPNsense LAN IP. Scope it to the **Midi only**, not a network-wide switch (network-wide redirection can break the setup phone's Yandex requests).
- **Firewall:** a LAN-side `allow <MIDI_IP> → 192.168.1.10 ports 80,443` rule that drops the rest to those ports on the impersonation backend; keep the default LAN→LAN allow intact so the station can reach silverstone.
- **Full detach (Tier 2, optional, future):** also block egress to real Yandex IPs and **DNAT all UDP/TCP 53 → silverstone**, because the station runs its own `unbound` (127.0.0.1:53) with a hardcoded fallback (`213.180.193.230`) that can bypass the override. Not required for the minimal path; documented as a known limitation of Tier 1.

---

## 7. Failure modes

| Condition | Behavior | Mitigation |
|---|---|---|
| Nov-4 build rejects the stand's cert (`unknown_ca`) | Phase 1 ADB will not open via the plain path; a downgrade is required. | Phase 0 test; lite-kit auto-downgrade to a trusted build. |
| Factory reset does **not** return a trusted factory image | Phase 1 and Phase 2 both stall. | Stop and evaluate the retail-CA-from-factory route; a factory reset is an irreversible firmware action. |
| Quasard cert not trusted on the running build | Station won't complete activation/sync through quasard; it may fall back to real cloud. | Re-apply the trust path; confirm `:5555` ADB (Phase 1) survived. |
| ADB torn down by a cloud sync | `Deactivate adb by quasmodrom config` on some builds. | OTA disabled (Phase 1) + `chattr +i` markers; do Phase 1 fully before restoring DNS. |
| 80/443 already in use on 192.168.1.10 | quasard (or lite-kit) cannot bind. | Audit before Phase 1; sequence the handoff. |
| Station on a guest/network with client isolation | ADB/DNS redirects don't reach silverstone. | Keep station + silverstone on the same LAN. |

---

## 8. Verification

1. **Phase 0 — firmware gate [before anything destructive]:** factory-reset the Midi, bring it up, run `adb connect <MIDI_IP>:5555` → `adb shell id` (expect `uid=0`) and `adb shell getprop ro.build.display.id`. ADB up ⇒ firmware trusts the stand. ADB down, no downgrade ⇒ **stop** and re-evaluate.
2. **Phase 1 lock-in:** `adb shell sh /data/opt/yandex-noupdate.sh status` shows 3-of-3; a reboot preserves `uid=0`; `ssh -p 2222 root@<MIDI_IP>` works.
3. **Static:** `./scripts/validate-stack.sh yandex-station` (repository validator, run from repo root).
4. **Runtime:** `docker compose -f stacks/yandex-station.yaml up -d`, `ps`, and confirm quasard listens on `192.168.1.10:80/:443`.
5. **End-to-end:** ask the Midi something; quasard should ASR → LLM → TTS back, and `:5555` should still be up.
6. **DNS:** `drill @127.0.0.1 quasar.yandex.net A` → `192.168.1.10` from OPNsense.

---

## 9. Rollback

- **OPNsense:** delete the Unbound host overrides and the DHCP reservation; restore normal DNS. Non-destructive.
- **silverstone:** `docker compose -f stacks/yandex-station.yaml down` (keep the git branch to revert). Stop lite-kit.
- **Midi:** a factory reset wipes `/data` and cannot revert the firmware version. If the Nov-4 build cannot be brought under control, the reset path is the only documented escape and is irreversible at the firmware layer.
- **Leak:** never publish `/data/quasar/devices.json`, device keys, MAC, serial, or Wi-Fi password — these are read from the device once rooted.

---

## 10. Follow-ups (explicitly out of scope here)

- Full cloud detach (Tier 2: egress block + 53 DNAT).
- Voice cloning via F5-TTS (`f5` engine) — ~3.4 GB VRAM, optional.
- Zigbee coordinator use of the Midi's Telink chip (a separate internal project; quasard can already recover/pair networks).
- Media/smart-home integration (e.g. the glagol `:1961` LAN control API for Home Assistant).
- Optional SSH hardening (key-only, drop `-B`).

---

## 11. Security actions (out of band, not part of the stack change)

- Root opens **passwordless** LAN SSH (`-B`) and an unauthenticated network ADB on `:5555`. Neither may be port-forwarded or placed on an untrusted network. This is accepted by design for a home device; firewall source scoping is the mitigation, not encryption.
- Do **not** import the leaked eMudhra/emSign CA or any compromised public-CA key into the station's trust store — that would compromise TLS for unrelated sites. Use a self-generated CA on this device only.
