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

## Verifying the inspector bridge

This is a one-shot sanity check that the SIGUSR1 / Node-inspector bridge actually works against a running container — useful when you want confidence that the path documented in `DESIGN.md` Section 4 is live before pointing a real harness at it.

```bash
PID=$(docker exec claude-desktop sh -c 'ps -eo pid,args --no-headers | awk "/electron.*app\\.asar/ && !/--type=/ {print \$1; exit}"')
docker exec claude-desktop kill -SIGUSR1 "$PID"
docker exec claude-desktop curl -sS http://127.0.0.1:9229/json/version
```

Expected response (the version string varies by Electron build):

```json
{
  "Browser": "node.js/v24.15.0",
  "Protocol-Version": "1.1"
}
```

If you get that JSON back, the gate is bypassed and the inspector is listening. What each piece does, and why it's there:

- **Finding the main PID.** `ps` lists every Electron process — the main process, plus a fan-out of `--type=zygote`, `--type=renderer`, `--type=gpu-process`, and `--type=utility` children. Only the main is a Node context that responds to `SIGUSR1`; sending the signal to a child renderer does nothing useful. The awk filter `electron.*app.asar` matches every Electron-with-app, and `!/--type=/` excludes the children. The first remaining match is the main.
- **Sending `SIGUSR1`.** This runs `inspector.open()` inside the main process and brings the Node inspector up on port 9229. The same code path is reachable interactively through the in-app `Developer → Enable Main Process Debugger` menu, which is the upstream signal that this route is tolerated, not an exploit.
- **Probing `/json/version`.** A standard Node-inspector HTTP endpoint that returns the protocol identity without needing a WebSocket client. If the JSON shape above comes back, you've proven that argv-time gating did not interfere and that the inspector is reachable.

A few things worth knowing before you build automation on this:

- The compose port map does **not** expose 9229 to the host today — the probe above works because `docker exec` runs *inside* the container's network namespace. If you want to attach a host-side CDP client, add `127.0.0.1:9229:9229` to the compose `ports:` and rebuild. Keep the localhost binding; the inspector has no authentication.
- Playwright's `chromium.connectOverCDP` will **not** work even after the inspector is up: it injects `--remote-debugging-port` into argv, which trips the same gate. Use a raw WebSocket client (e.g., `chrome-remote-interface`) and connect to the `webSocketDebuggerUrl` from `/json/list`.
- Once attached, evaluate JS in the main process via `Runtime.evaluate`; from there `webContents.getAllWebContents()` enumerates the renderers — `BrowserWindow.getAllWindows()` returns 0 in this build because `frame-fix-wrapper` substitutes the class. `DESIGN.md` Section 4 records both this and the `awaitPromise + returnByValue` Promise-empty-object gotcha so future-you doesn't rediscover them.

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
