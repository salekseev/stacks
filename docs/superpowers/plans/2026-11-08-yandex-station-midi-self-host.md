# Yandex Station Midi Self-Hosted Stand — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Steps marked **[USER SHELL]** must be run by the user (they touch the physical Midi or silverstone).

**Goal:** Customize a **Yandex Station Midi** (`cucumber`) so it runs a self-hosted backend instead of Yandex cloud. Pipeline = **(A)** one-time root ADB via DNS unlock, then **(B)** a persistent **v3rt3p** backend on `silverstone` (with the eMudhra `https-proxy`), with OPNsense (Lanner) Unbound routing the station's Yandex domains — and `ntp.yantp.net` — to `silverstone`.

**Architecture:** Phase 0 firmware gate (factory reset + ADB verification) → Phase 1 lock-in (root markers, OTA disable, SSH) + lite-kit stand (temporary DNS/HTTPS proxy) → Phase 2 v3rt3p stack (persistent, eMudhra trust) + OPNsense routing.

**Tech Stack:** Docker Compose, v3rt3p stack (`https-proxy` eMudhra CA, `quasar-server`, `processor` cloud LLM, `quasistreaming-gigam` ASR, `supertonic-tts` TTS, `postgres`, optional `ntp-server`), `krevetkqqq/lite-kit` (Phase 1), OPNsense Unbound, ADB, SSH/Dropbear.

**Spec:** `docs/superpowers/specs/2026-11-08-yandex-station-midi-self-host-design.md`

**Status:** repo-side steps done on this branch (2026-11-09): contrib files, v3rt3p submodules, `stacks/yandex-station.yaml` (validated). Device, silverstone-host, and OPNsense steps remain gated on Phase 0. Upstream-contract corrections are applied inline (dropbear path, gigam models, processor env names).

**Working branch:** `feature/yandex-station-midi-self-host` (create in Task 0 Step 0).

---

## Environment notes for the implementer

- Repo: `/home/salekseev/src/github.com/salekseev/stacks`.
- **silverstone = `192.168.1.10`** (LAN) — the station reaches it here, **not** the `100.77.121.38` Tailscale address.
- `apps` on silverstone = uid/gid **568**; configs under `/mnt/spool/apps/config/<stack>/`, data under `/mnt/spool/apps/data/<stack>/`.
- ssh to silverstone: `ssh silverstone` (in `known_hosts`); first time may need `-o StrictHostKeyChecking=accept-new`.
- **The Midi's current firmware `0.373.1.16…20261104` is newer than everything the community verified.** Phase 0 determines feasibility; a factory reset is destructive and **cannot revert firmware**.
- **Trust is now expected to just work:** the v3rt3p `https-proxy` uses the **eMudhra intermediate CA**, which the station trusts out of the box — so **no self-generated-CA / firmware trust step is needed**. The residual firmware question (does 0.373 still validate eMudhra?) is confirmed in Phase 0.
- **Ports 80/443 on 192.168.1.10 and udp/123 must be free** — `scrypted`/`hermes`/`plex` may hold 443; NTP is udp/123.
- **Do NOT port-forward `:2222`/`:5555`/`:80/:443`/`udp/123` to the WAN.** Root is passwordless and ADB is unauthenticated.
- The v3rt3p builds come from **remote git URLs**; to keep the stack self-contained, vendor them locally (git submodule under the stack dir) or clone on silverstone — many Docker setups disable remote `build:` contexts.

