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
- Check `stacks/stack.env` for shared environment variables
- Individual stacks may require additional environment setup
- Review each `.yaml` file for specific requirements

### Security Considerations
- Environment files may contain sensitive data
- Review `.gitignore` for excluded sensitive files
- Use Docker secrets or external secret management when appropriate

## Testing and Validation

### Static Stack Validation
To validate the syntax and configuration of a stack without starting any services, use the `validate-stack.sh` script. This is the recommended first step for testing any changes to a stack file.

```bash
# Validate a specific stack
./scripts/validate-stack.sh <stack-name>
```

### Dependabot Configuration Validation
Before committing changes to the Dependabot configuration, use the `validate-dependabot.sh` script to perform a dry run validation. This script checks:
- YAML syntax validation
- Docker Compose file existence and validity
- Included stack files validation
- Directory path verification
- Docker image detection

```bash
# Validate Dependabot configuration
./scripts/validate-dependabot.sh
```

The script will perform comprehensive checks and provide colored output indicating:
- ✓ Green: Validation passed
- ✗ Red: Validation failed (needs fixing)
- ⚠ Yellow: Warning or optional check skipped

**Exit codes:**
- `0`: All validations passed
- `1`: One or more validations failed

This validation should be run before committing any changes to:
- `.github/dependabot.yml`
- `stacks/docker-compose.yaml`
- Individual stack files in `stacks/`

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
