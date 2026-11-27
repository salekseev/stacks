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
