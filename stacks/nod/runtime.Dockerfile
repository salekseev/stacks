# Docker-socket allowlist proxy for the nod stack (stacks/nod.yaml, service
# `runtime`). Upstream bind-mounts docker-proxy.mjs from its checkout; Portainer
# Git deploy cannot resolve that relative path, so it is baked in here.
# Build context is upstream's deployment/self-host, not its repository root:
# upstream's root .dockerignore excludes docker-proxy.mjs.
# Base image and digest match upstream's `runtime` service.
FROM node:24.21.0-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20
COPY docker-proxy.mjs /app/docker-proxy.mjs
CMD ["node", "/app/docker-proxy.mjs"]
