# Yandex Station Midi Self-Hosted Stand — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Steps marked **[USER SHELL]** must be run by the user (they touch the physical Midi or silverstone).

**Goal:** Customize a **Yandex Station Midi** (`cucumber`) so it runs a self-hosted backend instead of Yandex cloud. Pipeline = **(A)** one-time root ADB via DNS unlock, then **(B)** a persistent **quasard** backend on `silverstone`, with OPNsense (Lanner) Unbound routing the station's Yandex domains to `silverstone`.

**Architecture:** Phase 0 firmware gate (factory reset + ADB verification) → Phase 1 lock-in (root markers, OTA disable, SSH) + lite-kit stand (temporary DNS/HTTPS proxy) → Phase 2 quasard backend (persistent) + OPNsense routing.

**Tech Stack:** Docker Compose, quasard (Python 3.12 + torch), lite-kit (Python 3.8), OPNsense Unbound, ADB, SSH/Dropbear.

**Spec:** `docs/superpowers/specs/2026-11-08-yandex-station-midi-self-host-design.md`

**Working branch:** `feature/yandex-station-midi-self-host` (create in Task 0 Step 0).

---

## Environment notes for the implementer

- Repo: `/home/salekseev/src/github.com/salekseev/stacks`.
- **silverstone = `192.168.1.10`** (LAN) — the station reaches it here, **not** the `100.77.121.38` Tailscale address.
- `apps` on silverstone = uid/gid **568**; configs under `/mnt/spool/apps/config/<stack>/`, data under `/mnt/spool/apps/data/<stack>/`.
- ssh to silverstone: `ssh silverstone` (in `known_hosts`); first time may need `-o StrictHostKeyChecking=accept-new`.
- **The Midi's current firmware `0.373.1.16…20261104` is newer than everything the community verified.** Phase 0 determines feasibility; a factory reset is destructive and **cannot revert firmware**.
- **Ports 80/443 on 192.168.1.10 must be free** — `scrypted`/`hermes`/`plex` may hold 443.
- **Do NOT port-forward `:2222`/`:5555`/`:80/:443` to the WAN.** Root is passwordless and ADB is unauthenticated.

Placeholder values to fill on the device and record:
- `<MIDI_IP>` — the Midi's LAN IP (from Phase 0).
- `<MIDI_MAC>` — the Midi's MAC (capture before the reset).
- `<LMM_BASE_URL>` / `<LMM_API_KEY>` — cloud LLM endpoint + key (Groq/OpenAI).
- `<quasard_platform>` — the firmware folder lite-kit expects for the Midi (likely `cucumber`; confirm from its menu).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `stacks/yandex-station.yaml` | The backend stack: quasard (source build), config, data, healthcheck | Created — committed in Task 4 |
| `/mnt/spool/apps/config/yandex-station/quasard/config.toml` (host, silverstone) | quasard server / ASR / LLM / TTS / music config | Created in Task 3 |
| `/mnt/spool/apps/data/yandex-station/quasard` (host, silverstone) | quasard runtime state | Created in Task 3 |
| `~/lite-kit/` (host, silverstone) | Phase 1 unlock + OTA-downgrade stand | Created/staged in Task 2, removed in Task 5 |
| OPNsense (Lanner) | Unbound host overrides + DHCP reservation + firewall | **[USER SHELL]** in Task 5 |

---

## Task 0 (PHASE 0): Setup + factory reset + validation — **the gating step**

**Do this before anything else.** Whole plan's feasibility depends on what firmware the reset produces. A factory reset wipes `/data` and cannot revert the firmware version.

