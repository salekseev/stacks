# Yandex Station Midi Self-Hosted Stand — Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. Steps marked **[USER SHELL]** touch the physical Midi, silverstone, or OPNsense. Do them in the order below. Repo files already on this branch are marked done and are not recommitted here.

**Goal:** A Yandex Station Midi (`cucumber`) on the IoT VLAN uses a self-hosted backend. OPNsense Host Overrides send the HTTPS names to `192.168.99.10` and `ntp.yantp.net` to `192.168.99.1` before the button reset. One factory reset, while lite-kit is listening on `192.168.99.10:80` and `:443`, opens root ADB. Root is locked in. lite-kit is then stopped and `stacks/yandex-station.yaml` takes that address. DNS does not move.

**Spec:** `docs/superpowers/specs/2026-11-08-yandex-station-midi-self-host-design.md`

**Status:** Repo files are on `feature/yandex-station-midi-self-host` (contrib, five submodules, Compose file, IoT-only Unbound tags, image workflow). Device, silverstone host, and OPNsense steps are still gated on the unlock below. This plan does not downgrade firmware and does not factory-reset a second time. There is no dnsmasq service and no Query Forwarding file.

**Working branch:** `feature/yandex-station-midi-self-host`

---

## Do these in order

1. **Task 1** — stage Supertonic 3, prompts, and `.env` on silverstone.
2. **Task 2** — install the tagged Unbound zones, delete any global Host Overrides for these names, confirm OPNsense NTP on the IoT interface, add the LAN-to-speaker ADB passes, and keep the IoT DHCP DNS server at `192.168.99.1`. Dig from IoT and from LAN before anything else.
3. **Task 3** — start lite-kit on `192.168.99.10` with `run/no_downgrade`. The host cannot bind that address: TrueNAS owns `*:80` and `*:443`, and VLAN 99 is tagged on `ens1f0np0`.
4. **Task 4** — button reset, then the in-app Wi-Fi join onto IoT, then ADB on silverstone. No `uid=0` means stop.
5. **Task 5** — lock in root and confirm a reboot.
6. **Task 6** — remove the lite-kit container, then `docker compose up`.
7. **Task 7** — dig `ntp.yantp.net`, then a normal reboot and a spoken question.
8. **Task 8** — write down what was verified.

Every `adb` command runs on silverstone (`ssh silverstone 'adb ...'`), so there is one ADB server. The repo checkout used by those commands is `/home/salekseev/src/github.com/salekseev/stacks` on silverstone.

---

## Environment

- silverstone LAN address is `192.168.1.10`. The station must not be sent to the Tailscale address `100.77.121.38`.
- Speakers live on OPNsense IoT: `opt1`, VLAN 99, `ix2_vlan99`, `192.168.99.0/24`, gateway `192.168.99.1`. IoT also has delegated IPv6. LAN is `192.168.1.0/24`. Speaker DNS is tagged for `192.168.99.0/24` only. LAN clients are not tagged.
- Host paths: config `/mnt/spool/apps/config/yandex-station/`, data `/mnt/spool/apps/data/yandex-station/`. The `apps` account is uid/gid **568**.
- Current firmware `0.373.1.16…20261104` is newer than the Midi build lite-kit's README records (`factory-9`). A factory reset wipes `/data` and cannot revert firmware.
- Placeholders: `<MIDI_MAC>` (capture before the reset), `<MIDI_IP>` (an address in `192.168.99.0/24`), `<OPENAI_API_KEY>` (the codex-lb `yandex` key), `<GIGAAM_DEVICE>` (`cpu` or `cuda`), `<TTS_VOICE>` (`M1`–`M5` or `F1`–`F5`; pinned supertonic README has no `F6`). Leave `OPENAI_BASE_URL` and `OPENAI_MODEL` unset; Compose uses `http://codex-lb:2455/v1` and `gpt-6-luna`. ADB and SSH run from silverstone, `192.168.1.10`.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `stacks/yandex-station.yaml` | v3rt3p services on the IoT ipvlan. No dnsmasq, no NTP container, no healthchecks. | On this branch |
| `stacks/yandex-station/unbound-iot-acl.conf` | Tagged local zones for `192.168.99.0/24`. Not a global Host Override. | Install in `unbound.opnsense.d` |
| `stacks/yandex-station/unbound-host-overrides.csv` | The same names and addresses, for reading. Do not import it. A global import applies to the LAN. | Do not import |
| `stacks/yandex-station/{https-proxy,quasar-server,quasistreaming-gigam,supertonic-tts,processor}` | Five git submodules. Image tags are their short SHAs. | On this branch |
| `.github/workflows/v3rt3p-images.yml` | PR builds the five images. A master push publishes `ghcr.io/salekseev/v3rt3p-<svc>:<sha>`. | On this branch |
| `contrib/yandex-noupdate.sh`, `contrib/bin/dropbear`, `contrib/bin/dropbearkey`, `contrib/etc/init.d/S99zdropbear` | OTA disable and Dropbear. Binaries are static ARM EABI5. | On this branch |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/.env` | Secrets. Mode `600`, owned by the deploying user. | Task 1 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/` | Supertonic 3 tree, `onnx/` and `voice_styles/` at the top. | Task 1 |
| `/mnt/spool/apps/config/yandex-station/v3rt3p/prompts/` | Three handlebars files from processor `a43e40e`. | Task 1 |
| `/mnt/spool/apps/data/yandex-station/v3rt3p/{postgres-data,gigaam-cache}/` | Postgres data and the GigaAM download cache. | Task 1 |
| `~/lite-kit/` on silverstone | Unlock HTTPS stand. Not a Compose service. Its dnsmasq is not the speaker's resolver. | Task 3, stopped in Task 6 |
| OPNsense tagged local zones | `unbound-iot-acl.conf` for `192.168.99.0/24`. | Install before the reset |
| OPNsense IoT DHCP and firewall | Reservation on `opt1` with DNS `192.168.99.1`. Passes in §5.6 of the spec. | Task 2 |

