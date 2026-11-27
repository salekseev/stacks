# Hermes Bot Screen sandbox with Google Chrome as its browser.
# The upstream sandbox ships only Playwright's Chromium (/opt/playwright). In sandbox placement Hermes
# ignores browser.executable_path and always launches the first
# $PLAYWRIGHT_BROWSERS_PATH/chromium-*/chrome-linux*/chrome (tools/bot_desktop/sandbox_host.py), so
# Chrome is installed from Google's .deb and that path is replaced by a wrapper that execs it. The
# original binary is kept next to it as chrome.orig. Hermes adds --no-sandbox itself in containers.
# Published as ghcr.io/salekseev/hermes-sandbox:<base tag>-chrome by .github/workflows/hermes-sandbox-image.yml.
# Chrome is whatever "stable" is at build time (amd64 only: Google ships no Linux arm64 Chrome).
FROM nousresearch/hermes-sandbox:v0.23.4-desktop

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
 && apt-get install -y --no-install-recommends /tmp/chrome.deb \
 && rm -f /tmp/chrome.deb \
 && rm -rf /var/lib/apt/lists/* \
 && google-chrome-stable --version \
 && set -- /opt/playwright/chromium-*/chrome-linux*/chrome \
 && test -x "$1" \
 && for c in "$@"; do \
      mv "$c" "$c.orig" \
      && printf '#!/bin/sh\nexec /usr/bin/google-chrome-stable "$@"\n' > "$c" \
      && chmod 755 "$c"; \
    done