Placeholder values to fill on the device and record:
- `<MIDI_IP>` — the Midi's LAN IP (from Phase 0).
- `<MIDI_MAC>` — the Midi's MAC (capture before the reset).
- `<OPENAI_BASE_URL>` / `<OPENAI_API_KEY>` / `<OPENAI_MODEL>` — the `processor`'s cloud LLM (OpenRouter/OpenAI/Groq), e.g. `<OPENAI_BASE_URL>=https://openrouter.ai/api/v1`, `<OPENAI_MODEL=nvidia/nemotron-3.5-lightning:free>`.
- `<GIGAAM_DEVICE>` — `cpu` (simplest, no GPU) or `cuda` (offloads ASR; needs NVIDIA driver + Container Toolkit). Default `cpu`.
- `<TTS_VOICE>` — e.g. `F1` (v3rt3p voices: M1–M5 male, F1–F6 female).
- `<lite-kit_platform>` — the firmware folder lite-kit expects for the Midi (likely `cucumber`; confirm from its menu).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `stacks/yandex-station.yaml` | The v3rt3p backend stack: 6 containers, `.env`, model assets, healthchecks | Created — committed in Task 4 |
| build repos vendored (git submodules under `stacks/yandex-station/`) | `https-proxy`, `quasar-server`, `quasistreaming-gigam`, `supertonic-tts`, `processor` | Added in Task 3 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/.env` (host, silverstone) | `POSTGRES_PASSWORD`, LLM `OPENAI_*` — secrets out of YAML | Created in Task 3 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/` (host, silverstone, RO) | supertonic TTS model assets (unzipped); GigaAM ASR models self-download to the data cache — no staging | Staged in Task 3 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/prompts/` (host, silverstone, RO) | `processor` handlebars templates | Staged in Task 3 |
| `/mnt/spool/apps/data/yandex-station/v3rt3p/` (host, silverstone) | Postgres data + GigaAM cache | Created in Task 3 |
| `~/lite-kit/` (host, silverstone) | Phase 1 unlock + OTA-downgrade stand | Created/staged in Task 2, removed in Task 5 |
| OPNsense (Lanner) | Unbound overrides (all proxied domains + ntp.yantp.net) + DHCP reservation + firewall | **[USER SHELL]** in Task 6 |

---

## Task 0 (PHASE 0): Factory reset + validation — **the gating step**

**Do this before anything else.** Whole plan's feasibility depends on what firmware the reset produces. A factory reset wipes `/data` and cannot revert the firmware version.

**Reset (Midi / `cucumber`):**
1. Unplug the power cable.
2. Hold the **rear mute-microphone button** (wiki alt: the center touch button).
3. Plug power back in and keep holding the button.
4. Hold **~7–10 s** until the LED turns **yellow-green** (wiki: until a beep + Alice announces reset).
5. Release; wait 1–2 min for the app-setup prompt.

**Validate — run and record every value. This is the decision gate.**

- [ ] **Step 1: capture the pre-reset MAC and post-reset IP/MAC**

```bash
! ssh silverstone 'sudo arp -an | grep -i <MIDI_MAC>'
```

Expected: record the new IP → `<MIDI_IP>` (it should be `192.168.1.x`, **not** `169.254.x.x`). If it is link-local, DHCP failed — resolve that before proceeding.

- [ ] **Step 2: bring up the Phase 1 stand and check ADB (see Task 2 Step 3 once lite-kit is running). For the gate, use a probe that reflects the reset state:**

```bash
adb connect <MIDI_IP>:5555
adb devices
adb shell id
```

Expected: `adb connect …` succeeds, `adb devices` shows `<MIDI_IP>:5555    device`, and `adb shell id` → `uid=0(root)`.

- [ ] **Step 3: record the firmware the device is actually on now**

```bash
! ssh silverstone 'adb shell getprop ro.build.display.id; adb shell getprop ro.product.cpu.abi'
```

Expected: `ro.build.display.id` is either the downgraded trusted build or (surprisingly) still `0.373` with ADB working. Record as `<FIRMWARE_BUILD>`.

**Decision gate — do NOT proceed until this gate passes:**
- ✅ `uid=0(root)` ⇒ firmware is unlocked → proceed to Task 1. (Confirm eMudhra trust on this build in Phase 5.)
- ✅ ADB failed but `~/lite-kit/log/local.log` shows `[OTA-AUTO] … отдаю манифест прошивки` ⇒ downgrade is happening; wait, re-run Step 2, proceed.
- ⚠️ ADB failed, no downgrade, still `0.373` ⇒ **STOP.** Reset once more to see if it lands on a trusted factory image (factory-6 / factory-9), or take the retail-CA-from-factory route. Do not proceed to Task 3 until Phase 1 root is verified.

---

## Task 1 (PHASE 1): Lock in root — markers, OTA, SSH

**Why now:** the unlock is transient. Without this the next cloud sync tears ADB down (Mini 2 logs `Deactivate adb by quasmodrom config`). **Do this while the site is still pointed at silverstone, before restoring DNS.**

**Files:**
- Create: `contrib/yandex-noupdate.sh` (from Marker284/yandex-station-extended)
- Create: `contrib/bin/dropbear`, `contrib/bin/dropbearkey` (from Marker284/yandex-station-binaries)
- Create: `contrib/etc/init.d/S99zdropbear` (init script for autostart)

- [x] **Step 1: create contrib directory structure**

```bash
mkdir -p /home/salekseev/src/github.com/salekseev/stacks/contrib/bin /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/init.d
```

Expected: directories created.

- [x] **Step 2: fetch & place yandex-noupdate.sh**

Download from `https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/yandex-noupdate.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/yandex-noupdate.sh -o /home/salekseev/src/github.com/salekseev/stacks/contrib/yandex-noupdate.sh
chmod +x /home/salekseev/src/github.com/salekseev/stacks/contrib/yandex-noupdate.sh
```

Expected: file exists and is executable.

- [x] **Step 3: fetch dropbear binaries**

Download from `https://github.com/Marker284/yandex-station-binaries` — verified path is `bin/` (not `arm/`): the shipped `dropbear`/`dropbearkey` are **static 32-bit ARM (armhf/EABI5)** builds, the ones the hackalice ecosystem ships for these stations; Amlogic A5 (Cortex-A55) executes AArch32. Confirm `ro.product.cpu.abi` in Phase 0 Step 3 and verify the binary runs before Task 1 Step 8.