---

## Task 1: Stage host files on silverstone

The Compose file is already in git. This task only fills host directories. Create them as the SSH user so the downloads can write, then hand the asset and data directories to uid `568`. Leave `.env` owned by the deploying user.

- [ ] **Step 1: directories**

```bash
! ssh silverstone 'sudo install -d -o "$(id -u)" -g "$(id -g)" -m 755 \
  /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets \
  /mnt/spool/apps/config/yandex-station/v3rt3p/prompts \
  /mnt/spool/apps/data/yandex-station/v3rt3p/postgres-data \
  /mnt/spool/apps/data/yandex-station/v3rt3p/gigaam-cache'
```

Expected: the SSH user can create files in each directory.

- [ ] **Step 2: Supertonic 3 at the pinned revision**

```bash
! ssh silverstone 'command -v hf >/dev/null || pip install --user "huggingface_hub[cli]"
hf download supertone-oss-archive/supertonic-3 \
  --revision aafc6e32416a594460b32413efc49d7fe4ce6d46 \
  --local-dir /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets
test -f /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/onnx/tts.json
test -f /mnt/spool/apps/config/yandex-station/v3rt3p/supertonic-tts-assets/voice_styles/F1.json'
```

Expected: `onnx/` and `voice_styles/` are directly inside `supertonic-tts-assets/`. Do not download `v3rt3p-storage.re146.dev/supertonic-tts-model.zip`.

- [ ] **Step 3: prompts from the pinned processor commit**

```bash
! ssh silverstone 'base=https://raw.githubusercontent.com/v3rt3p/processor/a43e40e02f0dd3e6929dfcecf5b8781d3e86024e
dest=/mnt/spool/apps/config/yandex-station/v3rt3p/prompts
curl -fsSL "$base/prompt.handlebars" -o "$dest/prompt.handlebars"
curl -fsSL "$base/prompt-state.handlebars" -o "$dest/prompt-state.handlebars"
curl -fsSL "$base/prompt-functions.handlebars" -o "$dest/prompt-functions.handlebars"'
```

Expected: three non-empty files.

- [ ] **Step 4: `.env`**

```bash
! ssh silverstone 'umask 077
cat > /mnt/spool/apps/config/yandex-station/v3rt3p/.env << EOF
POSTGRES_PASSWORD=<POSTGRES_PASSWORD>
OPENAI_API_KEY=<OPENAI_API_KEY>
GIGAAM_DEVICE=<GIGAAM_DEVICE>
TTS_VOICE=<TTS_VOICE>
TZ=Europe/Moscow
EOF
chmod 600 /mnt/spool/apps/config/yandex-station/v3rt3p/.env'
```

