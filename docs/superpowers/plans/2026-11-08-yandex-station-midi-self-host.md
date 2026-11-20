# Yandex Station Midi Self-Hosted Stand — Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. Steps marked **[USER SHELL]** touch the physical Midi, silverstone, or OPNsense. Do them in the order below. Repo files already on this branch are marked done and are not recommitted here.

**Goal:** A Yandex Station Midi (`cucumber`) on the IoT VLAN uses a self-hosted backend. OPNsense tagged local zones send the HTTPS names to `192.168.99.10` and `ntp.yantp.net` to `192.168.99.1` for `192.168.99.0/24` only, before the button reset. One factory reset, while lite-kit is listening on `192.168.99.10:80` and `:443`, opens root ADB. Root is locked in. lite-kit is then stopped and `stacks/yandex-station.yaml` takes that address. DNS does not move.

**Spec:** `docs/superpowers/specs/2026-11-08-yandex-station-midi-self-host-design.md`

**Status:** Merged to `master` on 2026-11-18 (`a4fb250`). The tagged Unbound file is installed on lanner. A LAN query for these names is public. A query sourced from `192.168.99.1` receives the speaker addresses. `ntpdate -q 192.168.99.1` from lanner returned stratum 3. LAN may reach IoT. IoT may not initiate connections to LAN. The speaker unlock and the Portainer deploy are still ahead. This plan does not downgrade firmware and does not factory-reset a second time. There is no dnsmasq service and no Query Forwarding file.