```bash
# Fetch dropbear and dropbearkey (static armhf)
curl -fsSL https://github.com/Marker284/yandex-station-binaries/raw/main/bin/dropbear -o /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbear
curl -fsSL https://github.com/Marker284/yandex-station-binaries/raw/main/bin/dropbearkey -o /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbearkey
chmod +x /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbear /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbearkey
```

Expected: both binaries exist and are executable.

- [x] **Step 4: create S99zdropbear init script**

```bash
cat > /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/init.d/S99zdropbear << 'EOF'
#!/bin/sh
DB=/data/opt/bin/dropbear
HK=/data/opt/etc/dropbear/hk_ed25519
mkdir -p $(dirname "$HK")
[ -f "$HK" ] || "$DB"key -t ed25519 -f "$HK"
exec "$DB" -r "$HK" -p 2222 -B
EOF
chmod +x /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/init.d/S99zdropbear
```

Expected: script exists, is executable, starts Dropbear with empty password.

- [ ] **Step 5: create ADB marker directories**

```bash
! ssh silverstone 'adb connect <MIDI_IP>:5555 >/dev/null && adb shell "mkdir -p /data/quasar /data/opt/bin /data/opt/etc/dropbear /data/opt/etc/init.d"'
```

Expected: all dirs created on device.

- [ ] **Step 6: pin ADB autostart markers (immutable)**

```bash
! ssh silverstone 'adb shell "touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb && chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb"'
```

Expected: markers set and immutable.

- [ ] **Step 7: push and run OTA-disable script**

```bash
! ssh silverstone 'adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/yandex-noupdate.sh /data/opt/yandex-noupdate.sh && adb shell sh /data/opt/yandex-noupdate.sh && adb shell sh /data/opt/yandex-noupdate.sh status'
```

Expected `status` output (3 lines):
```
launch.json : updatesd убран
applier : заглушён
ota key : подменён
```

- [ ] **Step 8: push dropbear binaries**

```bash
! ssh silverstone 'adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbear /data/opt/bin/dropbear && adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbearkey /data/opt/bin/dropbearkey && adb shell chmod +x /data/opt/bin/dropbear /data/opt/bin/dropbearkey'
```

Expected: both files on device, executable.

- [ ] **Step 9: generate Dropbear host key**

```bash
! ssh silverstone 'adb shell /data/opt/bin/dropbearkey -t ed25519 -f /data/opt/etc/dropbear/hk_ed25519'
```

Expected: key file generated (output: `Generating key, this may take a while...` then done).

- [ ] **Step 10: push init script and set up autostart**

```bash
! ssh silverstone 'adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/init.d/S99zdropbear /data/opt/etc/init.d/S99zdropbear && adb shell chmod +x /data/opt/etc/init.d/S99zdropbear && adb shell /data/opt/etc/init.d/S99zdropbear'
```

Expected: Dropbear starts (may log to syslog; `netstat -an | grep 2222` on device should show listening).

- [x] **Step 11: commit the contrib files** (done repo-side 2026-11-09; device push of Steps 7–10 still gated on Phase 0)

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add contrib/
git commit -m "feat(yandex-station): add OTA-disable and Dropbear SSH for Phase 1 unlock

