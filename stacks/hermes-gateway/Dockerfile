# Hermes gateway with the 1Password CLI and the Hindsight client baked in.
# - op: hermes-gateway runs `op` itself (secrets.onepassword resolves op:// references in the gateway
#   process) and Hermes never installs it, so it is copied from the official image.
# - hindsight-client: the hindsight memory plugin (/opt/data/plugins/hindsight, pip_dependencies
#   hindsight-client>=0.10.1) imports it, and the v0.23 image no longer ships it. HERMES_DISABLE_LAZY_INSTALLS=1
#   and a root-owned venv stop the plugin installing it at runtime, so it is installed here. The base
#   image sets a 3-day uv release cooldown, so the newest allowed release is pinned, not the newest one;
#   the Hindsight server (stacks/hindsight.yaml) is 1.x and the client is the same major.
# Published as ghcr.io/salekseev/hermes-gateway:<hermes tag>-op<op version>-hs<client version> by
# .github/workflows/hermes-gateway-image.yml; all three versions are read from the lines below.
# op needs session files in TMPDIR to be mode 600: see stacks/AGENTS.md (ACL on cache/scratch).
FROM nousresearch/hermes-agent:v0.23.4
COPY --from=1password/op:2.42.0 /usr/local/bin/op /usr/local/bin/op
RUN uv="$(ls /opt/hermes/tools/uv-*/uv | head -n1)" \
 && "$uv" pip install --no-cache --python /opt/hermes/.venv/bin/python hindsight-client==1.2.3
