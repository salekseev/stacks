# Docker-socket allowlist proxy for the nod stack (stacks/nod.yaml, service
# `runtime`). Upstream bind-mounts docker-proxy.mjs from its checkout; Portainer
# Git deploy cannot resolve that relative path, so it is baked in here.
# Build context is upstream's deployment/self-host, not its repository root:
# upstream's root .dockerignore excludes docker-proxy.mjs.
#
# BASE is the image of upstream's own `runtime` service, read from its
# compose.yaml by .github/workflows/nod-images.yml. It is not pinned here on
# purpose: upstream chooses the node version its proxy runs on, and a copy of
# that pin would drift and be bumped by Renovate independently of nod.
ARG BASE
FROM ${BASE}
COPY docker-proxy.mjs /app/docker-proxy.mjs
CMD ["node", "/app/docker-proxy.mjs"]