Add yandex-noupdate.sh from Marker284/yandex-station-extended to disable OTA
updates and protect ADB root. Include Dropbear binaries and init script for
SSH access on tcp/2222 with passwordless ed25519 root (LAN-only, firewall-scoped).

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Expected: commit succeeds.

- [ ] **Step 12: verify locked-in state survives reboot**

```bash
! ssh silverstone 'adb shell sh /data/opt/yandex-noupdate.sh status'
adb connect <MIDI_IP>:5555 >/dev/null
adb shell id
ssh -p 2222 root@<MIDI_IP> "id; getprop ro.build.display.id"
```

Expected:
- `status` → 3-of-3 (OTA disabled, markers intact)
- `adb shell id` → `uid=0(root)`
- `ssh` login works, shows `uid=0` + `<FIRMWARE_BUILD>`

---

## Task 2 (PHASE 1): Verify lite-kit is running (already started in Task 0)

**Why:** lite-kit is the temporary stand that serves `/get_sync_info` with `adbd.remoteActivation=true` and — when the installed firmware is newer than a trusted build — the automatic downgrade. Started in Task 0; keep running through Task 1. **Remove before Task 5** (v3rt3p startup). The v3rt3p path does **not** need a self-generated CA, but lite-kit is still required for the root unlock itself.

- [ ] **Step 1: confirm lite-kit is still running**

```bash
! ssh silverstone 'ps aux | grep lite-kit | grep -v grep'
```

Expected: process running (e.g., `python3 server.py` or similar).

- [ ] **Step 2: check lite-kit logs for unlock signals**

```bash
! ssh silverstone 'tail -n 50 ~/lite-kit/log/server.log'
```

Expected to see entries like:
```
>>> [SYNC-REAL→] payload …, adbd: config.system_config.adbd=on, …, top.adbd=on
```
(This confirms the Midi queried the stand and received activation payload.)

- [ ] **Step 3: confirm NTP path (required for v3rt3p reset/use)**

```bash
! ssh silverstone 'drill @127.0.0.1 ntp.yantp.net A || dig +short ntp.yantp.net @127.0.0.1'
```

Expected: resolves to silverstone's IP once the OPNsense override from Task 6 is in place; note this is only fully verifiable after Task 6, but the resolution requirement must be known before the stack is deployed.

---

## Task 3 (PHASE 2): Prepare the v3rt3p stack on silverstone

**Why:** v3rt3p is the persistent backend. It is **six cooperating container builds**, not a single source build. Stage the build repos, model assets, prompts, and `.env` here; compose + deploy in Tasks 4–5.

**Files:**
- Vend: the five `v3rt3p/*` build repos (as git submodules under `stacks/yandex-station/`, or cloned on silverstone). **Done on this branch.**
- Create: `/mnt/spool/apps/config/yandex-station/v3rt3p/` (compose, `.env`, prompts).
- Create: `/mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/` (RO: supertonic TTS model). GigaAM ASR models are **self-downloaded** into the data cache at first run — per the upstream README, do **not** pre-copy legacy GigaAM ONNX/token files into that cache.
- Create: `/mnt/spool/apps/data/yandex-station/v3rt3p/` (Postgres + ASR cache).

- [ ] **Step 1: prepare host config/data directories** (on silverstone)

```bash
! ssh silverstone 'sudo install -d -o 568 -g 568 -m 700 /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets /mnt/spool/apps/config/yandex-station/v3rt3p/prompts /mnt/spool/apps/data/yandex-station/v3rt3p/postgres-data /mnt/spool/apps/data/yandex-station/v3rt3p/gigaam-cache'
```

Expected: directories created with correct ownership (uid/gid 568 = `apps` user).

- [ ] **Step 2: stage model + prompt assets** (download the TTS model zip and the processor prompt templates; no ASR asset staging — see Files note above)

```bash
! ssh silverstone 'cd /mnt/spool/apps/config/yandex-station/v3rt3p && \
wget https://v3rt3p-storage.re146.dev/supertonic-tts-model.zip -O supertonic-tts-assets/model.zip && unzip -o supertonic-tts-assets/model.zip -d supertonic-tts-assets/ && rm -f supertonic-tts-assets/model.zip && \
wget https://raw.githubusercontent.com/v3rt3p/processor/refs/heads/master/prompt.handlebars -O prompts/prompt.handlebars && \
wget https://raw.githubusercontent.com/v3rt3p/processor/refs/heads/master/prompt-state.handlebars -O prompts/prompt-state.handlebars && \
wget https://raw.githubusercontent.com/v3rt3p/processor/refs/heads/master/prompt-functions.handlebars -O prompts/prompt-functions.handlebars'
```

