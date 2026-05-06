#!/bin/sh
# Wrapper that prepares the environment and execs Claude Desktop.
# See DESIGN.md Section 3 for why each step exists.

set -eu

# HOME defensively, on top of Dockerfile ENV and supervisord environment=.
export HOME="${HOME:-/root}"
export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-session-bus

# Wait for X to be ready (xdpyinfo answers). Up to 60 attempts at 0.5s = 30s.
attempts=0
while ! xdpyinfo -display :0 >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
        echo "ERROR: Xvfb did not become ready within 30 seconds" >&2
        exit 1
    fi
    sleep 0.5
done

# Wait for the session DBus to accept connections (Ping responds).
# The socket file existing is not the same as the daemon being ready.
attempts=0
while ! dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
        --print-reply / org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
        echo "ERROR: DBus session bus did not become ready within 30 seconds" >&2
        exit 1
    fi
    sleep 0.5
done

# Register our container-safe Chromium launcher (not the system Chromium) as
# the default browser. This is what Claude Desktop's xdg-open call invokes
# during the OAuth login flow.
xdg-settings set default-web-browser chromium-launcher.desktop

# Hand off to Claude Desktop with the full container-safe flag set.
# --no-sandbox: container is the isolation boundary; Chromium's sandbox
#   does not work in this shape.
# --password-store=basic: no DBus secret service in the container; libsecret
#   would otherwise hang on token storage.
# --disable-gpu, --use-gl=swiftshader: no GPU; software rendering.
# --disable-dev-shm-usage: belt-and-suspenders alongside compose shm_size=1g.
exec claude-desktop \
    --no-sandbox \
    --password-store=basic \
    --disable-gpu \
    --use-gl=swiftshader \
    --disable-dev-shm-usage
