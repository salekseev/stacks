# Suggested Commands

## Validation
```bash
# Validate a stack file syntax (run from repo root)
./scripts/validate-stack.sh <stack-name>
# e.g.: ./scripts/validate-stack.sh media
```

## Deployment
```bash
# Deploy a stack
docker-compose -f stacks/<stack-name>.yaml up -d

# Stop a stack
docker-compose -f stacks/<stack-name>.yaml down

# View logs (follow)
docker-compose -f stacks/<stack-name>.yaml logs -f

# Check running services
docker-compose -f stacks/<stack-name>.yaml ps

# Validate compose syntax manually
docker-compose -f stacks/<stack-name>.yaml config
```

## Debugging
```bash
# Check Docker daemon status
systemctl status docker

# Inspect container logs
docker logs <container-name>

# Check resource usage
docker stats
```

## Git Workflow
```bash
git status
git diff
git add stacks/<file>.yaml
git commit -m "feat: <description>"
```