Expected: model assets and prompts staged read-only.

- [x] **Step 3: vend the build repos locally** (so the stack is self-contained, not dependent on remote `build:` URLs) — **done on this branch 2026-11-09**

```bash
! ssh silverstone 'cd /home/salekseev/src/github.com/salekseev/stacks && git submodule add https://github.com/v3rt3p/https-proxy.git stacks/yandex-station/https-proxy && git submodule add https://github.com/v3rt3p/quasar-server.git stacks/yandex-station/quasar-server && git submodule add https://github.com/v3rt3p/quasistreaming-gigam.git stacks/yandex-station/quasistreaming-gigam && git submodule add https://github.com/v3rt3p/supertonic-tts.git stacks/yandex-station/supertonic-tts && git submodule add https://github.com/v3rt3p/processor.git stacks/yandex-station/processor'
```

Expected: submodules cloned under `stacks/yandex-station/`. If submodules are undesirable, clone the same repos on silverstone to a documented path and reference `build.context` locally instead (document the path).

- [ ] **Step 4: write `.env`** (secrets out of YAML; fill placeholders before deploy)

```bash
! ssh silverstone 'cat > /mnt/spool/apps/config/yandex-station/v3rt3p/.env << EOF
POSTGRES_PASSWORD=<POSTGRES_PASSWORD>
OPENAI_BASE_URL=<OPENAI_BASE_URL>
OPENAI_API_KEY=<OPENAI_API_KEY>
OPENAI_MODEL=<OPENAI_MODEL>
GIGAAM_DEVICE=<GIGAAM_DEVICE>
TTS_VOICE=<TTS_VOICE>
TZ=Europe/Moscow
EOF
chmod 600 /mnt/spool/apps/config/yandex-station/v3rt3p/.env'
```

Expected: `.env` present with mode 600; every placeholder filled before Task 5. **Compose does not auto-read this path** — it is passed explicitly with `--env-file` at deploy time (Task 5 Step 3).

- [ ] **Step 5: commit staging** (assets + submodules). Expected: commit succeeds.

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add stacks/yandex-station/  # submodules + asset symlinks (do NOT commit real secrets)
git commit -m "feat(yandex-station): stage v3rt3p build repos and model/prompt assets for the rooted Midi

Vend v3rt3p https-proxy, quasar-server, quasistreaming-gigam, supertonic-tts
and processor as git submodules; stage GigaAM ASR ONNX, supertonic TTS model
and processor prompt templates. .env (secrets) is filled before deploy and
kept out of git.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

> **Do not commit the real `.env`** — only the structure. Fill `<...>` placeholders in Task 5 before deploy.

---

## Task 4 (PHASE 2): Create `stacks/yandex-station.yaml`