**Guides checked 2026-11-19:** [Midi](https://hackalice.me/devices/station-midi/), [DNS unlock](https://hackalice.me/start/root/), [SSH and updates](https://hackalice.me/start/ssh/), [speaker DNS](https://hackalice.me/internals/network/).

**Working branch:** `master`

---

## Do these in order

1. **Task 1** — stage Supertonic 3, prompts, and `.env` on silverstone.
2. **Task 2** — DNS and NTP are done. Record the Midi MAC and reserve it on IoT DHCP with DNS `192.168.99.1`.
3. **Task 3** — start lite-kit on `192.168.99.10` with `run/no_downgrade`. The host cannot bind that address: TrueNAS owns `*:80` and `*:443`, and VLAN 99 is tagged on `ens1f0np0`.
4. **Task 4** — Midi reset (hold the center or rear microphone button, then apply power), join IoT from the app while the phone stays on LAN, then ADB on silverstone. No `uid=0` means stop. Do not downgrade.
5. **Task 5** — lock in root and confirm a reboot.
6. **Task 6** — remove the lite-kit container, then `docker compose up`.
7. **Task 7** — dig `ntp.yantp.net`, then a normal reboot and a spoken question.
8. **Task 8** — write down what was verified.

Every `adb` command runs on silverstone (`ssh silverstone 'adb ...'`), so there is one ADB server. silverstone has no checkout of this repo. Its home is `/mnt/spool/home/salekseev`. Task 5 copies `contrib/` there before `adb push`.

---

## Environment

- silverstone LAN address is `192.168.1.10`. The station must not be sent to the Tailscale address `100.77.121.38`.
- Speakers live on OPNsense IoT: `opt1`, VLAN 99, `ix2_vlan99`, `192.168.99.0/24`, gateway `192.168.99.1`. IoT also has delegated IPv6. LAN is `192.168.1.0/24`. Speaker DNS is an `access-control-tag` for `192.168.99.0/24` and the current IoT IPv6 prefix. LAN clients are not tagged. `interface-tag` is not used: the generated ACL allows `0.0.0.0/0` and `::/0`, and those rules override every `interface-*` setting. LAN may reach IoT. IoT may not initiate connections to LAN.
- Host paths: config `/mnt/spool/apps/config/yandex-station/`, data `/mnt/spool/apps/data/yandex-station/`. The `apps` account is uid/gid **568**.
- Current firmware `0.373.1.16…20261104` is newer than the Midi build the guides verified (`0.369.1.46…20261013`). The self-hosted unlock page says builds after 20–21 October 2026 reject that server's certificate, so `get_sync_info` does not enable ADB. `0.373` is in that set and has not been verified on Midi. A factory reset wipes `/data`. This plan does not serve a downgrade. `uid=0` is the gate. The underscore marker paths (`/data/quasar_activate_*`) are for factory-6, not this retail build.
- Placeholders: `<MIDI_MAC>` (capture before the reset), `<MIDI_IP>` (an address in `192.168.99.0/24`), `<OPENAI_API_KEY>` (the codex-lb `yandex` key), `<GIGAAM_DEVICE>` (`cpu` or `cuda`), `<TTS_VOICE>` (`M1`–`M5` or `F1`–`F5`; pinned supertonic README has no `F6`). Leave `OPENAI_BASE_URL` and `OPENAI_MODEL` unset; Compose uses `http://codex-lb:2455/v1` and `gpt-6-luna`. ADB and SSH run from silverstone, `192.168.1.10`.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `stacks/yandex-station.yaml` | v3rt3p services on the IoT ipvlan. No dnsmasq, no NTP container, no healthchecks. | On this branch |
| `stacks/yandex-station/unbound-iot-acl.conf` | Tagged local zones. Begins with `server:` and `define-tag: "yandex-iot"`. | Installed on lanner as `yandex-iot-acl.conf` |
| `stacks/yandex-station/{https-proxy,quasar-server,quasistreaming-gigam,supertonic-tts,processor}` | Five git submodules. Image tags are their short SHAs. | On this branch |
| `.github/workflows/v3rt3p-images.yml` | PR builds the five images. A master push publishes `ghcr.io/salekseev/v3rt3p-<svc>:<sha>`. | On this branch |
| `contrib/yandex-noupdate.sh`, `contrib/bin/dropbear`, `contrib/bin/dropbearkey`, `contrib/etc/init.d/S99zdropbear` | OTA disable and Dropbear. Binaries are static ARM EABI5. | On this branch |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/.env` | Secrets. Mode `600`, owned by the deploying user. | Task 1 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/` | Supertonic 3 tree, `onnx/` and `voice_styles/` at the top. | Task 1 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/prompts/` | Three handlebars files from processor `a43e40e`. | Task 1 |
| `/mnt/spool/apps/data/yandex-station/v3rt3p/{quasar-server-db,gigaam-cache}/` | SQLite file `database.sqlite3` and the GigaAM download cache. | Task 1 |
| `~/lite-kit/` on silverstone | Unlock HTTPS stand. Not a Compose service. Its dnsmasq is not the speaker's resolver. | Task 3, stopped in Task 6 |
| OPNsense tagged local zones | `unbound-iot-acl.conf` for `192.168.99.0/24` and the current IoT IPv6 prefix. | Installed on lanner |
| OPNsense IoT DHCP and firewall | Reservation on `opt1` with DNS `192.168.99.1` is still open. Firewall is the existing LAN-to-IoT allow. | Task 2 |

---

## Task 1: Stage host files on silverstone

The Compose file is already in git. This task only fills host directories. Create them as the SSH user so the downloads can write, then hand the asset and data directories to uid `568`. Leave `.env` owned by the deploying user.

- [x] **Step 1: directories** — present on silverstone, verified 2026-11-18.

```bash
! ssh silverstone 'sudo install -d -o "$(id -u)" -g "$(id -g)" -m 755 \
  /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets \
  /mnt/spool/apps/config/yandex-station/v3rt3p/prompts \
  /mnt/spool/apps/data/yandex-station/v3rt3p/postgres-data \
  /mnt/spool/apps/data/yandex-station/v3rt3p/gigaam-cache'
```

Expected: the SSH user can create files in each directory.

- [x] **Step 2: Supertonic 3 at the pinned revision** — `tts.json`, `unicode_indexer.json`, and `voice_styles/F1.json` match revision `aafc6e32416a594460b32413efc49d7fe4ce6d46`. Six ONNX files and voices `F1`–`F5`, `M1`–`M5` are in place.

```bash
! ssh silverstone 'command -v hf >/dev/null || pip install --user "huggingface_hub[cli]"
hf download supertone-oss-archive/supertonic-3 \
  --revision aafc6e32416a594460b32413efc49d7fe4ce6d46 \
  --local-dir /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets
test -f /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/onnx/tts.json
test -f /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/voice_styles/F1.json'
```

Expected: `onnx/` and `voice_styles/` are directly inside `supertonic-tts-assets/`. Do not download `v3rt3p-storage.re146.dev/supertonic-tts-model.zip`.

- [x] **Step 3: prompts from the pinned processor commit** — the three files match processor `a43e40e02f0dd3e6929dfcecf5b8781d3e86024e`.

```bash
! ssh silverstone 'base=https://raw.githubusercontent.com/v3rt3p/processor/a43e40e02f0dd3e6929dfcecf5b8781d3e86024e
dest=/mnt/spool/apps/config/yandex-station/v3rt3p/prompts
curl -fsSL "$base/prompt.handlebars" -o "$dest/prompt.handlebars"
curl -fsSL "$base/prompt-state.handlebars" -o "$dest/prompt-state.handlebars"
curl -fsSL "$base/prompt-functions.handlebars" -o "$dest/prompt-functions.handlebars"'
```

Expected: three non-empty files.

- [x] **Step 4: `.env`** — present, mode `600`, owned by `salekseev`. Do not rewrite it. The live keys are `IOT_PARENT=ens1f0v2`, `SPEAKER_IP=192.168.99.10`, `POSTGRES_PASSWORD`, `OPENAI_API_KEY`, `TTS_VOICE=F1`, `GIGAAM_DEVICE=cpu`, and `GIGAAM_DOCKERFILE=Dockerfile.cpu`. `OPENAI_BASE_URL` and `OPENAI_MODEL` are unset. The stack mounts this file as the `yandex_env` secret. Portainer does not need stack environment variables.

- [ ] **Step 5: ownership**

```bash
! ssh silverstone 'chmod -R a+rX /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets /mnt/spool/apps/config/yandex-station/v3rt3p/prompts
sudo chown -R 568:568 \
  /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets \
  /mnt/spool/apps/config/yandex-station/v3rt3p/prompts \
  /mnt/spool/apps/data/yandex-station/v3rt3p
chmod 600 /mnt/spool/apps/config/yandex-station/v3rt3p/.env'
```

Expected: `.env` stays owned by the deploying user. The GigaAM and Supertonic images have no `USER` instruction, so they run as root and can use these mounts. Do not commit host assets or `.env`.

---

## Task 2: Tagged DNS, firewall, reservation **[USER SHELL]**

Do the remaining steps before the button reset. Speaker HTTPS and NTP stay on VLAN 99, so they do not need an IoT-to-LAN pass. The existing policy is that LAN may reach IoT and IoT may not initiate connections to LAN. Do not use `interface-tag` or `interface-view`. The generated ACL allows `0.0.0.0/0` and `::/0`, which overrides every `interface-*` setting, and `interface-view` on `ix2_vlan99` took the resolver down. There is no host-override CSV.

- [ ] **Step 1: record `<MIDI_MAC>`** from the current lease or the speaker label.

- [x] **Step 2: install `stacks/yandex-station/unbound-iot-acl.conf`** as `/usr/local/etc/unbound.opnsense.d/yandex-iot-acl.conf`. Done on lanner 2026-11-18. The file begins with `server:` and `define-tag: "yandex-iot"`. Unbound start copied it to `/var/unbound/etc/yandex-iot-acl.conf`. Global Host Overrides for these names were removed in the GUI before the reload. `unbound-checkconf` passed before `configctl unbound restart`. The file tags `192.168.99.0/24` and the current IoT prefix `2600:4040:5b42:2599::/64`. Update the prefix if the delegation changes. `192.168.99.0/24` does not renumber. Speaker DNS stays `192.168.99.1`.

- [x] **Step 3: NTP on the IoT interface.** Verified 2026-11-18 from lanner: `ntpdate -q 192.168.99.1` returned stratum 3, offset about 0, delay 0.026 s.

- [x] **Step 4: firewall.** Accepted as-is for this deployment. LAN (`192.168.1.0/24`) may reach IoT (`192.168.99.0/24`). IoT may not initiate connections to LAN. silverstone (`192.168.1.10`) reaches the speaker on TCP `2222` and `5555` because it is on LAN. No extra pass or reject is added for those ports. No IoT-to-LAN pass for TCP `80`, `443`, `31116` or UDP `123`. No pass for port `53` to silverstone. No WAN forward of those ports.

- [ ] **Step 5: OPNsense → Services → DHCPv4 → IoT (`opt1`) → Reservations.** MAC `<MIDI_MAC>`, IP `<MIDI_IP>` inside `192.168.99.0/24`. DNS servers for this reservation: `192.168.99.1`, the same as the rest of IoT.

- [x] **Step 6: dig.** Verified 2026-11-18. From source `192.168.99.1`, `quasar.yandex.net` and `login.yandex.ru` are `192.168.99.10`, `ntp.yantp.net` is `192.168.99.1`, and AAAA is empty. From a LAN source those names are public, including AAAA.

```bash
dig @192.168.99.1 quasar.yandex.net A +short
dig @192.168.99.1 quasar.yandex.net AAAA +short
dig @192.168.99.1 ntp.yantp.net A +short
dig @192.168.1.1 quasar.yandex.net A +short
dig @192.168.1.1 login.yandex.ru A +short
```

Expected: from an IoT source, `quasar.yandex.net` prints `192.168.99.10` and `ntp.yantp.net` prints `192.168.99.1`. AAAA prints nothing. From a LAN host, neither name prints `192.168.99.10`. Stop if the LAN query is hijacked. The phone that joins the speaker uses that LAN resolver.

---

## Task 3: Start lite-kit

The speaker resolves the unlock names to `192.168.99.10`. lite-kit has to answer there from its own network namespace. Do not add `192.168.99.10` to `ens1f0v2` or any host interface. TrueNAS nginx listens on `0.0.0.0:80` and `:443`, so a host address would both fail the bind and publish the UI on the IoT VLAN. Also keep IPv6 off on `ens1f0v2` (`net.ipv6.conf.ens1f0v2.disable_ipv6=1`). The container's own dnsmasq is not the speaker's resolver.

- [ ] **Step 1: clone, block firmware serving, start a container on `192.168.99.10`**

```bash
! ssh silverstone 'test -d ~/lite-kit/.git || git clone https://github.com/krevetkqqq/lite-kit.git ~/lite-kit
find ~/lite-kit/firmware -name "*.zip" -print | grep -q . && { echo "firmware zip present; remove it"; exit 1; }
mkdir -p ~/lite-kit/run
touch ~/lite-kit/run/no_downgrade
sudo docker network inspect yandex-iot >/dev/null 2>&1 || sudo docker network create -d ipvlan \
  --subnet=192.168.99.0/24 --gateway=192.168.99.1 \
  -o parent=ens1f0v2 -o ipvlan_mode=l2 yandex-iot
sudo docker rm -f yandex-lite-kit >/dev/null 2>&1 || true
sudo docker run -d --name yandex-lite-kit \
  --network yandex-iot --ip 192.168.99.10 \
  -v "$HOME/lite-kit:/lite-kit" \
  -e LOCAL_IP=192.168.99.10 \
  --entrypoint bash debian:bookworm-slim \
  -lc "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq python3 ca-certificates procps && cd /lite-kit && ./start.sh && tail -f /lite-kit/log/server.log"'
```

Expected: `docker logs yandex-lite-kit` prints address `192.168.99.10`. `run/no_downgrade` is the flag `equasar_server.py` honors. Do not run `install-firmware.sh`. Do not run `./start.sh` on the host. The container needs outbound HTTPS to `deb.debian.org` for that `apt-get`. If it fails, do not reset the speaker. `yandex-iot` uses the same parent and subnet as the stack network, so Task 6 must delete it before `docker compose up`.

- [ ] **Step 2: confirm the stand**

```bash
! ssh silverstone 'sudo docker exec yandex-lite-kit ps -o args= -p "$(cat /lite-kit/run/server.pid)"'
```

Expected: the process is `scripts/equasar_server.py`. The speaker uses the tagged zones from Task 2. `ps | grep lite-kit` is the wrong check: the argv does not contain that string.

---

## Task 4: One button reset, app join, ADB gate **[USER SHELL]**

Task 2's tagged zones answer from an IoT source, and the lite-kit container is listening on `192.168.99.10:80` and `:443`. Resetting before both leaves the speaker on ordinary DNS or with nowhere to send the unlock query.

**Reset (Midi / `cucumber`, hackalice 2026-11-19):** disconnect power. Hold the center touch button or the rear microphone button. Connect power while holding. Wait for the sound and the spoken reset message. Setup is offered after one or two minutes. This is not the Light sequence (power on first, then hold pause until yellow-green).

`0.373` is after the 20–21 October 2026 cutoff. The self-hosted server guide says those builds reject the certificate (`unknown_ca` on TLS) and never request `get_sync_info`. The Midi they verified is `0.369.1.46…20261013`. If this speaker does that, Task 5 does not start. This plan does not put a firmware zip in `firmware/` and does not clear `run/no_downgrade`.

- [ ] **Step 1: join IoT from the Yandex app while lite-kit is still up.** Keep the phone on the LAN. Bluetooth and location stay on. In «Дом с Алисой», add an Alice device and stop on the Wi-Fi screen. Choose the IoT network there. The phone must not join the IoT SSID: that SSID is tagged, and the app has to reach real Yandex. The unlock query comes from the speaker after it joins, not when the LED changes.

- [ ] **Step 2: ADB from silverstone**

```bash
! ssh silverstone 'adb connect <MIDI_IP>:5555
adb devices
adb shell id
adb shell getprop ro.build.display.id
adb shell getprop ro.product.cpu.abi'
```

Expected: `<MIDI_IP>:5555 device` and `uid=0(root)`. Record the firmware as `<FIRMWARE_BUILD>` and the ABI. Confirm the ABI can run the static ARM EABI5 Dropbear before Task 5.

**Gate:** `uid=0` continues to Task 5. Anything else stops the procedure. A closed port with no `get_sync_info` in `~/lite-kit/log/server.log` matches the post-October certificate rejection. `firmware/` is empty and `run/no_downgrade` is set, so there is no `[OTA-AUTO]` manifest to wait for. The wiki's unlock DNS is only `quasar.yandex.net`, `quasar.yandex.ru`, and `scbh.yandex.net`. This network also sends `login.yandex.ru` and the other speaker names to `192.168.99.10`. The phone does not see that, because it stays on the LAN. If the speaker joins Wi-Fi and never calls `get_sync_info`, those extra names are the next thing to inspect.

---

## Task 5: Lock in root **[USER SHELL]**

Do this while lite-kit is still listening on `:80/:443`, before Task 6. The tagged zones stay as they are.

- [x] **Repo files** `contrib/yandex-noupdate.sh`, `contrib/bin/dropbear`, `contrib/bin/dropbearkey`, and `contrib/etc/init.d/S99zdropbear` are already on the branch.

- [ ] **Step 1: markers**

```bash
! ssh silverstone 'adb shell "mkdir -p /data/quasar /data/opt/bin /data/opt/etc/dropbear /data/opt/etc/init.d"
adb shell "touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb && chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb"'
```

- [ ] **Step 2: copy `contrib/` to silverstone, then disable OTA**

`yandex-noupdate.sh` with no argument runs `disable`. silverstone has no stacks checkout, so the push paths below are the copy made here.

```bash
rsync -a contrib/ silverstone:~/yandex-unlock/
ssh silverstone 'adb push ~/yandex-unlock/yandex-noupdate.sh /data/opt/yandex-noupdate.sh
adb shell sh /data/opt/yandex-noupdate.sh
adb shell sh /data/opt/yandex-noupdate.sh status
mkdir -p ~/yandex-unlock-backup
adb pull /data/opt/backup ~/yandex-unlock-backup'
```

Expected status includes `launch.json : updatesd убран`, `applier     : заглушён`, `ota key     : подменён`, and `maind --updatesd не запущен`. On factory-6 the script leaves `updatesd` in place because that build has no `--platformd`. `0.373` is a later retail build and is expected to have `--platformd`. Pull `/data/opt/backup` off the speaker. A later factory reset deletes that directory. Do not commit the backup.

- [ ] **Step 3: Dropbear**

`rcS` runs `/etc/init.d/S??*` from the root filesystem. A copy that exists only under `/data/opt/etc/init.d/` does not start on the next boot. The script stays key-only (`-s -D /data/opt/etc/dropbear`). The guide's default line is `-B` (empty password). This plan does not use `-B`.

```bash
ssh silverstone 'adb push ~/yandex-unlock/bin/dropbear /data/opt/bin/dropbear
adb push ~/yandex-unlock/bin/dropbearkey /data/opt/bin/dropbearkey
adb shell chmod +x /data/opt/bin/dropbear /data/opt/bin/dropbearkey
adb shell /data/opt/bin/dropbearkey -t ed25519 -f /data/opt/etc/dropbear/hk_ed25519
adb push ~/yandex-unlock/etc/dropbear/authorized_keys /data/opt/etc/dropbear/authorized_keys
adb shell chmod 600 /data/opt/etc/dropbear/authorized_keys
adb shell mount -o remount,rw /
adb push ~/yandex-unlock/etc/init.d/S99zdropbear /etc/init.d/S99zdropbear
adb shell chmod +x /etc/init.d/S99zdropbear
adb shell sync
adb shell mount -o remount,ro /
adb shell /etc/init.d/S99zdropbear'
```

Expected: the binary runs (Task 4 recorded an ABI that can execute AArch32), `/etc/init.d/S99zdropbear` is the file that was pushed, and something is listening on TCP `2222`. Rootfs edits on `0.369` with verified boot were still unchecked on the Midi page. If `mount -o remount,rw /` fails, or the file is gone after the Task 5 reboot, stop. Do not switch the script to `-B` to get past that.

- [ ] **Step 4: reboot and re-check**

```bash
! ssh silverstone 'adb shell reboot'
```

Wait for the speaker, then:

```bash
! ssh silverstone 'adb connect <MIDI_IP>:5555
adb shell id
adb shell sh /data/opt/yandex-noupdate.sh status'
ssh -p 2222 -o StrictHostKeyChecking=accept-new root@<MIDI_IP> id
```

Expected: `uid=0(root)` over both ADB and SSH. Dropbear is key-only (`-s`). The private key stays in 1Password. The speaker stays on IoT.

---

## Task 6: Stop lite-kit and start the stack

- [x] **Step 1: stop lite-kit** — done 2026-11-20. `yandex-lite-kit` and the `yandex-iot` network were removed. `shared-services` was already present.

- [ ] **Step 2: deploy**

The ipvlan address `192.168.99.10` and parent `ens1f0v2` are in the compose file. `POSTGRES_PASSWORD` and `OPENAI_API_KEY` are read from `/mnt/spool/apps/config/yandex-station/v3rt3p/.env` when the containers start. A Portainer stack needs no environment variables. `up -d` pulls the five ghcr images after they have been published from `master`. Until that workflow has published the pinned tags, add `--build`.

```bash
! ssh silverstone 'docker compose -f /home/salekseev/src/github.com/salekseev/stacks/stacks/yandex-station.yaml up -d
docker compose -f /home/salekseev/src/github.com/salekseev/stacks/stacks/yandex-station.yaml ps'
```

Expected: each service is `Up`. None of them define a healthcheck, so Compose will not say `healthy`. https-proxy holds `192.168.99.10` TCP `80`, `443`, and `31116`. This stack does not listen on port `53` or UDP `123`.

- [ ] **Step 3: certificate**

```bash
! ssh silverstone 'openssl s_client -connect 192.168.99.10:443 -servername quasar.yandex.net </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject'
```

Expected: the leaf issuer is `CN=EM EV TLS CA - G3C`.

---

## Task 7: DNS check and spoken request **[USER SHELL]**

The tagged zones are in place. This step checks them again. `ntp.yantp.net` is OPNsense at `192.168.99.1`.

- [ ] **Step 1: dig from a host on `192.168.99.0/24`, and once from a LAN host:**

```bash
dig @192.168.99.1 quasar.yandex.net A +short
dig @192.168.99.1 quasar.yandex.net AAAA +short
dig @192.168.99.1 ntp.yantp.net A +short
dig @192.168.1.1 quasar.yandex.net A +short
```

From the same IoT host, repeat the `ntp.yantp.net` A query with `dig -6` against OPNsense's IoT IPv6 address.

Expected: `quasar.yandex.net` A prints `192.168.99.10`. `ntp.yantp.net` A prints `192.168.99.1`, including the IPv6 transport. The AAAA query prints nothing.

- [ ] **Step 2: reboot the Midi, not a factory reset**

```bash
! ssh silverstone 'adb shell reboot'
```

After it returns, ask a short question. Then:

```bash
! ssh silverstone 'adb connect <MIDI_IP>:5555
adb shell id
docker logs v3rt3p-quasar-server | tail -20'
```

Expected: `uid=0(root)` still. quasar-server shows the station connecting. A button factory reset here would wipe `/data` and drop root. If the local backend cannot be reached without that wipe, stop and repeat Tasks 3–5 on purpose with lite-kit listening on `:80/:443` again. Leave the tagged zones in place.

On Mini 2 `0.369`, `get_sync_info` can install DNS forwarders `77.88.8.x`. The speaker then resolves `quasar.yandex.net` on the public internet and never asks OPNsense. A speaker with an empty `/data` uses the DHCP DNS for the first query, which is the tagged Unbound. If quasar-server shows no connection after this reboot, check whether the speaker is querying `77.88.8.x` on port 53. The fix is to keep IoT DNS to `192.168.99.1` only. Do not open that path to the LAN.

---

## Task 8: Record the result

- [ ] **Step 1:** write `<MIDI_IP>`, `<FIRMWARE_BUILD>`, `<GIGAAM_DEVICE>`, `<TTS_VOICE>`, and the firewall rules into `/mnt/spool/apps/config/yandex-station/`. Do not copy device keys, `devices.json`, or the Wi-Fi password into git.

- [ ] **Step 2:** follow-ups from spec §10 stay out of this procedure: CUDA GigaAM, processor tools, Tier 2 egress blocking, key-only SSH, and the upstream https-proxy / supertonic attribution items.

---

## Rollback

- **OPNsense:** delete `/usr/local/etc/unbound.opnsense.d/yandex-iot-acl.conf` and `/var/unbound/etc/yandex-iot-acl.conf`, then restart Unbound. Leave the LAN-to-IoT policy as it was. IoT DHCP DNS was already `192.168.99.1`.
- **silverstone:** `docker rm -f yandex-lite-kit` and `docker network rm yandex-iot` if they remain, then `docker compose -f /home/salekseev/src/github.com/salekseev/stacks/stacks/yandex-station.yaml down`.
- **Midi:** a factory reset wipes `/data` and cannot revert firmware.
