# Task Completion Checklist

When finishing a task (adding or modifying a stack):

1. **Validate syntax**: `./scripts/validate-stack.sh <stack-name>`
2. **Check conventions**:
   - Image version pinned (no floating `latest` without digest)
   - `restart: unless-stopped` present
   - Uses `expose` (not `ports`) if behind Cloudflare tunnel
   - Uses `env_file: stack.env` for PUID/PGID/TZ
   - Config volume follows `/mnt/spool/apps/config/<service>:/config` pattern
3. **If adding Cloudflare tunnel route**: add hostname entry to cloudflared config in media.yaml
4. **Commit** with descriptive message following pattern: `feat: <description>`