**Files:**
- Create: `stacks/yandex-station.yaml` (v3rt3p compose tailored to this repo's conventions)

- [x] **Step 1: write `stacks/yandex-station.yaml`** (done 2026-11-09, with the upstream-contract corrections noted above)

Design (see spec §5.1/§5.2 — build contexts vendored as submodules, host ports bound to `192.168.1.10`, `.env` for secrets). This mirrors the upstream `v3rt3p/v3rt3p.github.io` `docker-compose.yml` (the canonical deployment manifest, verified 2026-11-09) but uses **local** build contexts (submodules) and binds the LAN IP. Env values must be `${VAR:-default}` **compose interpolations, not `<placeholder>` literals**; secrets come from the config-dir `.env` via `--env-file` (Task 5).

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Yandex Station self-hosted backend (v3rt3p). Impersonates Yandex cloud so the
# rooted Midi resolves quasar.yandex.net/.ru, scbh.yandex.net, ntp.yantp.net, etc.
# to silverstone:80/:443 (+ udp/123 NTP). Trust is via the eMudhra intermediate CA
# shipped by https-proxy (station trusts it out of the box). LAN-only exposure:
# OPNsense firewall (Task 6) restricts source to the Midi IP.

services:
  # Public entry: NGINX on :80/:443, eMudhra CA, per-domain certs at runtime.
  https-proxy:
    build:
      context: ./yandex-station/https-proxy
    container_name: v3rt3p-https-proxy
    restart: unless-stopped
    ports:
      - "192.168.1.10:80:80"
      - "192.168.1.10:443:443"
    environment:
      YANDEX_UPSTREAM_URL: http://quasar-server:31115
    depends_on:
      - quasar-server

  # Main "maind" protocol server.
  quasar-server:
    build:
      context: ./yandex-station/quasar-server
    container_name: v3rt3p-quasar-server
    restart: unless-stopped
    environment:
      ALLOW_UPDATES: "true"
      PORT: "31115"
      API_PORT: "31116"
      TTS_OPENAI_BASE_URL: http://supertonic-tts:9150
      TTS_OPENAI_VOICE: "${TTS_VOICE:-F1}"          # supertonic voices: M1–M5, F1–F5
      PROCESSOR_BASIC_URL: http://processor:8080    # base URL; processor appends its route
      STT_GIGAAM_URL: ws://quasistreaming-gigam:8080
      POSTGRES_URL: postgres://quasar:${POSTGRES_PASSWORD:-change-me}@postgres:5432/quasar
    ports:
      - "192.168.1.10:31116:31116"   # external API port for controlling the speakers
    depends_on:
      - postgres
      - processor
      - quasistreaming-gigam
      - supertonic-tts

  postgres:
    image: postgres:17
    container_name: v3rt3p-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: quasar
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-change-me}
      POSTGRES_DB: quasar
    volumes:
      - /mnt/spool/apps/data/yandex-station/v3rt3p/postgres-data:/var/lib/postgresql/data

  # ASR: GigaAM. Default CPU; GIGAAM_DEVICE=cuda for GPU (needs NVIDIA + Container
  # Toolkit). Models self-download into the mounted cache on first run — do NOT
  # pre-copy legacy ONNX files (upstream README).
  quasistreaming-gigam:
    build:
      context: ./yandex-station/quasistreaming-gigam
      dockerfile: "${GIGAAM_DOCKERFILE:-Dockerfile.cpu}"
    container_name: v3rt3p-gigam
    restart: unless-stopped
    environment:
      GIGAAM_DEVICE: "${GIGAAM_DEVICE:-cpu}"  # cpu | cuda
      GIGAAM_DOWNLOAD_ROOT: /app/.cache/gigaam
    volumes:
      - /mnt/spool/apps/data/yandex-station/v3rt3p/gigaam-cache:/app/.cache/gigaam

  # TTS: self-hosted OpenAI-compatible service (model assets mounted RO).
  supertonic-tts:
    build:
      context: ./yandex-station/supertonic-tts
    container_name: v3rt3p-tts
    restart: unless-stopped
    environment:
      ASSETS_PATH: /assets
    volumes:
      - /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets:/assets:ro

  # Brain: builds prompts, calls the cloud OpenAI-compatible LLM.
  processor:
    build:
      context: ./yandex-station/processor
    container_name: v3rt3p-processor
    restart: unless-stopped
    environment:
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_MODEL: ${OPENAI_MODEL}
      PROMPT_TEMPLATE_PATH: /prompt.handlebars
      STATE_PROMPT_TEMPLATE_PATH: /prompt-state.handlebars
      FUNCTIONS_PROMPT_TEMPLATE_PATH: /prompt-functions.handlebars
      CACHE_SIZE: "1000"
    volumes:
      - /mnt/spool/apps/config/yandex-station/v3rt3p/prompts/prompt.handlebars:/prompt.handlebars:ro
      - /mnt/spool/apps/config/yandex-station/v3rt3p/prompts/prompt-state.handlebars:/prompt-state.handlebars:ro
      - /mnt/spool/apps/config/yandex-station/v3rt3p/prompts/prompt-functions.handlebars:/prompt-functions.handlebars:ro

  # Optional but required for reset: NTP server (public image).
  ntp-server:
    image: cturra/ntp:latest
    container_name: v3rt3p-ntp
    restart: unless-stopped
    ports:
      - "192.168.1.10:123:123/udp"
    environment:
      NTP_SERVERS: time1.google.com,time2.google.com,time.cloudflare.com

  # Healthchecks omitted by default (upstream images ship no proven probes); add
  # per service once a readiness signal is evidenced. The real trust check is TLS
  # to https://quasar.yandex.net on :443.
```

- [x] **Step 2: validate statically** (done 2026-11-09: `Validation successful`; only warning is unset `OPENAI_MODEL`, expected without the env file)

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
./scripts/validate-stack.sh yandex-station
```

