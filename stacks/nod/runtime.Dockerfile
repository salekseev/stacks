# Docker-socket allowlist proxy for the nod stack (stacks/nod.yaml, service
# `runtime`). Upstream bind-mounts docker-proxy.mjs from its checkout; Portainer
# Git deploy cannot resolve that relative path, so it is baked in here.
# Build context is upstream's deployment/self-host, not its repository root:
# upstream's root .dockerignore excludes docker-proxy.mjs.
# Base image and digest match upstream's `runtime` service.
FROM node:26.13.1-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1
COPY docker-proxy.mjs /app/docker-proxy.mjs
CMD ["node", "/app/docker-proxy.mjs"]
