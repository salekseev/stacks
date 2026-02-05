#!/bin/bash
# Validate Dependabot configuration before committing
# This script performs multiple validation checks on the Dependabot setup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPENDABOT_CONFIG="$REPO_ROOT/.github/dependabot.yml"
STACKS_DIR="$REPO_ROOT/stacks"
DOCKER_COMPOSE_FILE="$STACKS_DIR/docker-compose.yaml"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_header() {
    echo ""
    print_status "$BLUE" "=========================================="
    print_status "$BLUE" "$1"
    print_status "$BLUE" "=========================================="
    echo ""
}

# Track overall status
VALIDATION_FAILED=0

print_header "Dependabot Configuration Validator"

# Step 1: Validate YAML syntax
print_status "$BLUE" "1. Validating YAML syntax..."
if command -v yamllint &> /dev/null; then
    if yamllint -d relaxed "$DEPENDABOT_CONFIG"; then
        print_status "$GREEN" "✓ Dependabot YAML syntax is valid"
    else
        print_status "$RED" "✗ Dependabot YAML syntax validation failed"
        VALIDATION_FAILED=1
    fi
else
    print_status "$YELLOW" "⚠ yamllint not found, skipping YAML syntax validation"
fi

# Step 2: Validate Dependabot config file exists
print_status "$BLUE" "2. Checking Dependabot config file..."
if [ -f "$DEPENDABOT_CONFIG" ]; then
    print_status "$GREEN" "✓ Dependabot config file exists at $DEPENDABOT_CONFIG"
else
    print_status "$RED" "✗ Dependabot config file not found at $DEPENDABOT_CONFIG"
    VALIDATION_FAILED=1
    exit 1
fi

# Step 3: Validate docker-compose.yaml exists in stacks directory
print_status "$BLUE" "3. Checking for docker-compose.yaml in stacks directory..."
if [ -f "$DOCKER_COMPOSE_FILE" ]; then
    print_status "$GREEN" "✓ docker-compose.yaml found at $DOCKER_COMPOSE_FILE"
else
    print_status "$RED" "✗ docker-compose.yaml not found at $DOCKER_COMPOSE_FILE"
    print_status "$YELLOW" "  Dependabot expects a docker-compose.yaml file in the monitored directory"
    VALIDATION_FAILED=1
fi

# Step 4: Validate all included files exist
print_status "$BLUE" "4. Validating included stack files..."
if [ -f "$DOCKER_COMPOSE_FILE" ]; then
    MISSING_FILES=0
    while IFS= read -r line; do
        # Extract filename from include lines (e.g., "  - changedetection.yaml")
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*\.yaml)$ ]]; then
            filename="${BASH_REMATCH[1]}"
            filepath="$STACKS_DIR/$filename"
            if [ -f "$filepath" ]; then
                print_status "$GREEN" "  ✓ Found: $filename"
            else
                print_status "$RED" "  ✗ Missing: $filename"
                MISSING_FILES=$((MISSING_FILES + 1))
                VALIDATION_FAILED=1
            fi
        fi
    done < "$DOCKER_COMPOSE_FILE"

    if [ $MISSING_FILES -eq 0 ]; then
        print_status "$GREEN" "✓ All included stack files exist"
    else
        print_status "$RED" "✗ $MISSING_FILES included stack file(s) missing"
    fi
fi

# Step 5: Validate Docker Compose syntax
print_status "$BLUE" "5. Validating Docker Compose syntax..."
if command -v docker &> /dev/null; then
    if docker compose -f "$DOCKER_COMPOSE_FILE" config > /dev/null 2>&1; then
        print_status "$GREEN" "✓ Docker Compose syntax is valid"
    else
        print_status "$RED" "✗ Docker Compose syntax validation failed"
        print_status "$YELLOW" "  Run 'docker compose -f $DOCKER_COMPOSE_FILE config' for details"
        VALIDATION_FAILED=1
    fi
else
    print_status "$YELLOW" "⚠ Docker not found, skipping Docker Compose syntax validation"
fi

# Step 6: Check if GitHub CLI is available for API validation
print_status "$BLUE" "6. Checking for GitHub CLI (optional)..."
if command -v gh &> /dev/null; then
    print_status "$GREEN" "✓ GitHub CLI (gh) is available"

    # Check if authenticated
    if gh auth status &> /dev/null; then
        print_status "$GREEN" "✓ GitHub CLI is authenticated"

        # Note: GitHub doesn't have a direct API to validate dependabot.yml
        # But we can check if the repo has Dependabot enabled
        print_status "$BLUE" "  Checking repository Dependabot status..."
        if gh api repos/:owner/:repo/vulnerability-alerts &> /dev/null; then
            print_status "$GREEN" "  ✓ Repository has Dependabot alerts enabled"
        else
            print_status "$YELLOW" "  ℹ Could not verify Dependabot alerts status"
        fi
    else
        print_status "$YELLOW" "⚠ GitHub CLI not authenticated, skipping API checks"
        print_status "$YELLOW" "  Run 'gh auth login' to authenticate"
    fi
else
    print_status "$YELLOW" "⚠ GitHub CLI not found, skipping API validation"
    print_status "$YELLOW" "  Install from: https://cli.github.com/"
fi

# Step 7: Validate Dependabot directory paths
print_status "$BLUE" "7. Validating Dependabot directory paths..."
INVALID_PATHS=0
while IFS= read -r line; do
    # Extract directory from dependabot config
    if [[ "$line" =~ ^[[:space:]]*directory:[[:space:]]+\"(.*)\"$ ]]; then
        dir_path="${BASH_REMATCH[1]}"
        # Remove leading slash for local path check
        local_path="$REPO_ROOT${dir_path}"
        if [ -d "$local_path" ]; then
            print_status "$GREEN" "  ✓ Directory exists: $dir_path"
        else
            print_status "$RED" "  ✗ Directory not found: $dir_path"
            INVALID_PATHS=$((INVALID_PATHS + 1))
            VALIDATION_FAILED=1
        fi
    fi
done < "$DEPENDABOT_CONFIG"

if [ $INVALID_PATHS -eq 0 ]; then
    print_status "$GREEN" "✓ All Dependabot directories exist"
fi

# Step 8: Check for Docker images in the compose files
print_status "$BLUE" "8. Checking for Docker images in stack files..."
IMAGE_COUNT=$(grep -r "image:" "$STACKS_DIR"/*.yaml 2>/dev/null | wc -l)
if [ "$IMAGE_COUNT" -gt 0 ]; then
    print_status "$GREEN" "✓ Found $IMAGE_COUNT Docker image reference(s) in stack files"
    print_status "$BLUE" "  Sample images:"
    grep -h "image:" "$STACKS_DIR"/*.yaml 2>/dev/null | head -5 | sed 's/^/  /'
else
    print_status "$YELLOW" "⚠ No Docker images found in stack files"
fi

# Summary
print_header "Validation Summary"

if [ $VALIDATION_FAILED -eq 0 ]; then
    print_status "$GREEN" "✅ All validation checks passed!"
    echo ""
    print_status "$GREEN" "Your Dependabot configuration is ready to commit."
    print_status "$BLUE" "Dependabot will scan the following:"
    print_status "$BLUE" "  - Directory: /stacks"
    print_status "$BLUE" "  - File: docker-compose.yaml"
    print_status "$BLUE" "  - Included stack files: $(grep -c "^  - .*\.yaml$" "$DOCKER_COMPOSE_FILE" 2>/dev/null || echo 0) files"
    echo ""
    exit 0
else
    print_status "$RED" "❌ Validation failed! Please fix the issues above before committing."
    echo ""
    exit 1
fi
