# stacks/ notes for agents

Host-level gotchas that are not visible in the compose files.

## Hermes: `op` fails with "permissions are too broad" (ZFS ACL on `cache/scratch`)

**Symptom.** `hermes secrets onepassword sync` resolves nothing; every `op read` fails with:

```
error initializing client: Logic: (failed to model.WriteSessionToFile), Can't continue.
We can't safely access "/opt/data/cache/scratch/com.agilebits.op.1000/.<id>" because its
permissions are too broad. Change its permissions to 600 and try again.
```

The first `op` call works and leaves a session file behind; every later call fails on it.

**Cause.** Hermes (v0.23+) sets `TMPDIR=/opt/data/cache/scratch` for every child process. On
silverstone that path is `/mnt/spool/apps/data/hermes/gateway/cache/scratch`, on the dataset
`spool/apps/data` (`acltype=nfsv4`, `aclmode=passthrough`, `aclinherit=passthrough`). New files
inherit `group@`/`builtin_users` entries and an `owner@` entry with `x`, so they come out as mode
770 (even under `umask 077`; `chmod 600` reads back as 700). `op` accepts only 600.

**Fix (host, one time, as the `salekseev` owner; no sudo needed).** Give `cache/scratch` an ACL
whose inheritable entries have no `group@` / `builtin_users` and no `x` for files, then delete
op's stale session dir so it is recreated under the new ACL:

```sh
S=/mnt/spool/apps/data/hermes/gateway/cache/scratch
nfs4xdr_getfacl $S > ~/acl-backup-hermes-scratch.txt        # rollback: truenas_setfacl -f <file> $S
cat > /tmp/scratch-acl.txt <<'EOF'
owner@:rwpRWxDdaAcCos:-------:allow
owner@:rwpRW-DdaAcCos:f-i----:allow
owner@:rwpRWxDdaAcCos:-di----:allow
user:salekseev:rwpRWxDdaAcCos:-------:allow
user:salekseev:rwpRW-DdaAcCos:f-i----:allow
user:salekseev:rwpRWxDdaAcCos:-di----:allow
group:builtin_administrators:rwpRWxDdaAcCos:-------:allow
group:builtin_administrators:rwpRW-DdaAcCos:f-i----:allow
group:builtin_administrators:rwpRWxDdaAcCos:-di----:allow
user:apps:rwpRWxDdaAc--s:-------:allow
user:apps:rwpRW-DdaAc--s:f-i----:allow
user:apps:rwpRWxDdaAc--s:-di----:allow
EOF
truenas_setfacl -f /tmp/scratch-acl.txt $S
rm -rf $S/com.agilebits.op.1000
```

The file/dir split matters: with one inheritable `owner@` entry that has `x`, files come out 700
and `op` still refuses them. Verified 2026-11-26: new files 600, new dirs 700, three consecutive
`op read` calls pass with Hermes' real `TMPDIR`.

**Verify.**

```sh
docker exec -u 1000:1000 -e HERMES_HOME=/opt/data hermes-gateway hermes secrets onepassword sync
```

**Caveats.** The ACL lives on the host, not in git. It is lost if `cache/scratch` is deleted
(Hermes recreates it with the default inherited ACL), if someone resets permissions in the TrueNAS
UI, or on a new host. Reapply the steps above. Only new files inherit it, so old files in scratch
keep mode 770 until Hermes prunes them (24 h idle). Do not "fix" this with a tmpfs over
`cache/scratch`: Hermes keeps scratch on real disk on purpose (large clones, venvs).

**The `op` binary** comes from our gateway image (`stacks/hermes-gateway/Dockerfile`, published
as `ghcr.io/salekseev/hermes-gateway`), not from a volume or an init container.

## Hermes: the Hindsight memory plugin reads its config file before the environment

**Symptoms.** Memory never saves. `/opt/data/logs/errors.log` shows either
`No module named 'hindsight_client'` on every retain, or the plugin talking to the wrong server
(`Hindsight API at http://localhost:8888 reports version None`).

**Two separate causes.**

1. **Wrong config.** The plugin (`/opt/data/plugins/hindsight`) reads `/opt/data/hindsight/config.json`
   first and only falls back to `HINDSIGHT_MODE` / `HINDSIGHT_API_URL` / `HINDSIGHT_BANK_ID` when that
   file is missing or empty. The compose file sets those variables, but a `config.json` written with
   defaults (`"mode": "cloud"`, `"api_url": "http://localhost:8888"`) silently overrides them. From inside
   the gateway container `localhost` is the container itself. It must say:

   ```json
   "mode": "local_external",
   "api_url": "http://hindsight:8888/api",
   "bank_id": "hermes"
   ```

   `/api` is the server's `HINDSIGHT_API_BASE_PATH`; `hindsight` resolves over the `shared-services`
   network. The key is `HINDSIGHT_API_KEY` in `/opt/data/.env` (leave `apiKey` out of the JSON).

2. **Missing client.** The v0.23 base image does not ship `hindsight-client`, the plugin imports it, and
   `HERMES_DISABLE_LAZY_INSTALLS=1` plus a root-owned venv stop it installing at runtime.
   `stacks/hermes-gateway/Dockerfile` installs it; the `-hs<version>` part of the image tag is that
   version. The base image enforces a 3-day uv release cooldown, so a client release newer than three
   days cannot be installed: pin the newest older one and let Renovate move it later.

