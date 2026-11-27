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
