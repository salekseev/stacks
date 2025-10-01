# Local Testing Guide

## Overview

Test the media automation stack locally before deploying to Portainer.

## Quick Start

```bash
# Run full test (creates temp dirs, deploys, validates, cleans up)
./scripts/test-stack.sh starr

# Keep stack running for manual inspection
./scripts/test-stack.sh starr --keep-running

# Verbose output
./scripts/test-stack.sh starr --verbose
```

## What Gets Tested

1. ✅ Docker Compose syntax validation
2. ✅ All 9 services start successfully
3. ✅ Services reach healthy state (or running for services without health checks)
4. ✅ Network isolation (separate test network)
5. ✅ Volume mounts work correctly
6. ✅ Environment variable substitution

## Test Environment

**Temporary directories created**:
- `/tmp/starr-test-{timestamp}/config/` - Service configurations
- `/tmp/starr-test-{timestamp}/media/` - Media and downloads

**Network**: `starr_net_test_{pid}` (isolated from production)

**Configuration**: `stacks/stack-test.env` (safe defaults, no secrets)

## Cleanup

Automatic cleanup happens on:
- ✅ Test success
- ✅ Test failure
- ✅ Ctrl+C interrupt

Unless `--keep-running` flag is used.

## Troubleshooting

### Test Fails with Timeout

- Check Docker daemon: `docker info`
- Increase timeout in script if needed
- Check logs: `docker compose -f stacks/starr.yaml --env-file stacks/stack-test.env logs`

### Port Conflicts

Test uses same ports as production. Ensure production stack not running locally.

### Permission Errors

Ensure your user can run Docker:
```bash
sudo usermod -aG docker $USER
# Log out and back in
```

## Integration with CI/CD

```yaml
# Example GitHub Actions
- name: Test Stack
  run: ./scripts/test-stack.sh starr
```

## Differences from Production

| Aspect | Local Test | Production (Portainer) |
|--------|------------|------------------------|
| Directories | `/tmp/starr-test-*/` | `/mnt/dpool/`, `/mnt/spool/` |
| Network | `starr_net_test_*` | `starr_net` |
| Config | `stack-test.env` | `stack.env` (secrets) |
| Cleanup | Automatic | Manual (via Portainer) |
| Tunnel | Fake token | Real Cloudflare token |