**Verify.** `grep "Hindsight initialized" /mnt/spool/apps/data/hermes/gateway/logs/agent.log | tail -1`
should show `mode=local_external, api_url=http://hindsight:8888/api, bank=hermes`, and no new
`hindsight_client` errors in `errors.log`. The server answers `GET http://hindsight:8888/api/version`
without a key.

## Hermes: sandbox bind mounts resolve inside dind, not on the gateway

**Symptoms.** `errors.log` warns "Docker backend is enabled for the messaging gateway but no explicit
host-visible output mount", the sandbox's `/root/.hermes/skills` is empty, and files the agent writes
to `/output` never reach Slack or the dashboard.

**Cause.** With `terminal.backend: docker` the gateway runs `docker run -v /opt/data/skills:...` against
the **dind** daemon (`DOCKER_HOST=tcp://dind:2375`). A bind source is a path on the daemon's host, so it
is looked up in the dind container's filesystem, where `/opt/data` did not exist. Docker silently
creates the missing path as an empty directory.

**Fix.** `stacks/hermes.yaml` mounts the needed gateway directories into `hermes-dind` at the same
`/opt/data/...` paths (skills, cache, browser_screenshots, images, attachments, composer-pastes), so a
bind source means the same thing on both sides. Output goes through a `docker_volumes` entry in
`/opt/data/config.yaml`:

```sh
docker exec -u 1000:1000 -e HERMES_HOME=/opt/data hermes-gateway \
  hermes config set terminal.docker_volumes '["/opt/data/cache/documents:/output"]'
```

If Hermes starts mounting another `/opt/data` directory (the log line is `Docker: mounting ... dir
/opt/data/<x>`), add it to the `dind` volumes. Check with
`docker exec hermes-dind ls /opt/data`: it should list those directories, not fail.

**Disk quota warning.** "Docker storage driver does not support per-container disk limits" is harmless:
dind's `overlay2` has no XFS project quota. `terminal.container_disk: 0` stops the warning.

## Hermes: keep the sandbox browser profile (logins, Cloudflare clearance) across redeploys

**Why it matters.** A site that fronts itself with Cloudflare's interactive "Verify you are human" check
(home-barista.com does) only asks a *new* client. A client holding a valid `cf_clearance` cookie and its
signed-in session is not challenged again. The old Camofox profile never saw the challenge for that reason:
it carried both for months. Hermes' Chrome starts with an empty profile, so it is challenged until a human
clears it once (Bot Screen: Take over, click the checkbox, sign in, Hand back).

**The profile must be durable.** In sandbox placement Hermes ignores `browser.user_data_dir` and always
uses `/home/pn/.hermes/bot-desktop/browser-profile` inside the sandbox. That is the sandbox container's own
filesystem, which Hermes may remove (orphan reaper) and which does not survive a new container. So the host
directory is bind-mounted over that exact path:

1. `stacks/hermes.yaml` mounts `gateway/bot-browser-profile` and `gateway/sandboxes` into `hermes-dind` at
   the same `/opt/data/...` paths (bind sources resolve on dind, see the section above).
2. Create the host directory once, owned by the gateway user (uid 1000, the sandbox's `pn`):
   `mkdir -p /mnt/spool/apps/data/hermes/gateway/bot-browser-profile`
3. Add the mount to the sandbox (merge into the existing list; a second `docker_volumes:` key silently
   overrides the first):

   ```sh
   docker exec -u 1000:1000 -e HERMES_HOME=/opt/data hermes-gateway hermes config set terminal.docker_volumes \
     '["/opt/data/cache/documents:/output","/opt/data/bot-browser-profile:/home/pn/.hermes/bot-desktop/browser-profile"]'
   ```

   Changing `docker_volumes` changes the container's environment label, so Hermes creates a fresh sandbox
   that has the mount.

**Do not name the host directory `browser-profile`.** `$HERMES_HOME/browser-profile` (that is `/opt/data/browser-profile`)
is Hermes' own real-profile snapshot store. `cleanup_real_profile_snapshots()` (`hermes_cli/browser_connect.py`)
does `shutil.rmtree` on it whenever a browser session is created with `browser.use_real_profile` off, which is
the default. The first version of this setup used that name; the bot's next `browser_exec` deleted the
directory, the sandbox's bind mount was left pointing at a deleted inode, and Chrome could not start. Use
`bot-browser-profile`, and keep anything you want to survive out of `$HERMES_HOME/browser-profile`.

**Verify.** `docker exec hermes-dind docker exec -u pn <sandbox> sh -c 'mount | grep browser-profile'`
shows the bind, and `ls /mnt/spool/apps/data/hermes/gateway/bot-browser-profile` on the host fills with Chrome's
profile files once the browser has run. Cookies then survive `docker rm` of the sandbox and a dind recreate.

**Do not** copy `cf_clearance` from a *different* browser's profile (Camofox's Firefox, for example).
Cloudflare ties it to the client's user agent and IP, so it does not transfer. Let a human clear it once in
this profile.

**Hermes running on your own computer** has a documented alternative: `browser.use_real_profile: true` in
that machine's `~/.hermes/config.yaml` (Desktop: Capabilities > Tools > Browser > "Use My Real Browser
Profile"). Hermes snapshots your default Chromium-family browser's active profile and drives the same
real browser binary, so logins and any clearance you earned there come along. It uses the machine
Hermes runs on, so it does not apply to the silverstone gateway, and the agent then acts with *all* of your
real logins (the docs call it "a consent-gated convenience, not an isolation boundary").