- [ ] **Step 0: create feature branch**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git checkout -b feature/yandex-station-midi-self-host
```

Expected: branch created and checked out.

- [ ] **Step 1: capture pre-reset Midi MAC address**

From the Midi's web setup UI or DHCP log on OPNsense, find its current MAC. Record as `<MIDI_MAC>` for later reference.

Expected: e.g., `00:1a:2b:3c:4d:5e`

- [ ] **Step 2: factory reset the Midi (physical device)**

**[USER SHELL]** — Run on the device itself:
1. Unplug the power cable.
2. Hold the **rear mute-microphone button** (wiki alt: the center touch button).
3. Plug power back in and keep holding the button.
4. Hold **~7–10 s** until the LED turns **yellow-green** (wiki: until a beep + Alice announces reset).
5. Release; wait 1–2 min for the app-setup prompt.

Expected: device reboots to setup screen.

- [ ] **Step 3: check DHCP — get the Midi's new IP**

```bash
! ssh silverstone 'sudo arp -an | grep -i <MIDI_MAC>'
```

Expected: record the new IP → `<MIDI_IP>` (it should be `192.168.1.x`, **not** `169.254.x.x`). If link-local, DHCP failed — resolve before proceeding.

- [ ] **Step 4: clone lite-kit (prep for Phase 1)**

```bash
! ssh silverstone 'cd ~ && git clone https://github.com/krevetkqqq/lite-kit && cd lite-kit && sudo apt-get update && sudo apt-get install -y dnsmasq python3 openssl dnsutils'
```

Expected: lite-kit cloned, deps installed.

- [ ] **Step 5: start lite-kit**

```bash
! ssh silverstone 'cd ~/lite-kit && sudo ./start.sh'
```

Expected: prints silverstone IP and confirms DNS setup. Leave running.

- [ ] **Step 6: probe ADB connectivity to determine firmware trust**

```bash
adb connect <MIDI_IP>:5555
adb devices
adb shell id
```

Expected: `adb connect …` succeeds, `adb devices` shows `<MIDI_IP>:5555    device`, and `adb shell id` → `uid=0(root)`.

- [ ] **Step 7: check which firmware the device landed on**

```bash
! ssh silverstone 'adb shell getprop ro.build.display.id; adb shell getprop ro.product.cpu.abi'
```

Expected: `ro.build.display.id` is either a downgraded trusted build or (surprisingly) still `0.373` with ADB working. Record as `<FIRMWARE_BUILD>`.

**Decision gate — do NOT proceed until this gate passes:**
- ✅ `uid=0(root)` + firmware is trusted build or Nov-4 with ADB working ⇒ proceed to Task 1.
- ⚠️ ADB failed but `~/lite-kit/log/server.log` shows `[OTA-AUTO] отдаю манифест прошивки` ⇒ downgrade in progress; wait 2 min, re-run Step 6.
- ❌ `uid=0` failed, no downgrade, still `0.373` ⇒ **STOP.** Reset once more or evaluate retail-CA route. Do NOT proceed to Task 1 without verified root ADB.

---

## Task 1 (PHASE 1): Lock in root — markers, OTA, SSH

**Why now:** the unlock is transient. Without this the next cloud sync tears ADB down (Mini 2 logs `Deactivate adb by quasmodrom config`). **Do this while the site is still pointed at silverstone, before restoring DNS.**

**Files:**
- Create: `contrib/yandex-noupdate.sh` (from Marker284/yandex-station-extended)
- Create: `contrib/bin/dropbear`, `contrib/bin/dropbearkey` (from Marker284/yandex-station-binaries)
- Create: `contrib/etc/init.d/S99zdropbear` (init script for autostart)

- [ ] **Step 1: create contrib directory structure**

```bash
mkdir -p /home/salekseev/src/github.com/salekseev/stacks/contrib/bin /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/init.d
```

Expected: directories created.

- [ ] **Step 2: fetch & place yandex-noupdate.sh**

Download from `https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/yandex-noupdate.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/yandex-noupdate.sh -o /home/salekseev/src/github.com/salekseev/stacks/contrib/yandex-noupdate.sh
chmod +x /home/salekseev/src/github.com/salekseev/stacks/contrib/yandex-noupdate.sh
```

Expected: file exists and is executable.

- [ ] **Step 3: fetch dropbear binaries**

Download from `https://github.com/Marker284/yandex-station-binaries` (e.g., `arm64-v8a` for Amlogic A5):

```bash
# Fetch dropbear and dropbearkey for ARM
curl -fsSL https://github.com/Marker284/yandex-station-binaries/raw/main/arm/dropbear -o /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbear
curl -fsSL https://github.com/Marker284/yandex-station-binaries/raw/main/arm/dropbearkey -o /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbearkey
chmod +x /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbear /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbearkey
```

Expected: both binaries exist and are executable.

- [ ] **Step 4: create S99zdropbear init script**

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

- [ ] **Step 11: commit the contrib files**

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

**Why:** lite-kit is the temporary stand that serves `/get_sync_info` with `adbd.remoteActivation=true` and — when the installed firmware is newer than a trusted build — the automatic downgrade. Started in Task 0 Step 5; keep running through Task 1. Remove before Task 4 (quasard startup).

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

---

## Task 3 (PHASE 2): Build quasard config on silverstone

**Why:** quasard is the persistent backend that impersonates the Yandex cloud. **Source build** (no published image). VRAM budget on the 4 GB GPU: local GigaAM ASR + cloud LLM + cloud Edge TTS.

**Files:**
- Create: `/mnt/spool/apps/config/yandex-station/quasard/` (symlink to cloned repo)
- Create: `/mnt/spool/apps/config/yandex-station/quasard/config.toml`
- Create: `/mnt/spool/apps/config/yandex-station/quasard/certs/` (server certs + CA)