Expected: mode `600`, no `<PLACEHOLDER>` left, file not in git. Compose reads it only when `--env-file` is passed.

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

## Task 2: Host Overrides, firewall, reservation **[USER SHELL]**

Do this before the button reset. Speaker HTTPS and NTP stay on VLAN 99, so they do not need an IoT-to-LAN pass. Do not use `interface-view`. That option on `ix2_vlan99` took the resolver down. Do not import the CSV as global Host Overrides.

- [ ] **Step 1: record `<MIDI_MAC>`** from the current lease or the speaker label.

- [ ] **Step 2: install `stacks/yandex-station/unbound-iot-acl.conf`** as `/usr/local/etc/unbound.opnsense.d/yandex-iot-acl.conf`. Delete any global Host Overrides for these names. Run `unbound-checkconf` and stop if it fails. Then restart Unbound. The file tags `192.168.99.0/24` and the current IoT prefix `2600:4040:5b42:2599::/64`. Update the prefix if the delegation changes.

- [ ] **Step 3: NTP on the IoT interface.** Services → NTP listens on `opt1` (`ix2_vlan99`). From a host that can reach the IoT gateway:

```bash
ntpdate -q 192.168.99.1
```

Expected: a stratum 3 reply from `192.168.99.1`. If IoT rules allow the gateway only for DNS, add a pass for UDP `123` to `192.168.99.1`.

- [ ] **Step 4: firewall.** On LAN, above the default allow:

1. Pass source `192.168.1.10` to `<MIDI_IP>` TCP `2222,5555`.
2. Reject other LAN sources to `<MIDI_IP>` TCP `2222,5555`.

No pass from IoT to `192.168.1.10` for TCP `80`, `443`, `31116` or UDP `123`. No pass for port `53` to silverstone. No WAN forward of those ports. Apply.

- [ ] **Step 5: OPNsense → Services → DHCPv4 → IoT (`opt1`) → Reservations.** MAC `<MIDI_MAC>`, IP `<MIDI_IP>` inside `192.168.99.0/24`. DNS servers for this reservation: `192.168.99.1`, the same as the rest of IoT.

- [ ] **Step 6: dig.**

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

Expected: `docker logs yandex-lite-kit` prints address `192.168.99.10`. `run/no_downgrade` is the flag `equasar_server.py` honors. Do not run `install-firmware.sh`. Do not run `./start.sh` on the host.

- [ ] **Step 2: confirm the stand**

```bash
! ssh silverstone 'sudo docker exec yandex-lite-kit ps -o args= -p "$(cat /lite-kit/run/server.pid)"'
```

Expected: the process is `scripts/equasar_server.py`. The speaker uses the tagged zones from Task 2. `ps | grep lite-kit` is the wrong check: the argv does not contain that string.

---

## Task 4: One button reset, app join, ADB gate **[USER SHELL]**

Task 2's tagged zones answer from an IoT source, and the lite-kit container is listening on `192.168.99.10:80` and `:443`. Resetting before both leaves the speaker on ordinary DNS or with nowhere to send the unlock query.

**Reset (Midi / `cucumber`):** unplug power, hold the rear mute-microphone button, plug power back in, hold about 7–10 seconds until the LED is yellow-green, release, and wait for the setup prompt.

- [ ] **Step 1: join the IoT Wi-Fi in the Yandex app while lite-kit is still up.** Add the device on VLAN 99. The unlock query happens during that join, not at the moment the LED changes.

- [ ] **Step 2: ADB from silverstone**

```bash
! ssh silverstone 'adb connect <MIDI_IP>:5555
adb devices
adb shell id
adb shell getprop ro.build.display.id
adb shell getprop ro.product.cpu.abi'
```

Expected: `<MIDI_IP>:5555 device` and `uid=0(root)`. Record the firmware as `<FIRMWARE_BUILD>` and the ABI. Confirm the ABI can run the static ARM EABI5 Dropbear before Task 5.

**Gate:** `uid=0` continues to Task 5. Anything else stops the procedure. `firmware/` is empty and `run/no_downgrade` is set, so there is no `[OTA-AUTO]` manifest to wait for.

---

## Task 5: Lock in root **[USER SHELL]**

Do this while lite-kit is still listening on `:80/:443`, before Task 6. The IoT view stays as it is.

