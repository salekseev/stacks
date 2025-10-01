#!/bin/bash

# This script validates a Docker Compose stack file using `docker-compose config`.

# Exit immediately if a command exits with a non-zero status.
set -e

# Check if a stack name is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <stack-name>"
  exit 1
fi

STACK_NAME="$1"
STACK_FILE="stacks/${STACK_NAME}.yaml"

# Check if the stack file exists
if [ ! -f "$STACK_FILE" ]; then
  echo "Error: Stack file not found at ${STACK_FILE}"
  exit 1
fi

# Validate the stack file
echo "Validating ${STACK_FILE}..."
if docker compose -f "${STACK_FILE}" --env-file stacks/stack.env config --quiet; then
  echo "✓ Validation successful for ${STACK_FILE}"
  echo ""
  echo "Services:"
  docker compose -f "${STACK_FILE}" --env-file stacks/stack.env config --services | sort
  echo ""
  echo "Networks:"
  docker compose -f "${STACK_FILE}" --env-file stacks/stack.env config | grep -A 2 "^networks:"
else
  echo "✗ Validation failed for ${STACK_FILE}"
  exit 1
fi
