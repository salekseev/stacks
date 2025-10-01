# Coding Agent Context

This file provides essential context for AI coding agents working on this project. It helps agents understand the project structure, conventions, and workflow to provide more accurate and helpful assistance.

## Project Overview

<!-- Replace this section with your project's specific details -->
This repository is a collection of Docker Compose configurations for self-hosting various services. Each service, or "stack," is defined in a YAML file within the `stacks/` directory. The repository is managed using a set of shell scripts that enforce a specific workflow for adding and modifying stacks.

**Key Technologies:**
- Docker Compose
- Shell Scripts
- YAML Configuration

**Architecture:**
- Service-based configuration management
- Script-driven workflow automation
- Template-based feature development

## Development Environment Setup

### Prerequisites
<!-- List required tools, versions, and dependencies -->
- Docker and Docker Compose
- Shell environment (bash/zsh)
- Git

### Quick Start
```bash
# Clone the repository
git clone <repository-url>
cd <project-directory>

# Set up environment (if applicable)
# source .env or run setup scripts

# Verify setup
docker --version
docker-compose --version
```

## Project Structure

```
/
├── stacks/           # Docker Compose configurations
├── scripts/          # Automation and workflow scripts
├── templates/        # Template files for new features
├── specs/           # Feature specifications (when created)
└── memory/          # Agent memory and context files
```

## Development Workflow

### Feature Development Process
1. **Create New Feature**: Use `./scripts/create-new-feature.sh "description"`
2. **Branch Naming**: Features use `NNN-feature-name` format
3. **Documentation**: Each feature includes spec.md, plan.md, tasks.md
4. **Implementation**: Follow the plan and update tasks
5. **Testing**: Validate stack deployment and functionality

### Common Commands
```bash
# Create a new stack/feature
./scripts/create-new-feature.sh "Stack description"

# Deploy a specific stack
docker-compose -f stacks/<stack-name>.yaml up -d

# Stop a stack
docker-compose -f stacks/<stack-name>.yaml down

# View logs
docker-compose -f stacks/<stack-name>.yaml logs -f
```

## Code Organization

### File Naming Conventions
- Stack files: `<service-name>.yaml`
- Scripts: `<action>-<target>.sh`
- Templates: `<type>-template.md`

### Directory Conventions
- `/stacks/`: Production-ready compose files
- `/scripts/`: Reusable automation scripts
- `/templates/`: Templates for consistent file creation
- `/specs/`: Feature specifications and planning docs

## Configuration Management

### Environment Variables
- **Centralized Configuration**: `stacks/stack.env` contains shared environment variables for the media automation stack
- **Stack-Specific Variables**: 
  - `starr.yaml` uses variables from `stack.env` (TZ, PUID, PGID, API keys, TUNNEL_TOKEN)
  - Other stacks may use inline environment variables or separate env files
- Review each `.yaml` file for specific requirements

### Security Considerations
- Environment files may contain sensitive data (API keys, tunnel tokens)
- **Never commit `stack.env` with real credentials** - use `.gitignore`
- Review `.gitignore` for excluded sensitive files
- Use Docker secrets or external secret management when appropriate
- For Portainer deployments, upload env files through Portainer UI

### Stack-Specific Notes

#### Media Automation Stack (`starr.yaml`)
- **Deployment**: Via Portainer web UI on remote host
- **Environment**: Requires `stacks/stack.env` with configured values
- **Host Directories**: Must exist on Portainer host before deployment
  - Media: `/mnt/dpool/media/{tv,movies,downloads/{usenet,torrents}}`
  - Configs: `/mnt/spool/apps/config/{sonarr,radarr,prowlarr,nzbget,qbittorrent,flaresolverr,unpackerr,recyclarr,cloudflared}`