- [x] **Repo files** `contrib/yandex-noupdate.sh`, `contrib/bin/dropbear`, `contrib/bin/dropbearkey`, and `contrib/etc/init.d/S99zdropbear` are already on the branch.

- [ ] **Step 1: markers**

```bash
! ssh silverstone 'adb shell "mkdir -p /data/quasar /data/opt/bin /data/opt/etc/dropbear /data/opt/etc/init.d"
adb shell "touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb && chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb"'
```

- [ ] **Step 2: OTA disable**

`yandex-noupdate.sh` with no argument runs `disable`.

```bash
! ssh silverstone 'adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/yandex-noupdate.sh /data/opt/yandex-noupdate.sh
adb shell sh /data/opt/yandex-noupdate.sh
adb shell sh /data/opt/yandex-noupdate.sh status'
```

Expected status includes `launch.json : updatesd убран`, `applier     : заглушён`, `ota key     : подменён`, and `maind --updatesd не запущен`.

- [ ] **Step 3: Dropbear**

```bash
! ssh silverstone 'adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbear /data/opt/bin/dropbear
adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/bin/dropbearkey /data/opt/bin/dropbearkey
adb shell chmod +x /data/opt/bin/dropbear /data/opt/bin/dropbearkey
adb shell /data/opt/bin/dropbearkey -t ed25519 -f /data/opt/etc/dropbear/hk_ed25519
adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/dropbear/authorized_keys /data/opt/etc/dropbear/authorized_keys
adb push /home/salekseev/src/github.com/salekseev/stacks/contrib/etc/init.d/S99zdropbear /data/opt/etc/init.d/S99zdropbear
adb shell chmod 600 /data/opt/etc/dropbear/authorized_keys
adb shell chmod +x /data/opt/etc/init.d/S99zdropbear
adb shell /data/opt/etc/init.d/S99zdropbear'
```

Expected: the binary runs (Task 4 recorded an ABI that can execute AArch32), and something is listening on TCP `2222`.

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

- [ ] **Step 1: stop lite-kit**

```bash
! ssh silverstone 'sudo docker rm -f yandex-lite-kit'
```

Expected: the container is gone, so `192.168.99.10` is free for https-proxy. The tagged zones stay. IoT DNS stays `192.168.99.1`.

- [ ] **Step 2: deploy**

`up -d` pulls the five ghcr images after they have been published from `master`. Until that workflow has published the pinned tags, add `--build`.

```bash
! ssh silverstone 'docker compose -f /home/salekseev/src/github.com/salekseev/stacks/stacks/yandex-station.yaml --env-file /mnt/spool/apps/config/yandex-station/v3rt3p/.env up -d
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

The Host Overrides are in place. This step checks them again. `ntp.yantp.net` is OPNsense at `192.168.99.1`.

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

Expected: `uid=0(root)` still. quasar-server shows the station connecting. A button factory reset here would wipe `/data` and drop root. If the local backend cannot be reached without that wipe, stop and repeat Tasks 3–5 on purpose with lite-kit listening on `:80/:443` again. Leave the view in place.

---

## Task 8: Record the result

- [ ] **Step 1:** write `<MIDI_IP>`, `<FIRMWARE_BUILD>`, `<GIGAAM_DEVICE>`, `<TTS_VOICE>`, and the firewall rules into `/mnt/spool/apps/config/yandex-station/`. Do not copy device keys, `devices.json`, or the Wi-Fi password into git.

- [ ] **Step 2:** follow-ups from spec §10 stay out of this procedure: CUDA GigaAM, processor tools, Tier 2 egress blocking, key-only SSH, and the upstream https-proxy / supertonic attribution items.

---

## Rollback

- **OPNsense:** delete `/usr/local/etc/unbound.opnsense.d/yandex-iot.conf`, restart Unbound, and delete the Task 2 passes. Host Overrides were not given Yandex names. IoT DHCP DNS was already `192.168.99.1`.
- **silverstone:** `docker compose -f /home/salekseev/src/github.com/salekseev/stacks/stacks/yandex-station.yaml --env-file /mnt/spool/apps/config/yandex-station/v3rt3p/.env down`. Stop lite-kit if it is still up.
- **Midi:** a factory reset wipes `/data` and cannot revert firmware.
