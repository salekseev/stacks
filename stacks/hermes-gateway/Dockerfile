# Hermes gateway with the 1Password CLI baked in.
# hermes-gateway runs `op` itself (secrets.onepassword resolves op:// references in the gateway
# process) and Hermes never installs it, so it is copied from the official image instead of being
# shared through an init container and a volume.
# Published as ghcr.io/salekseev/hermes-gateway:<hermes tag>-op<op version> by
# .github/workflows/hermes-gateway-image.yml; both versions are read from the lines below.
# op needs session files in TMPDIR to be mode 600: see stacks/AGENTS.md (ACL on cache/scratch).
FROM nousresearch/hermes-agent:v0.23.4
COPY --from=1password/op:2.42.0 /usr/local/bin/op /usr/local/bin/op