- **Validation**: Use Portainer's built-in compose validation or `./scripts/validate-stack.sh starr`
- **Network**: Isolated `starr_net` bridge network (172.28.0.0/16)
- **Port Exposure**: Only qBittorrent peer ports (6881/tcp, 6881/udp) published
- **Remote Access**: All web UIs accessible only via Cloudflare Tunnel
- **Documentation**: See [detailed quickstart](specs/001-create-a-comprehensive/quickstart.md)

### Local Testing

**Test Script**: `scripts/test-stack.sh`
- **Purpose**: Validate stack configuration locally before Portainer deployment
- **Usage**: `./scripts/test-stack.sh starr [--keep-running] [--verbose]`
- **Test Environment**: Uses `stacks/stack-test.env` with temporary directories
- **Validation**: All 9 services must reach healthy/running state
- **Cleanup**: Automatic (removes containers and temp files)

**Environment Parameterization**:
- Host paths now use environment variables:
  - `STARR_CONFIG_ROOT` - base config directory
  - `STARR_MEDIA_ROOT` - base media directory
  - `STARR_NETWORK_NAME` - network name
- **Production**: Uses `stacks/stack.env` (not committed)
- **Testing**: Uses `stacks/stack-test.env` (committed, safe defaults)
- **Backward Compatible**: Defaults to original paths if variables not set

**Test Workflow**:
1. Edit `stacks/starr.yaml`
2. Run `./scripts/test-stack.sh starr` to validate locally
3. If tests pass, deploy to Portainer with confidence

**Troubleshooting Tests**:
- Timeout waiting for healthy: Check `docker compose logs`
- Port conflicts: Ensure no production stack running locally
- Permission errors: Ensure user in docker group

## Testing and Validation

### Static Stack Validation
To validate the syntax and configuration of a stack without starting any services, use the `validate-stack.sh` script. This is the recommended first step for testing any changes to a stack file.

```bash
# Validate a specific stack
./scripts/validate-stack.sh <stack-name>
```

### Runtime Stack Testing
Runtime testing involves deploying the stack to a live Docker environment to ensure it functions as expected.

```bash
# Deploy the stack
docker-compose -f stacks/<stack-name>.yaml up -d

# Check that services are running
docker-compose -f stacks/<stack-name>.yaml ps

# View service logs for errors
docker-compose -f stacks/<stack-name>.yaml logs -f

# Stop the stack when testing is complete
docker-compose -f stacks/<stack-name>.yaml down
```

## Agent-Specific Guidelines

### When Working with This Codebase
1. **Always check existing stacks** before creating new ones
2. **Use provided scripts** rather than manual git operations
3. **Follow the feature directory structure** for new additions
4. **Update documentation** when modifying existing stacks
5. **Test deployments** before finalizing changes

### Common Tasks for Agents
- **Creating new Docker Compose stacks**
- **Modifying existing service configurations**
- **Updating documentation and specifications**
- **Troubleshooting deployment issues**
- **Optimizing container configurations**

### Important Files to Reference
- `scripts/common.sh`: Shared script utilities
- `templates/`: Reference templates for consistency
- Individual stack `.yaml` files for service-specific context

## Troubleshooting

### Common Issues
1. **Port conflicts**: Check for conflicting port assignments
2. **Environment variables**: Ensure required vars are set
3. **Volume mounts**: Verify host paths exist and permissions
4. **Network issues**: Check Docker network configuration

### Debugging Commands
```bash
# Check Docker daemon status
systemctl status docker

# Inspect container logs
docker logs <container-name>

# Check resource usage
docker stats

# Validate compose file syntax
docker-compose -f <file> config
```

## Additional Context

### Project Goals
This project aims to provide a standardized way to deploy and manage self-hosted services using Docker Compose, with a focus on maintainability and reproducibility.

### Contribution Guidelines
- Use the established workflow scripts
- Maintain documentation alongside code changes
- Test all configurations before committing
- Follow existing naming and organizational conventions

---

*Note: This file should be customized for each specific project. Replace placeholder sections with project-specific information.*
