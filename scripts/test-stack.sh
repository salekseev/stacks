#!/bin/bash
set -euo pipefail

# ============================================
# Local Stack Testing Script
# ============================================
# Tests a Docker Compose stack locally with temporary directories
# before deploying to production Portainer environment.
#
# Usage: ./scripts/test-stack.sh [STACK_NAME] [OPTIONS]
# Example: ./scripts/test-stack.sh starr --verbose

# ============================================
# CONFIGURATION
# ============================================

STACK_NAME="${1:-starr}"
STACK_FILE="stacks/${STACK_NAME}.yaml"
TEST_ENV="stacks/stack-test.env"
TIMEOUT=300  # 5 minutes
POLL_INTERVAL=10  # seconds

# ============================================
# FLAGS
# ============================================

KEEP_RUNNING=false
VERBOSE=false

# ============================================
# FUNCTIONS
# ============================================

usage() {
  cat << EOF
Usage: $0 [STACK_NAME] [OPTIONS]

Test a Docker Compose stack locally with temporary directories.

Arguments:
  STACK_NAME        Name of stack to test (default: starr)

Options:
  --keep-running    Leave stack running after test for manual inspection
  --verbose, -v     Show detailed output
  --help, -h        Show this help message

Examples:
  $0 starr                    # Run test with cleanup
  $0 starr --keep-running     # Run test, leave running
  $0 starr --verbose          # Run test with detailed output

Description:
  This script tests a Docker Compose stack in an isolated environment:
  - Creates temporary directories in /tmp/starr-test-{timestamp}/
  - Deploys all services with test configuration
  - Validates services reach healthy/running state
  - Automatically cleans up containers and temp files (unless --keep-running)

Prerequisites:
  - Docker Engine 20.10+
  - docker compose (v2.0+)
  - jq (for JSON parsing)

EOF
  exit 0
}

# ============================================
# ARGUMENT PARSING
# ============================================

# Parse all arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      usage
      ;;
    --keep-running)
      KEEP_RUNNING=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    *)
      STACK_NAME="$1"
      STACK_FILE="stacks/${STACK_NAME}.yaml"
      shift
      ;;
  esac
done

# ============================================
# PREREQUISITE VALIDATION
# ============================================

# Check for jq (required for JSON parsing)
if ! command -v jq &> /dev/null; then
  echo "❌ Error: jq is required but not installed"
  echo "   Install with:"
  echo "   - Fedora/RHEL: sudo dnf install jq"
  echo "   - Ubuntu/Debian: sudo apt install jq"
  echo "   - macOS: brew install jq"
  exit 1
fi

# Verify stack file exists
if [ ! -f "$STACK_FILE" ]; then
  echo "❌ Error: Stack file not found: $STACK_FILE"
  exit 1
fi

# Verify test environment file exists
if [ ! -f "$TEST_ENV" ]; then
  echo "❌ Error: Test environment file not found: $TEST_ENV"
  exit 1
fi

# ============================================
# SCRIPT START
# ============================================

echo "🚀 Starting local stack test: $STACK_NAME"
echo "   Stack file: $STACK_FILE"
echo "   Test env: $TEST_ENV"
echo ""

# ============================================
# TEMPORARY DIRECTORY SETUP
# ============================================

# Create timestamp-based temp directory
TIMESTAMP=$(date +%s)
TEST_DIR="/tmp/starr-test-${TIMESTAMP}"
export STARR_CONFIG_ROOT="${TEST_DIR}/config"
export STARR_MEDIA_ROOT="${TEST_DIR}/media"
export STARR_NETWORK_NAME="starr_net_test_$$"

# ============================================
# CLEANUP HANDLERS
# ============================================

