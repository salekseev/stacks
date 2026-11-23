# Stage appended to upstream's Dockerfile.browser by
# .github/workflows/nod-images.yml; it is not buildable on its own (`browser`
# is upstream's stage). Swaps the browser Nod drives from Debian's chromium to
# Google Chrome stable, which is what the top engines in the stealth benchmark
# behind follow-up (2) of docs/superpowers/specs/2026-11-21-nod-stack-design.md
# run. Nod launches whatever chromium.sh executes, so only the wrapper changes.
#
# Not pinned: Google's repo serves only the current stable. Chrome is what was
# current when this layer was last built, and the build cache keeps the layer
# until upstream's layers change, i.e. until the next nod release.
# Debian's chromium stays installed, unused.

FROM browser AS chrome
USER root
ADD --chmod=644 https://dl.google.com/linux/linux_signing_key.pub /etc/apt/keyrings/google-chrome.asc
RUN echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main' \
      > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*
RUN printf '#!/bin/sh\nexec /usr/bin/google-chrome-stable "$@" 2>/dev/null\n' \
      > /app/src/providers/container-browser/chromium.sh
USER node
