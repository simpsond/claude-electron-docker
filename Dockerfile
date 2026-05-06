# syntax=docker/dockerfile:1.6
#
# Claude Desktop in Docker (PoC).
# See DESIGN.md for the rationale behind every decision in this file.
#
# Pinned to amd64 because the aaddrick .deb ships amd64 only.
# On Apple Silicon hosts this runs under Docker Desktop's amd64 emulation.
FROM --platform=linux/amd64 ubuntu:22.04

# .deb pin: aaddrick release v2.0.10+claude1.6259.0, pinned 2026-05-06.
# To update: visit https://github.com/aaddrick/claude-desktop-debian/releases,
# update both URL and SHA256 together, and rebuild.
ARG CLAUDE_DEB_URL=https://github.com/aaddrick/claude-desktop-debian/releases/download/v2.0.10%2Bclaude1.6259.0/claude-desktop_1.6259.0-2.0.10_amd64.deb
ARG CLAUDE_DEB_SHA256=04e1e5c4c89b09bdfd82b9ea6a1a7a26127b34bc5f94de68b62ad47aafa63d1b

# System packages, in commented groups so the purpose of each is obvious.
# DEBIAN_FRONTEND keeps tzdata and friends from prompting interactively.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        # Headless display stack
        xvfb \
        fluxbox \
        x11vnc \
        # Electron runtime libraries (the .deb declares many of these too; we
        # list explicitly as a safety net so missing libs surface at build time).
        libgtk-3-0 \
        libnss3 \
        libasound2 \
        libasound2-plugins \
        libxshmfence1 \
        libgbm1 \
        libdrm2 \
        libxkbfile1 \
        libsecret-1-0 \
        libxss1 \
        libxtst6 \
        # OAuth handoff browser support (Chrome itself installed in the next
        # RUN block from Google's apt repo — Ubuntu's `chromium` is a snap
        # redirect that does not work in Docker).
        xdg-utils \
        gnupg \
        # Clipboard bridge (X11 selection ownership)
        xclip \
        # Fonts so menus and chat bubbles do not render as blank rectangles
        fonts-liberation \
        fonts-noto-core \
        # Session bus (Electron quietly assumes one is present)
        dbus \
        # Process supervisor (PID 2 under tini)
        supervisor \
        # Locale package; en_US.UTF-8 generated below
        locales \
        # Triage and readiness tools
        procps \
        curl \
        ca-certificates \
        xdotool \
        x11-utils \
    && rm -rf /var/lib/apt/lists/*

# Google Chrome stable, the OAuth handoff browser.
# Key dearmored into /usr/share/keyrings/ and the source list line uses
# [signed-by=...] so this key is scoped to this single repo (a misissued
# key would not be trusted for any other apt source). The `command -v`
# check fails the build if Google ever renames the binary.
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/* \
    && command -v google-chrome-stable

# Generate en_US.UTF-8 so Electron's Intl machinery has a real locale to read.
RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# HOME is read by Electron, Chrome, and xdg-settings; supervisord under root
# does not always propagate it. ENV here gives every process a baseline.
ENV HOME=/root

# Route ALSA's default device to a null PCM. Electron's audio probe finds a
# "device", emits no errors, and continues. PulseAudio is deliberately not
# installed; PA probes fail fast at dlopen rather than hanging.
RUN printf 'pcm.!default {\n    type null\n}\nctl.!default {\n    type null\n}\n' > /etc/asound.conf

# Download, verify, install Claude Desktop.
# We use `apt-get install ./file.deb` (not `dpkg -i`) so apt resolves any
# dependencies the .deb declares. The `command -v` check fails the build at
# build time if an upstream rename/layout change moved the binary off PATH.
RUN curl -fsSL "$CLAUDE_DEB_URL" -o /tmp/claude-desktop.deb \
    && echo "$CLAUDE_DEB_SHA256  /tmp/claude-desktop.deb" | sha256sum -c - \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/claude-desktop.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/claude-desktop.deb \
    && command -v claude-desktop

# Defensive xdg-mime: route claude:// back to Claude Desktop. If the .deb
# already registers the handler, this is a no-op. `|| true` tolerates the
# .deb installing a differently-named .desktop file.
RUN xdg-mime default claude-desktop.desktop x-scheme-handler/claude || true

# Chrome launcher wrapper. Chrome refuses to start as root without
# --no-sandbox; --password-store=basic avoids libsecret hangs (no DBus
# secret service in the container); the GPU/IPC flags match start-claude.sh
# so the OAuth browser shares the same container-safe baseline.
RUN cat > /usr/local/bin/chrome-launcher <<'SCRIPT'
#!/bin/sh
exec /usr/bin/google-chrome-stable \
    --no-sandbox \
    --password-store=basic \
    --disable-gpu \
    --use-gl=swiftshader \
    --disable-dev-shm-usage \
    "$@"
SCRIPT
RUN chmod +x /usr/local/bin/chrome-launcher

# Custom .desktop file pointing at our launcher. start-claude.sh registers
# this as the default browser at runtime.
RUN cat > /usr/share/applications/chrome-launcher.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome (container-safe)
Exec=/usr/local/bin/chrome-launcher %U
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
DESKTOP

# Our supervisord config overwrites the stock top-level config rather than
# dropping a fragment into conf.d/. This makes the CMD path unambiguous and
# removes our dependency on the stock config's conf.d/*.conf include.
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY start-claude.sh /usr/local/bin/start-claude.sh
RUN chmod +x /usr/local/bin/start-claude.sh

EXPOSE 5901

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