# Cleanup function
cleanup() {
  local EXIT_CODE=$?
  
  if [ "$KEEP_RUNNING" = false ]; then
    echo ""
    echo "🧹 Cleaning up..."
    
    # Stop and remove containers
    if docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --quiet 2>/dev/null | grep -q .; then
      echo "   Stopping containers..."
      docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" down -v 2>/dev/null || true
    fi
    
    # Remove temp directory
    if [ -d "$TEST_DIR" ]; then
      echo "   Removing test directory: $TEST_DIR"
      rm -rf "$TEST_DIR"
    fi
    
    echo "✓ Cleanup complete"
  else
    echo ""
    echo "⚠️  Stack left running (--keep-running flag)"
    echo "   Test directory: $TEST_DIR"
    echo "   Network: $STARR_NETWORK_NAME"
    echo ""
    echo "   To inspect:"
    echo "   docker compose -f $STACK_FILE --env-file $TEST_ENV ps"
    echo "   docker compose -f $STACK_FILE --env-file $TEST_ENV logs -f"
    echo ""
    echo "   To stop:"
    echo "   docker compose -f $STACK_FILE --env-file $TEST_ENV down -v"
    echo "   rm -rf $TEST_DIR"
  fi
  
  exit $EXIT_CODE
}

# Trap cleanup on exit, interrupt, and termination
trap cleanup EXIT INT TERM

echo "📁 Creating test directories..."
echo "   Base: $TEST_DIR"
[ "$VERBOSE" = true ] && echo "   Config: $STARR_CONFIG_ROOT"
[ "$VERBOSE" = true ] && echo "   Media: $STARR_MEDIA_ROOT"
echo "   Network: $STARR_NETWORK_NAME"
echo ""

# Create directory structure for all services
mkdir -p "$STARR_CONFIG_ROOT"/{sonarr,radarr,prowlarr,nzbget,qbittorrent,flaresolverr,unpackerr,recyclarr,cloudflared}
mkdir -p "$STARR_MEDIA_ROOT"/{tv,movies,downloads/{usenet,torrents}}

if [ "$VERBOSE" = true ]; then
  echo "📂 Directory structure:"
  echo ""
  tree -L 3 "$TEST_DIR" 2>/dev/null || find "$TEST_DIR" -type d | sort
  echo ""
fi

echo "✅ Test directories created successfully"
echo ""

# ============================================
# STACK DEPLOYMENT
# ============================================

# Deploy stack
echo "🐳 Deploying stack..."
if [ "$VERBOSE" = true ]; then
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" up -d
  DEPLOY_EXIT=$?
else
  # Capture output but show errors
  DEPLOY_OUTPUT=$(docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" up -d 2>&1)
  DEPLOY_EXIT=$?
fi

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "❌ Stack deployment failed"
  echo ""
  if [ "$VERBOSE" = false ]; then
    echo "Error output:"
    echo "$DEPLOY_OUTPUT"
  fi
  echo ""
  echo "Recent logs:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" logs --tail=30 2>/dev/null || true
  exit 1
fi

echo "✓ Stack deployed"
echo ""

# ============================================
# HEALTH CHECK POLLING
# ============================================

# Wait for services to become healthy
echo "⏳ Waiting for services to become healthy (timeout: ${TIMEOUT}s)..."
ELAPSED=0
ALL_HEALTHY=false

while [ $ELAPSED -lt $TIMEOUT ]; do
  # Get container status as JSON
  STATUS_JSON=$(docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --format json 2>/dev/null || echo "[]")
  
  # Count total services
  TOTAL=$(echo "$STATUS_JSON" | jq -s 'length')
  
  # Count healthy/running services
  # Services with health checks: count as healthy
  # Services without health checks: count if running
  HEALTHY=$(echo "$STATUS_JSON" | jq -s '
    [.[] | select(
      (.Health == "healthy") or 
      (.Health == null and .State == "running")
    )] | length
  ')
  
  echo -ne "   Progress: $HEALTHY/$TOTAL services ready\r"
  
  # Check if all services are healthy/running
  if [ "$HEALTHY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo -ne "\n"
    ALL_HEALTHY=true
    break
  fi
  
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""

# ============================================
# STATUS REPORTING
# ============================================

# Report final status
echo "📊 Final Service Status:"
docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps

echo ""
if [ "$ALL_HEALTHY" = true ]; then
  echo "✅ All services healthy! Test PASSED"
  echo ""
  echo "Services:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --format "table {{.Service}}\t{{.Status}}"
  exit 0
else
  echo "❌ Timeout waiting for services. Test FAILED"
  echo ""
  echo "Service Status:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" ps --format "table {{.Service}}\t{{.Status}}"
  echo ""
  echo "Recent Logs:"
  docker compose -f "$STACK_FILE" --env-file "$TEST_ENV" logs --tail=30
  exit 1
fi



