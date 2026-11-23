# codex-lb 1.24.0 plus upstream PR #2692 (soju06/codex-lb), which is open and in
# no release: "fix(chat): preserve non-strict tool defaults during conversion".
#
# Why: codex-lb converts Chat Completions requests to the Responses API. A chat
# tool with `strict` omitted means non-strict, but the omission was passed
# through and Responses treats it as strict. Tools whose schema cannot be
# compiled strictly (nod's `pay` tool: allOf + anyOf) then fail the whole
# request with 400 invalid_json_schema. Upstream issue: soju06/codex-lb#2691.
#
# Only app/core/openai/chat_requests.py changes; everything else is the
# published image. `patch` exits non-zero if the hunks do not apply, so a base
# bump that already contains the fix fails the build: drop this Dockerfile and
# point stacks/codex-lb.yaml back at ghcr.io/soju06/codex-lb then.
#
# Built by .github/workflows/codex-lb-image.yml as
# ghcr.io/salekseev/codex-lb:<base version>-pr2692.

FROM ghcr.io/soju06/codex-lb:1.24.0@sha256:ba5598aaa70f7acf74a958139037604621ec2582a7fb5fe1e870f08bece807d6 AS base

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS patched
COPY --from=base /app/app/core/openai/chat_requests.py /src/app/core/openai/chat_requests.py
COPY patches/2692-chat-tool-strict-default.patch /src/fix.patch
RUN apk add --no-cache patch && cd /src && patch -p1 < fix.patch

FROM base
COPY --from=patched /src/app/core/openai/chat_requests.py /app/app/core/openai/chat_requests.py