- [ ] **Step 1: prepare host config directories** (on silverstone)

```bash
! ssh silverstone 'sudo install -d -o 568 -g 568 -m 700 /mnt/spool/apps/config/yandex-station/quasard /mnt/spool/apps/data/yandex-station/quasard'
```

Expected: directories created with correct ownership (uid/gid 568 = `apps` user).

- [ ] **Step 2: clone quasard repo**

```bash
! ssh silverstone 'cd /mnt/spool/apps/config/yandex-station && git clone https://github.com/amirilivice/quasard quasard'
```

Expected: quasard cloned to `/mnt/spool/apps/config/yandex-station/quasard`.

- [ ] **Step 3: build the `uv` venv** (Python 3.12, torch, ffmpeg)

```bash
! ssh silverstone 'cd /mnt/spool/apps/config/yandex-station/quasard && uv venv -p 3.12 .venv && uv pip install -p .venv torch torchaudio --index-url https://download.pytorch.org/whl/cu128 && uv pip install -p .venv -r requirements.txt'
```

Expected: venv created, torch and deps installed. Takes ~5–10 min.

- [ ] **Step 4: create base config from template**

```bash
! ssh silverstone 'cd /mnt/spool/apps/config/yandex-station/quasard && cp config.example.toml config.toml'
```

Expected: `config.toml` present.

- [ ] **Step 5: edit `config.toml` — server section**

```bash
! ssh silverstone 'cat > /tmp/quasard_server.patch << '\''EOF'\''
[server]
host = "0.0.0.0"
port = 80
port_tls = 443
EOF
'
```

Then manually edit or use sed (caveman: we keep it simple — manual edit via SSH):

```bash
! ssh silverstone 'nano /mnt/spool/apps/config/yandex-station/quasard/config.toml'
```

Edit `[server]` section to:
```toml
[server]
host = "0.0.0.0"
port = 80
port_tls = 443
```

Expected: server listens on all interfaces, ports 80/443.

- [ ] **Step 6: edit `config.toml` — LLM section**

In `[llm]` section, set:
```toml
[llm]
base_url = "<LMM_BASE_URL>"
api_key = "<LMM_API_KEY>"
model = "mixtral-8x7b-32768"  # or similar fast streaming model (e.g., Groq)
```

**Record placeholder values** (fill in before deploy):
- `<LMM_BASE_URL>` — e.g., `https://api.groq.com/openai/v1` (Groq) or `https://api.openai.com/v1` (OpenAI)
- `<LMM_API_KEY>` — your API key

- [ ] **Step 7: edit `config.toml` — TTS section**

In `[tts]` section, set:
```toml
[tts]
engine = "edge"
```

Expected: uses cloud TTS (online, no local VRAM).

- [ ] **Step 8: edit `config.toml` — ASR section**

In `[asr]` section, ensure:
```toml
[asr]
provider = "gigaam"
[asr.gigaam]
model = "v3"  # or latest version
silero_vad = true
```

Expected: local ASR with Silero VAD (~1 GB VRAM).

- [ ] **Step 9: edit `config.toml` — music section (if wanted)**

If Yandex Music streaming is desired, set:
```toml
[music]
enable = true
login_token = "<YANDEX_MUSIC_TOKEN>"
```

Otherwise, leave `enable = false`.

To get token: `./tools/music_login.py` (interactive; requires a Yandex account with Music).

- [ ] **Step 10: create self-signed CA and server certificate** (for HTTPS trust)

```bash
! ssh silverstone 'cd /mnt/spool/apps/config/yandex-station/quasard && mkdir -p certs && \
openssl genrsa -out certs/ca-key.pem 4096 && \
openssl req -new -x509 -days 3650 -key certs/ca-key.pem -out certs/ca.pem \
  -subj "/CN=Quasard-Local-CA" && \
openssl genrsa -out certs/server-key.pem 4096 && \
openssl req -new -key certs/server-key.pem -out certs/server.csr \
  -subj "/CN=quasar.yandex.net" && \
openssl x509 -req -days 3650 -in certs/server.csr \
  -CA certs/ca.pem -CAkey certs/ca-key.pem -CAcreateserial \
  -out certs/server.pem'
```

Expected: CA and server certs generated. Place in quasard config for HTTPS MITM.

- [ ] **Step 11: commit quasard config**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add docs/superpowers/plans/  # if any tracking files added
git commit -m "feat(yandex-station): quasard config — source build, LLM, ASR, TTS

