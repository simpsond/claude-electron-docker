# Claude Desktop in Docker (PoC)

Runs the [aaddrick community Linux build](https://github.com/aaddrick/claude-desktop-debian) of Claude Desktop inside a container, with VNC for human attach-and-use. This is a proof-of-concept — see `DESIGN.md` for what it is, what it isn't, and why each piece is there.

## Quick start

```bash
docker compose up --build
```

Connect a VNC client to `localhost:5901`. No password.

You should see Claude Desktop's window. Log in (TOTP-based 2FA only — passkey will not work over VNC), and use it normally. Remote MCP servers work via the container's outbound network.

## Stopping

```bash
docker compose down
```

The container has no persistent volumes; every run starts from a fresh login state.

## Network exposure

The compose file binds the VNC port to `127.0.0.1` only. To reach the container from another machine, use SSH port forwarding:

```bash
ssh -L 5901:localhost:5901 user@docker-host
```

Do not change the port binding to `0.0.0.0`. The VNC server runs without authentication; direct exposure would let anyone with network access drive a logged-in Claude session.

Note: Claude Desktop blocks `--remote-debugging-port` at startup (Anthropic-signed token required). Automated harness access uses the upstream-documented runtime workaround instead — `SIGUSR1` to the main process opens the Node inspector on port 9229. See `DESIGN.md` Section 4.

## Triage

Per-daemon logs are written to `/tmp/` inside the container:

```bash
docker exec claude-desktop tail -f /tmp/claude-desktop.err
docker exec claude-desktop tail -f /tmp/x11vnc.err
docker exec claude-desktop tail -f /tmp/xvfb.err
docker exec claude-desktop supervisorctl status
```

## Updating the .deb pin

The `CLAUDE_DEB_URL` and `CLAUDE_DEB_SHA256` build args are pinned in the Dockerfile. To update: pick a release on the [aaddrick releases page](https://github.com/aaddrick/claude-desktop-debian/releases), update both values together (the SHA256 is computed with `curl -L "$URL" | sha256sum`), and rebuild. The build verifies the hash and fails loudly on a mismatch.