Expected: `Validation successful for stacks/yandex-station.yaml`. If `docker-compose` (v1) is missing, run `docker compose -f stacks/yandex-station.yaml config > /dev/null && echo OK`.

- [x] **Step 3: commit** (done 2026-11-09, commit below on this branch)

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add stacks/yandex-station.yaml
git commit -m "feat(yandex-station): self-hosted v3rt3p backend for the rooted Midi

V3rt3p stack (https-proxy eMudhra CA, quasar-server, processor cloud LLM,
quasistreaming-gigam ASR, supertonic-tts, postgres, optional ntp-server).
https-proxy terminates quasar.yandex.net/.ru, scbh.yandex.net, ntp.yantp.net,
etc. at silverstone:80/:443; the station trusts it via the eMudhra CA, so no
firmware CA step is needed. Build contexts are vendored as submodules; host
ports bound to 192.168.1.10 (matches plex.yaml/scrypted.yaml) so the LAN
station can reach it; OPNsense firewall (Task 6) scopes :80/:443/udp/123 to
the Midi IP.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Expected: commit succeeds.

---

## Task 5 (PHASE 2): Stop lite-kit and deploy v3rt3p

**Why:** lite-kit and the v3rt3p `https-proxy` both need `:80/:443`. lite-kit is temporary (unlock only); v3rt3p is permanent. Stop lite-kit before starting it.

**Files:**
- Deploy: `stacks/yandex-station.yaml` on silverstone

- [ ] **Step 1: stop lite-kit**

```bash
! ssh silverstone 'cd ~/lite-kit && sudo ./stop.sh'
```

Expected: lite-kit stopped (ports 53/80/443 freed).

- [ ] **Step 2: verify ports are free**

```bash
! ssh silverstone 'sudo netstat -tlnp | grep -E ":(80|443)" || echo "Ports free"'
```

Expected: no processes on 80/443, or "Ports free" message.

- [ ] **Step 3: deploy the v3rt3p stack** (first run builds 6 images — allow 5–15 min)

```bash
! ssh silverstone 'cd /home/salekseev/src/github.com/salekseev/stacks && docker compose -f stacks/yandex-station.yaml --env-file /mnt/spool/apps/config/yandex-station/v3rt3p/.env up -d --build'
```

Expected: containers build and start.

- [ ] **Step 4: verify stack is up**

```bash
! ssh silverstone 'docker compose -f stacks/yandex-station.yaml ps'
```

Expected: `v3rt3p-https-proxy` Up and healthy on `192.168.1.10:80/:443`.

- [ ] **Step 5: confirm eMudhra trust (Phase 2 trust is now "just works")**

```bash
! ssh silverstone 'openssl s_client -connect 192.168.1.10:443 -servername quasar.yandex.net </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject'
```

Expected: issuer is the **eMudhra/emSign intermediate CA** for `quasar.yandex.net` (not a self-generated CA). This is the decisive test that the Nov-4 build's trust path works.

- [ ] **Step 6: end-to-end (requires Task 6 DNS + NTP)**

```bash
! ssh silverstone 'docker logs v3rt3p-quasar-server | tail -20'
```

Expected: once the Midi is re-pointed (Task 6), see `/register` and `/token` as the station connects.

---

## Task 6 (PHASE 2 + OPNsense): Wire the DNS routing

**Why:** the Midi must resolve `quasar.yandex.net` etc. (and `ntp.yantp.net`) to silverstone for impersonation to work. OPNsense Unbound + DHCP reservation + firewall scoping.

**[USER SHELL]** — All steps require OPNsense UI or console access (Lanner mini-PC).