Clone quasard (amirilivice), build uv venv with torch + GigaAM ASR. Config:
- Server: 0.0.0.0:80/:443 (Compose binds to 192.168.1.10)
- LLM: cloud (Groq/OpenAI) for VRAM budget
- TTS: cloud Edge (can switch to F5 clone if VRAM allows)
- ASR: local GigaAM v3 + Silero VAD (~1 GB VRAM)
- HTTPS: self-signed CA (must install on rooted Midi for trust)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Expected: commit succeeds.

---

## Task 4 (PHASE 2): Create `stacks/yandex-station.yaml`

**Files:**
- Create: `stacks/yandex-station.yaml`
- Create: `/mnt/spool/apps/config/yandex-station/quasard/` and `/mnt/spool/apps/data/yandex-station/quasard/` (host, silverstone)

- [ ] **Step 1: create the host dirs on silverstone**

```bash
! ssh silverstone 'sudo install -d -o 568 -g 568 -m 700 /mnt/spool/apps/config/yandex-station/quasard /mnt/spool/apps/data/yandex-station/quasard'
```

- [ ] **Step 2: write `stacks/yandex-station.yaml`**

Design (see spec §5.2 — the `network_mode: host` / `192.168.1.10` deviation is intentional and precedent-backed by `plex.yaml`/`scrypted.yaml`):

```yaml
# $schema: https://raw.githubusercontent.com/compose-spec/compose-spec/refs/heads/main/schema/compose-spec.json
#
# Yandex Station self-hosted backend (quasard). Impersonates Yandex cloud so the
# rooted Midi resolves quasar.yandex.net/.ru + scbh.yandex.net -> silverstone:80/:443.
# LAN-only exposure: OPNsense firewall restricts source to the Midi IP (Task 5).

services:
  quasard:
    image: amirilivice/quasard:latest        # build locally if no published image (source project)
    container_name: yandex-quasard
    restart: unless-stopped
    # Host network OR 0.0.0.0:<LAN_IP>:80,:443 publish. Both domains' TLS certs
    # must be bound on the host-facing IP so the LAN can reach it.
    network_mode: host                        # matches plex.yaml / scrypted.yaml convention
    # If the image binds an internal port instead, use (and drop network_mode):
    #   ports:
    #     - "192.168.1.10:80:80"
    #     - "192.168.1.10:443:443"
    environment:
      - STATION_IP=<MIDI_IP>                  # quasard-side guard: only this device may talk to the backend
      - LLM_API_KEY=<LMM_API_KEY>             # cloud LLM (keeps VRAM off-device)
      # TLS material for quasar.yandex.net etc. lives in config/ (project-supplied)
    volumes:
      - /mnt/spool/apps/config/yandex-station/quasard:/config:ro
      - /mnt/spool/apps/data/yandex-station/quasard:/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - lan-access
networks:
  lan-access:
    driver: bridge
```

- [ ] **Step 3: validate statically**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
./scripts/validate-stack.sh yandex-station
```

Expected: `Validation successful for stacks/yandex-station.yaml`. If `docker-compose` (v1) is missing, run `docker compose -f stacks/yandex-station.yaml config > /dev/null && echo OK`.

- [ ] **Step 4: commit**

```bash
cd /home/salekseev/src/github.com/salekseev/stacks
git add stacks/yandex-station.yaml
git commit -m "feat(yandex-station): self-hosted quasard backend for the rooted Midi

Quasard impersonates the Yandex cloud so the speaker resolves quasar.yandex.net/.ru
and scbh.yandex.net to silverstone:80/:443. Source build via uv; cloud LLM + edge
TTS keep the 4 GB GPU budget for local GigaAM ASR. network_mode: host to 192.168.1.10
matches plex.yaml/scrypted.yaml so the LAN station can reach it; OPNsense firewall
scopes :80/:443 to the Midi IP."
```

Expected: commit succeeds.

---

## Task 4 (PHASE 2): Stop lite-kit and deploy quasard

**Why:** lite-kit and quasard both need `:80/:443`. lite-kit is temporary (unlock only); quasard is permanent. Stop lite-kit before starting quasard.

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

- [ ] **Step 3: deploy quasard stack**

```bash
! ssh silverstone 'cd /home/salekseev/src/github.com/salekseev/stacks && docker compose -f stacks/yandex-station.yaml up -d'
```

Expected: container starts (may take 30–60 s for first-run torch download).

- [ ] **Step 4: verify quasard is running**

```bash
! ssh silverstone 'docker compose -f stacks/yandex-station.yaml ps'
```

Expected: `yandex-quasard` status `Up`.

- [ ] **Step 5: check healthcheck**

```bash
! ssh silverstone 'curl -fsSL http://localhost:80/health'
```

Expected: HTTP 200 or health endpoint response (may take 30 s if first startup).

---

## Task 5 (PHASE 2 + OPNsense): Wire the DNS routing

**Why:** the Midi must resolve `quasar.yandex.net` etc. to silverstone for impersonation to work. OPNsense Unbound + DHCP reservation + firewall scoping.

**[USER SHELL]** — All steps require OPNsense UI or console access (Lanner mini-PC).

- [ ] **Step 1: add Unbound host overrides (OPNsense UI)**

Log into OPNsense → **Services → Unbound DNS → Overrides** → **+** (add override):

**Override 1:**
- Type: `A`
- Host: `quasar`
- Domain: `yandex.net`
- IP: `192.168.1.10`

**Override 2:**
- Type: `A`
- Host: `quasar`
- Domain: `yandex.ru`
- IP: `192.168.1.10`

**Override 3:**
- Type: `A`
- Host: `scbh`
- Domain: `yandex.net`
- IP: `192.168.1.10`

Apply. Verify:

```bash
! ssh silverstone 'configctl unbound check && drill @127.0.0.1 quasar.yandex.net A && drill @127.0.0.1 scbh.yandex.net A'
```

Expected: all three queries return `192.168.1.10` (A-only, no AAAA).

- [ ] **Step 2: DHCP reservation for the Midi (OPNsense UI)**

Log into OPNsense → **Services → DHCPv4 → [Interface_LAN]** → **Reservations** → **+**:

- MAC: `<MIDI_MAC>`
- IP: `<MIDI_IP>` (from Task 0 Step 3)
- Hostname: `yandex-midi` (optional)
- Set DNS servers: **checked**, use OPNsense LAN IP (e.g., `192.168.1.1`)

Save and apply. This ensures only the Midi uses the overrides; other devices use default DNS.

- [ ] **Step 3: firewall rule — restrict `:80/:443` to Midi IP (OPNsense UI)**

Log into OPNsense → **Firewall → Rules → LAN** → **+** (add rule):

- Action: `Pass`
- Direction: `in`
- Interface: `LAN`
- Source: `<MIDI_IP>` (single IP, not subnet)
- Destination: `192.168.1.10` (silverstone)
- Port Destination: `80,443`
- Log: checked

Insert above the default `Pass LAN to any rule` so it takes precedence. Save, apply.

Expected: traffic from the Midi to silverstone:80/:443 is allowed; other LAN hosts are blocked (or use default rule).

- [ ] **Step 4: verify DNS resolution on the Midi**

```bash
! ssh silverstone 'adb shell "getprop ro.net.dns1; nslookup quasar.yandex.net 2>&1 | head -5"'
```

Expected: DNS server = OPNsense IP; `quasar.yandex.net` resolves to `192.168.1.10`.

- [ ] **Step 5: end-to-end test — activate the Midi and ask it a question**

On the Midi's app or via voice ("Алиса, …"), ask a simple question (e.g., "Сколько сейчас времени?" = "What time is it?").

Expected: quasard logs ASR → LLM call → TTS response. Midi plays response. Check logs:

```bash
! ssh silverstone 'docker logs yandex-quasard | tail -30'
```

Verify ADB still responds:

```bash
adb shell id
```

Expected: `uid=0(root)` (Phase 1 lock-in survived).

---

## Task 6: Post-deploy cleanup & recording

- [ ] **Step 1: record the verified layout** — `<MIDI_IP>`, firmware, the `quasard` firmware/platform folder, and the exact Unbound/firewall rules, into the stack's README or a notes file under `/mnt/spool/apps/config/yandex-station/`.

- [ ] **Step 2: optional SSH hardening** — add `/root/.ssh/authorized_keys` on the Midi and drop the Dropbear `-B` flag so root login is key-only (see spec §5.6).

- [ ] **Step 3: note the remaining follow-ups** from the spec (§10): full cloud detach (Tier 2), voice cloning (F5-TTS), Zigbee coordinator, glagol `:1961` Home Assistant control.

---

## Rollback

- **OPNsense:** delete the Unbound overrides + DHCP reservation; restore DNS. Non-destructive.
- **silverstone:** `docker compose -f stacks/yandex-station.yaml down` (keep the branch to revert). Stop lite-kit.
- **Midi:** a factory reset wipes `/data` and cannot revert firmware. If the Nov-4 build cannot be brought under control, the reset path is the only documented escape and is irreversible at the firmware layer.
- **Leak:** never publish `/data/quasar/devices.json`, device keys, MAC, serial, or Wi-Fi password.