- [ ] **Step 1: add Unbound host overrides [USER SHELL]** — Services → Unbound DNS → Overrides → **+**, `Type = A`, `IP = 192.168.1.10`. Full list below — verified 2026-11-09 against the vendored `stacks/yandex-station/https-proxy/domains/yandex.txt` (its first line `quasar:31120` is the proxy's internal upstream marker, not a DNS entry; lines prefixed `!` in that file — `*.s3.yandex.net`, `*.svc.cdn.yandex.net`, `*.strm.yandex.net` — are proxy **exclusions** and must **not** be overridden):

| FQDN (A record → `192.168.1.10`) |
|---|
| `quasar.yandex.net` |
| `quasar.yandex.ru` |
| `scbh.yandex.net` |
| `ntp.yantp.net` |
| `rpc.alice.yandex.net` |
| `uniproxy.alice.yandex.net` |
| `uniproxy-quic.alice.yandex.net` |
| `login.yandex.ru` |
| `oauth.yandex.ru` |
| `push.yandex.ru` |
| `clck.yandex.net` |
| `mobileproxy.passport.yandex.net` |
| `mobileproxy.yango.com` |
| `login.yasmina.yango.com` |
| `oauth.yasmina.yango.com` |
| `push.yasmina.yango.com` |
| `quasar.yasmina.yango.com` |
| `rpc.yasmina.yango.com` |
| `login.yasmina.funtechservices.com` |
| `oauth.yasmina.funtechservices.com` |
| `quasar.yasmina.funtechservices.com` |
| `clck.yasmina.yango.com` |
| `report.appmetrica.yandex.net` |
| `tracking.appmetrica.yandex.net` |
| `rosenberg.appmetrica.yandex.net` |
| `zen.report.appmetrica.yandex.net` |
| `redirect.appmetrica.yandex.com` |
| `startup.appmetrica.yango.com` |
| `startup.mobile.yandex.net` |
| `analytics.mobile.yandex.net` |
| `certificate.mobile.yandex.net` |
| `api.lbs.yandex.net` |
| `ws.api.music.yandex.net` |

Apply, then verify:

```bash
! ssh silverstone 'configctl unbound check && drill @127.0.0.1 quasar.yandex.net A && drill @127.0.0.1 ntp.yantp.net A'
```

Expected: all queries return `192.168.1.10` (A-only, no AAAA). (If an override drops silently, add the base domain to Private Domains.)

- [ ] **Step 2: DHCP reservation for the Midi (OPNsense UI)** — **Services → DHCPv4 → [Interface_LAN] → Reservations → +**: MAC `<MIDI_MAC>`, IP `<MIDI_IP>`, hostname `yandex-midi` (optional), **Set DNS servers = checked, OPNsense LAN IP**. Save, apply. Scope it to the Midi only, not network-wide.

- [ ] **Step 3: firewall rule — restrict `:80/:443/udp/123` source to `<MIDI_IP>`** (best practice; keeps the impersonation backend + NTP off other LAN hosts). **Firewall → Rules → LAN → +**: Pass / in / LAN / Source `<MIDI_IP>` / Destination `192.168.1.10` / Destination port `80,443,123/udp`, inserted above the default `Pass LAN to any` rule. Keep the default LAN→LAN allow intact.

- [ ] **Step 4: end-to-end — reset the Midi via the app and ask it a question**

On the Midi's app or via voice ("Алиса, …"), ask a simple question. Expected: v3rt3p ASR (gigam) → LLM (processor) → TTS (supertonic); the station connects and `/register`/`/token` appear in `quasar-server` logs. Verify ADB still responds:

```bash
adb shell id
```

Expected: `uid=0(root)` (Phase 1 lock-in survived).

---

## Task 7: Post-deploy cleanup & recording

- [ ] **Step 1: record the verified layout** — `<MIDI_IP>`, firmware `<FIRMWARE_BUILD>`, `<GIGAAM_DEVICE>`, `<TTS_VOICE>`, the exact Unbound overrides (all proxied domains + `ntp.yantp.net`), and the firewall rule, into a notes file under `/mnt/spool/apps/config/yandex-station/`.

- [ ] **Step 2: optional SSH hardening** — add `/root/.ssh/authorized_keys` on the Midi and drop the Dropbear `-B` flag so root login is key-only (see spec §5.6).

- [ ] **Step 3: note the remaining follow-ups** from the spec (§10): GigaAM on CUDA, `processor` function/state/MCP servers and home-functions, full cloud detach (Tier 2).

---

## Rollback

- **OPNsense:** delete the Unbound overrides (all proxied domains + `ntp.yantp.net`) + DHCP reservation; restore DNS. Non-destructive.
- **silverstone:** `docker compose -f stacks/yandex-station.yaml down` (keep the branch to revert). Stop lite-kit.
- **Midi:** a factory reset wipes `/data` and cannot revert firmware. If a build cannot be brought under control, the reset path is the only documented escape and is irreversible at the firmware layer.
- **Leak:** never publish `/data/quasar/devices.json`, device keys, MAC, serial, or Wi-Fi password.
