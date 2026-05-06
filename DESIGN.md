# Claude Desktop in Docker — Design Doc

## Section 0: Problem Statement

### Who this is for

Engineers on our team who test MCP servers against Claude Desktop. They already have a working end-to-end harness — built on proprietary UI orchestration tooling — that runs against Claude Desktop inside a GCP VM, including OAuth login and full UI interaction. That harness works. It is not what this document is about.

### The gap we want to close

Our broader testing infrastructure standardizes on Docker containers as the unit of test isolation: tests run inside containers, scheduled and observed by our existing CI tooling. The Claude Desktop side of our MCP testing currently sits outside that standard path — it runs in a GCP VM rather than a container. That divergence means it doesn't benefit from the affordances the rest of our test platform provides: scheduling, parallel execution, hermetic per-run state, log and artifact capture, and the same operational tooling used by every other test we run.

We want to bring Claude Desktop testing onto the well-lit path: same container model, same harness story, same operational shape as everything else we test.

### Why the Electron app specifically

We are explicitly targeting the Electron build of Claude Desktop — not the web app at claude.ai, and not Claude Code. The MCP behavior we care about is what users of Claude Desktop actually experience, which is mediated by the Electron app's process lifecycle and its MCP client implementation. The web app and Claude Code have different MCP surfaces; substituting either would make our results uninformative about the product surface our users actually use.

Because Anthropic does not ship a Linux build of Claude Desktop, we use the community-maintained `aaddrick/claude-desktop-debian` port. We accept that the port is not a perfect proxy for the macOS and Windows builds our users run. For orchestration-lifecycle questions — how MCP servers are launched, supervised, and torn down — it is close enough to give us useful signal. For platform-specific UI or OS-integration assertions, it would not be, and we would not draw those conclusions from it.

### What this PoC delivers

A Dockerfile and `docker-compose.yml` that bring up Claude Desktop (Electron) inside a Linux container, with VNC exposed so a human can attach, log in, and use the app interactively — including connecting to remote MCP servers.

That is the entire scope of this document. It is **not** integrated with our existing test harness, **not** running unattended, **not** in CI, and **not** automating login. It is also **not** validating the orchestration lifecycle of local stdio MCP servers — how Claude Desktop launches, supervises, or tears them down. That question is exercised today by our existing GCP-VM tests; migrating those tests onto this container is a follow-on step. The remote MCP server in the success criteria below is a sanity check that Claude Desktop can complete a tool-call round trip from inside the container, not a validation of MCP process management. Those are all deliberate next steps; they are not part of this artifact.

The purpose of starting here is to surface and document what it actually takes to run this Electron app under headless Linux — shared-library dependencies, the headless display stack, and the small but nontrivial set of services Electron quietly assumes are present (a session DBus, fonts, sufficient shared memory). The findings from this PoC carry forward into every automated, hermetic, CI-driven version that follows.

### How we know we're done

An engineer on our team can:

1. Check out this repository on a Mac with Docker installed.
2. Run `docker compose up`.
3. Connect a VNC client to `localhost:5901`.
4. See the Claude Desktop window render.
5. Log in to Claude.
6. Send a prompt, receive a reply, and exercise a remote MCP server.

If all six steps work, the PoC has met its goal. If any step fails, the failure tells us what is missing — and closing that gap is the work.

## Section 1: How We Build It

### The mental model

A Docker container is a Linux machine in a box. It shares the host's kernel but has its own filesystem, processes, and network. We are going to put Claude Desktop inside one of those boxes and make it usable by a human sitting outside the box.

The complication is that Claude Desktop is a graphical app. It expects a screen, a window manager, fonts, and a few quiet background services that come for free on any normal Linux desktop. A bare container has none of that. So our job is to assemble the smallest plausible set of parts that convince Claude Desktop it is running on a real desktop, and that let a human see and click on what it draws.

### The parts

**Claude Desktop itself.** Installed from the community Debian package, `aaddrick/claude-desktop-debian`. This is the thing under test; every other piece exists to support it. We launch it with the `--no-sandbox` flag because Chromium's built-in sandbox does not work well inside a container, and the container is itself the isolation boundary we rely on.

**A fake screen** (`Xvfb`). Stands in for a physical monitor. Anything Claude Desktop wants to draw, it draws into memory inside the container instead of onto pixels on real glass. Without this, the app cannot start at all.

**A window manager** (`fluxbox`). A tiny program that decides where the Claude Desktop window goes on the fake screen, draws a border around it, and handles moving and resizing. Most Electron apps misbehave or fail to paint at all without one running, even if there is only one window in the entire session.

**A VNC server** (`x11vnc`). Watches the fake screen and streams a live picture of it over the network. A VNC client running on the engineer's Mac connects to that stream, shows them what the fake screen would have shown if it had been real, and forwards their mouse and keyboard back into the container.

**A web browser inside the container** (Chromium). When the user clicks "log in" inside Claude Desktop, the app hands the OAuth flow off to whatever the system has registered as the default browser. The container needs an actual browser available to receive that hand-off. Without one, the login button does nothing visible.

**A clipboard bridge** (`xclip`, plus the right flag on the VNC server). When the engineer pastes an email address or a 2FA code from their Mac into the VNC window, the text needs to travel through the VNC protocol and land in Claude Desktop's input field. This is the small piece of plumbing that makes that work. Without it, characters have to be typed by hand through the VNC keystroke channel, which is slow and error-prone.

**Background services Electron quietly assumes are present.** A session-level DBus daemon, which is the standard way Linux desktop apps coordinate with the rest of the desktop. A usable set of fonts, so menus and chat text do not render as blank rectangles. Enough shared memory for the Electron app's rendering process to operate, configured at the compose level via `shm_size`. None of these are visible to the user directly; all of them matter to whether the app starts cleanly.

**A small process supervisor** (`supervisord`). The container has several little daemons that need to be running at the same time — the fake screen, the window manager, the VNC server, the DBus daemon, and Claude Desktop itself. supervisord starts them in the right order, keeps them alive, and gives the container a single foreground process to "be," which is what keeps it running long enough for a human to attach to it.

### How the pieces come together

When the container starts:

1. supervisord wakes up first and becomes the long-lived process the container is built around.
2. It starts the fake screen.
3. It starts the session DBus.
4. It starts the window manager on the fake screen.
5. It starts the VNC server, pointed at the fake screen, with clipboard sharing enabled.
6. It starts Claude Desktop, which draws its window onto the fake screen.

At this point the container is sitting there with Claude Desktop running on a screen no human has yet seen. One port — 5901 — is exposed to the host. An engineer opens a VNC client on their Mac, connects to `localhost:5901`, and sees the Claude Desktop window. They click "log in," Chromium opens inside the container to handle the OAuth redirect, they finish logging in, and they start using the app.

When they are done, `docker compose down` discards the container. Because we are not persisting anything to disk, the next run starts from scratch — no leftover login session, no cached settings, no surprises carried over from the last run.

### How this fits in our ecosystem

This PoC produces two artifacts: a Dockerfile and a compose file. Neither of them knows anything about our broader test platform yet. That is on purpose.

Where this is going: our existing test infrastructure already runs containers in GCP, with its own scheduling, log capture, artifact storage, and UI automation tooling. The Claude Desktop testing we do today bypasses that infrastructure and runs in a dedicated VM. The container we build here is the building block that lets us bring those tests onto the same path as everything else we test — same orchestration, same observability, same operational shape.

This document does not cover that integration. It covers the predecessor: proving the building block exists and behaves.

## Section 2: Alternatives We Considered

### Use the web app at claude.ai instead of Claude Desktop

The web app runs on any operating system, in any browser, with no Electron involved and no community port to worry about. For many use cases it would be the simpler choice. We ruled it out because the MCP behavior we want to test is the one Claude Desktop users actually experience, and the Desktop app's MCP surface is genuinely different from the web app's. Testing the web app would give us answers that say nothing about whether a Claude Desktop user gets the same outcome.

### Use Claude Code instead

Claude Code is officially supported on Linux, ships from Anthropic directly, and would let us skip the community-port question entirely. It is also a different product, with a different MCP client, used in a different way. The same reasoning that ruled out the web app applies: it would not tell us what we need to know about Claude Desktop.

### Install Claude Desktop natively on the host

The community Debian package installs cleanly on Debian or Ubuntu, and on a developer's own machine that would be the path of least resistance. We ruled it out because our broader test infrastructure runs every test inside a Docker container, and the entire point of this work is to bring Claude Desktop testing onto that same well-lit path. A native install solves a different problem than the one we have.

### Forward an X11 or Wayland display from the host instead of running a VNC server

If the host were a Linux desktop, we could mount its display socket into the container and let Claude Desktop draw onto the host's real screen. That arrangement is meaningfully simpler than the fake-screen-plus-VNC-server one we landed on, and on a Linux developer workstation it would be the right answer. We ruled it out because the eventual destination for this work is GCP, where there is no host display to forward to. Designing around display forwarding now would force a rewrite the moment we leave a developer's Mac — and the Mac itself is not a Linux desktop anyway. Docker on Mac runs a hidden Linux virtual machine with no display of its own, so display forwarding is not even available there.

### Browser-based VNC (noVNC and websockify)

The first sketch of this project exposed VNC through a web page on port 6080. The appeal is that anyone with a browser can open the URL with no client software to install. The cost is that noVNC and the websockify bridge that supports it are the heaviest pieces of the stack, and our audience is a small team of engineers who already have VNC clients on their laptops. Plain VNC on port 5901 is what we kept; the browser layer was carrying weight it did not earn.

### A persistent volume for Claude's login session

The original sketch mounted a named volume so that login state survived across container restarts. For day-to-day human use of the app that would be a real convenience. For a PoC focused on bring-up it is actively unhelpful: stale state from a previous run can mask a real failure in the current run, and hermetic per-run state is what our test infrastructure wants long-term anyway. We dropped the volume.

### Run no window manager at all

Claude Desktop is the only graphical app in the container, and it always opens just one window. We considered skipping the window manager entirely. We kept it because Electron apps often fail to paint properly without a window manager present — they wait for window-management signals that never arrive — and "is it the missing window manager?" is exactly the kind of question we do not want to spend time chasing during a first bring-up. A tiny window manager removes a variable for a few hundred kilobytes.

### A single entrypoint script instead of a process supervisor

For containers whose job is to run one test and exit, the cleanest pattern is a single script as the foreground process: if the script exits, the container exits, and the exit code is the test result. A process supervisor like the one we are using is built for the opposite case — keeping services alive indefinitely. We chose the supervisor here because the PoC container needs to stay running while a human attaches to it through VNC, and we want any of the little daemons that happen to crash to be restarted rather than silently absent. When we move from "human attaches and uses the app" to "automated test runs and exits," the entrypoint-script pattern will likely become the right one. That is a future change, not a change for this document.

## Section 3: Implementation Plan

This is a new repository. Every file listed below is a creation, not a modification of an existing file.

### Files we will create

| File | Purpose |
|------|---------|
| `Dockerfile` | The image recipe. Installs Claude Desktop, the headless display stack, the VNC server, the OAuth-handoff browser, the clipboard bridge, the session bus, fonts, and the process supervisor. |
| `docker-compose.yml` | The service definition. Builds the image, exposes the VNC port to localhost only, sets shared-memory size. |
| `supervisord.conf` | The supervisor's program list. Tells the supervisor which daemons to run, in what rough order, and where each one's logs land. |
| `start-claude.sh` | A small wrapper that sets the environment Claude Desktop needs (display, session bus, default browser) and launches the app with the flags we want. |
| `README.md` | User-facing instructions for cloning, building, running, and triaging the container. |
| `.dockerignore` | Keeps the build context lean and prevents stray local files from ending up inside the image. |
| `.gitignore` | Keeps stray local files out of the repository itself. |
| `DESIGN.md` | This document. Already exists; listed here for completeness. |

Eight files, in one directory, with no subdirectories, no submodules, no generated artifacts, and no scripts that build other scripts.

### File-by-file rationale

#### `Dockerfile`

The recipe that produces the container image. In order:

- Starts from `debian:bookworm-slim`, pinned to `linux/amd64` via `FROM --platform=linux/amd64`. Debian rather than Alpine because Electron apps depend on glibc, and Alpine uses musl. The slim variant rather than the full Debian image because we want a small starting point and will install only what we need. The platform pin exists because the aaddrick port ships an amd64 `.deb`; on Apple Silicon hosts the image will run under Docker Desktop's amd64 emulation, with a performance hit we are explicitly accepting (see Section 4).
- Installs system packages with `apt-get install --no-install-recommends` and removes `/var/lib/apt/lists/` in the same `RUN` layer, so the image stays close to the slim baseline that we picked the slim image for in the first place. The packages fall into clearly commented groups so that a future engineer reading the Dockerfile can see at a glance which packages serve which purpose:
  - **Headless display stack** — `xvfb`, `fluxbox`, `x11vnc`. Provides the fake screen, the window manager, and the VNC server described in Section 1.
  - **Electron runtime dependencies** — the libraries the Electron binary will refuse to start without. We commit to an explicit set: `libgtk-3-0`, `libnss3`, `libasound2`, `libasound2-plugins`, `libxshmfence1`, `libgbm1`, `libdrm2`, `libxkbfile1`, `libsecret-1-0`, `libxss1`, `libxtst6`. The `.deb` we install will declare some of these as apt dependencies; listing them explicitly is a safety net. `libasound2-plugins` is included so we can route ALSA's default device to a `null` PCM via `/etc/asound.conf` (written by the Dockerfile), so Electron's audio probe finds a "device" and stops emitting errors. PulseAudio is deliberately not installed — without `libpulse.so` available, Electron's PA probe fails fast at `dlopen` rather than hanging.
  - **The OAuth handoff browser** — `chromium` plus `xdg-utils`. Required because Claude Desktop's login flow opens the OAuth URL in the system default browser; without an actual browser present, the login button does nothing visible. We cannot use the system Chromium `.desktop` file as-is: Chromium refuses to start as root without `--no-sandbox`, and there is no functioning DBus secret service in the container for it to use for credential storage. The Dockerfile creates a small wrapper at `/usr/local/bin/chromium-launcher` and a corresponding `/usr/share/applications/chromium-launcher.desktop` entry, both inlined via heredoc. The exact contents:

    Wrapper script (`/usr/local/bin/chromium-launcher`, `chmod +x`):

    ```sh
    #!/bin/sh
    exec /usr/bin/chromium --no-sandbox --password-store=basic "$@"
    ```

    Desktop entry (`/usr/share/applications/chromium-launcher.desktop`):

    ```ini
    [Desktop Entry]
    Version=1.0
    Type=Application
    Name=Chromium (container-safe)
    Exec=/usr/local/bin/chromium-launcher %U
    Terminal=false
    Categories=Network;WebBrowser;
    MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
    ```

    `start-claude.sh` registers this launcher (not the system Chromium) as the default browser at runtime via `xdg-settings`.
  - **The clipboard bridge** — `xclip`. Required because VNC's clipboard sync needs an X11-side helper to move text between the VNC channel and applications running on the fake screen.
  - **Fonts** — `fonts-liberation`, `fonts-noto-core`. Required because the slim base image ships almost no fonts and unlabelled UI renders as blank rectangles.
  - **Session bus** — the `dbus` package, providing `dbus-daemon`. Required because Electron apps quietly assume a session bus is present and behave erratically without one.
  - **Process supervisor** — `supervisor`.
  - **Locale** — `locales`. The slim base image ships only the C locale, which Electron's Intl machinery handles awkwardly. After installing the package, the Dockerfile runs `sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen` to enable and generate `en_US.UTF-8`, then sets both `ENV LANG=en_US.UTF-8` and `ENV LC_ALL=en_US.UTF-8` so every process started in the container inherits a fully-defined locale.
  - **Triage and readiness tools** — `procps`, `curl`, `xdotool`, `x11-utils`. Small conveniences that make `docker exec` debugging less painful when something goes wrong during bring-up. `x11-utils` specifically provides `xdpyinfo`, which `start-claude.sh` uses to poll for X readiness; `dbus-send` (used for the DBus readiness check) is already provided by the `dbus` package above.
- Downloads, verifies, and installs the aaddrick `claude-desktop-debian` package. The Dockerfile pins two build arguments with concrete defaults filled in inline at first authoring:
  - `CLAUDE_DEB_URL` — the upstream tagged release artifact URL on the aaddrick GitHub releases page (of the form `https://github.com/aaddrick/claude-desktop-debian/releases/download/<tag>/<filename>.deb`). Pinned to a specific release tag, not a `latest` link, so the build is reproducible. The implementer fills the default in by visiting the releases page and copying the URL of the most recent stable release; a comment immediately above the `ARG` line records the upstream tag and the date it was pinned.
  - `CLAUDE_DEB_SHA256` — the expected SHA256 of that exact `.deb`. Computed once at first authoring with `curl -L "$CLAUDE_DEB_URL" | sha256sum` and pasted inline as the `ARG` default. Updating the URL means recomputing the SHA256 in the same change.

  The install procedure is: `curl -fsSL "$CLAUDE_DEB_URL" -o /tmp/claude-desktop.deb`, then `echo "$CLAUDE_DEB_SHA256  /tmp/claude-desktop.deb" | sha256sum -c -` to verify the hash, then `apt-get update && apt-get install -y --no-install-recommends /tmp/claude-desktop.deb` to install. We use `apt-get install` against the local `.deb` rather than `dpkg -i` because the `.deb` declares apt dependencies that `dpkg` cannot resolve on its own; `apt-get install ./file.deb` resolves and installs those dependencies in the same step. After the install, the Dockerfile runs `command -v claude-desktop` as its own `RUN` step so that an upstream rename or layout change fails the build at build time rather than at first VNC. A mismatch on either the SHA256 or the binary-name check fails the build loudly before anything else proceeds.

  We do **not** include a fallback mirror in the PoC. A team-owned mirror would require an internal artifact storage decision (which GCS bucket, who owns it, who has write access to populate it) that is not in scope for this artifact and is not blocking for a single-developer PoC running on a Mac. If the upstream URL becomes unreachable during a build, the build fails loudly and the operator's recourse is to pin a different release. Adding a `CLAUDE_DEB_URL_FALLBACK` build arg is a small additive change to make later when ops designates a mirror, and is explicitly noted as a follow-on in Section 4.
- Sets `ENV HOME=/root`. supervisord under root does not reliably propagate `HOME` to child programs, and Electron, Chromium, and `xdg-settings` all break in confusing ways without `HOME`. Setting it at the image level establishes a baseline that every process inherits.
- Copies `supervisord.conf` to `/etc/supervisor/supervisord.conf`, **overwriting** the stock Debian top-level config rather than dropping a fragment into `/etc/supervisor/conf.d/`. This makes our config self-contained: the CMD's path reference is unambiguous, and we do not rely on the stock config's `conf.d/*.conf` include behavior. Copies `start-claude.sh` to `/usr/local/bin/start-claude.sh` and the Chromium wrapper described above to `/usr/local/bin/chromium-launcher`; both get `chmod +x`. Copies the `.desktop` entry to `/usr/share/applications/chromium-launcher.desktop`.
- Exposes port 5901 (VNC).
- Sets the container's `CMD` to `["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]`. `-n` keeps supervisord in the foreground (otherwise it daemonizes and the container exits); `-c` points at the configuration file we copied in. Combined with `init: true` in compose, this puts tini at PID 1 and supervisord at PID 2 — supervisord is the conceptual "long-lived process the container is built around," even if not literally PID 1.

Every package group and every non-obvious flag gets an inline comment explaining why it is there. The Dockerfile is a learning artifact; the comments are part of the deliverable.

#### `docker-compose.yml`

The service definition. It does very little, deliberately:

- Names the service `claude-desktop` and points it at the local `Dockerfile`.
- Maps port 5901 from the container to `127.0.0.1:5901` on the host. Localhost-only on purpose — VNC without a password should never be reachable from anywhere but the host the container is running on. Anyone wanting to reach it from another machine should use an SSH tunnel, as documented in the README.
- Sets `shm_size: 1g`, because Chromium's renderer process inside Electron will crash with the default 64 megabytes of `/dev/shm`.
- Sets `init: true`. Docker provides `tini` as PID 1 inside the container, with supervisord running underneath it. tini handles SIGTERM forwarding and zombie reaping cleanly, which removes a class of "weird shutdown" bugs that supervisord-as-PID-1 is known to cause. The cost is one line of compose configuration; we are paying it.
- Sets `mem_limit: 4g`. Electron with Chromium loaded plus Claude Desktop's renderer can comfortably use two gigabytes; on Docker Desktop for Mac, an unbounded container can grind the host VM. The four-gigabyte cap is generous enough to accommodate the app under normal usage including a Chromium-mediated login flow, and small enough to fail fast if the app starts leaking. The number is empirical rather than principled; it is one line to change if it turns out to be too tight or too loose.
- Mounts no volumes. Hermetic per-run state is a goal of this PoC, and a persistent config volume would work directly against that.
- Sets no environment variables. The fake-screen geometry and the VNC port are baked into the image at sensible defaults; nothing about the running container needs compose-time configuration for the PoC to work.

A comment block at the top of the file explains each non-default setting in one line each.

#### `supervisord.conf`

Tells the supervisor which daemons to run and in what order. Each daemon is its own program block, with an explicit `priority` so startup order is deterministic. Lower priority starts earlier.

- **`xvfb`** (`priority=100`) — starts the fake screen with the exact command `Xvfb :0 -screen 0 1440x900x24 -dpi 96 -nolisten tcp`. Display `:0`, geometry `1440x900x24`, DPI 96, no TCP listener. Every graphical thing depends on this being up. The geometry and depth are committed numbers: 1440x900 is generous enough for the Claude window without making VNC bandwidth painful, 24-bit color matches what the app expects, and 96 DPI is what produces correctly-scaled text in Electron apps. `-nolisten tcp` because we have no use for X-over-TCP and exposing it would be a needless attack surface.
- **`dbus`** (`priority=200`) — starts a session DBus daemon with the exact command `dbus-daemon --session --nofork --address=unix:path=/tmp/dbus-session-bus`. `--session` gives us a session bus rather than a system bus; `--nofork` keeps the daemon in the foreground so supervisord can track it; `--address` commits the socket path explicitly rather than letting the daemon pick a transient one. `start-claude.sh` exports the matching `DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-session-bus`; both files name the same exact path so the dependency cannot drift silently.
- **`fluxbox`** (`priority=300`) — starts the window manager with the exact command `fluxbox` and `DISPLAY=:0` exported in the program's environment. No fluxbox configuration file is shipped — defaults are fine for our single-window use case.
- **`x11vnc`** (`priority=400`) — starts the VNC server with the exact command `x11vnc -display :0 -forever -shared -rfbport 5901 -nopw -xkb -clipboard -noxdamage`. `-display :0` points at our Xvfb screen. `-forever` keeps the server up across client disconnects. `-shared` allows multiple clients (rare but useful for "one engineer triaging while another watches"). `-rfbport 5901` overrides x11vnc's default `5900 + display_number` convention, which would otherwise put us on 5900 for display `:0` and miss our compose port map. `-nopw` for no password (acceptable because the host-side port binding is `127.0.0.1` only). `-xkb` and `-clipboard` for keyboard layout fidelity and clipboard sync. `-noxdamage` because XDAMAGE under Xvfb has been a flake source historically and we do not need its bandwidth optimizations.
- **`claude-desktop`** (`priority=500`) — runs `/usr/local/bin/start-claude.sh`. Last to start; depends on Xvfb, DBus, and fluxbox being up.

Supervisord starts programs in ascending priority order but does **not** wait for readiness before launching the next program. The Claude wrapper script handles that gap by polling X and DBus before launching the app.

Every program is configured with `autorestart=true`, `startretries=3`, `startsecs=2`, and `environment=HOME="/root"` (with per-program additions where relevant — for example, `DISPLAY=":0"` on `fluxbox`, `x11vnc`, and `claude-desktop`, and `DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/dbus-session-bus"` on `claude-desktop`). The daemon must run for two seconds without exiting before supervisord considers it "started"; supervisord retries up to three times before giving up. These values are conservative enough to absorb startup hiccups without papering over hard failures: a crash-looping daemon exhausts retries quickly and ends up in `FATAL`, visible in `supervisorctl status` and in the program's log file. `HOME` is set explicitly per program as belt-and-suspenders alongside the Dockerfile-level `ENV HOME=/root`; supervisord version differences in env propagation make the redundancy worth the few characters.

Each program writes stdout and stderr to its own log file under `/tmp/` (e.g., `/tmp/xvfb.out`, `/tmp/xvfb.err`), so `docker exec ... tail -f /tmp/x11vnc.err` and equivalents are the triage path during a failed bring-up. The deliberate choice to route logs to files rather than stdout is documented as an accepted PoC-only departure in Section 4.

The file is heavily commented. For each program: what it is, why the container needs it, and what to check first if that program is the one misbehaving.

#### `start-claude.sh`

A small shell wrapper for launching Claude Desktop. It exists as its own file rather than as a one-liner in `supervisord.conf` because (a) it is more readable that way and (b) it gives us a single place to set the environment Claude Desktop expects.

It does, in order:

- Exports `HOME="${HOME:-/root}"` defensively. The Dockerfile's `ENV HOME=/root` and the supervisord program's `environment=HOME="/root"` should both already provide it, but this third belt-and-suspenders export costs nothing and removes any remaining possibility that the wrapper runs without `HOME` set.
- Exports `DISPLAY=:0` so the app knows where to draw.
- Exports `DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-session-bus`. This value must match the socket path used by the `dbus` supervisord program; both files commit the same exact path in writing, so they cannot drift apart by accident.
- Polls the X server with `xdpyinfo -display :0` in a loop, sleeping 0.5 seconds between attempts, with a hard ceiling of 30 seconds. If `xdpyinfo` does not return success within 30 seconds the script exits non-zero and supervisord records the failure. This is the "wait until Xvfb is really up" step that supervisord's priority ordering does not give us by itself.
- Polls the session DBus daemon with `dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.Peer.Ping`, also at 0.5-second intervals with a 30-second ceiling. The socket file existing is not the same as the daemon being ready to accept connections; on a slow host Electron will race DBus startup and either crash or behave erratically without this check.
- Registers the Chromium launcher (the wrapper described in the Dockerfile section, not the system `chromium.desktop`) as the system default browser via `xdg-settings set default-web-browser chromium-launcher.desktop`. This ensures that when Claude Desktop hands off the OAuth login URL, the browser that opens is the one configured to run cleanly as root in our container.
- Execs `claude-desktop --no-sandbox --password-store=basic`. We assume the aaddrick `.deb` installs the binary as `claude-desktop` on `PATH` — that is the standard install layout for the upstream package. If a future upstream change renames the binary, the wrapper updates here. `--no-sandbox` is necessary because Chromium's built-in sandbox does not work cleanly in this container shape (the container itself is the isolation boundary, per Section 1). `--password-store=basic` is necessary because Electron will otherwise try to use libsecret for credential storage; with `libsecret-1-0` installed but no functioning DBus secret service (no gnome-keyring, no kwallet, no `pass`), Electron will hang or error during token storage. Both flags address standard Electron-in-container gotchas.

Comments at the top of the file explain why each step exists, in the same spirit as the Dockerfile.

#### `README.md`

User-facing instructions, written for an engineer on our team picking this repository up for the first time — or one of us six months from now who has forgotten how it works. It covers:

- One paragraph stating what the artifact is and what it is for. Points readers at `DESIGN.md` for the rationale.
- Quick start: clone, `docker compose up --build`, point a VNC client at `localhost:5901`, log in to Claude.
- A note that the container's VNC port is bound to localhost only. To reach it from another machine, the recommended path is an SSH tunnel. Direct exposure to the network is not supported by this configuration.
- A short troubleshooting section: where the supervisord logs live, what a black VNC session usually means, how to override the `.deb` URL at build time if upstream changes it.
- A line acknowledging the unofficial community port, with a link to the aaddrick upstream project.

The README is intentionally short. Anything longer is documentation drift waiting to happen, and the deeper "why" lives in this design document.

#### `.dockerignore`

Excludes `.git/`, `DESIGN.md`, `README.md`, and common local junk (`.DS_Store`, editor swap files) from the Docker build context. Two reasons: keeps `docker build` fast, and prevents accidentally baking development-only files into the image.

#### `.gitignore`

Excludes the same kinds of local junk from the repository itself. Standard hygiene; the file's contents are unremarkable.

#### `DESIGN.md`

This document. Already exists. Listed here so the file inventory is complete.

### Implementation order

We will write these files in roughly the following order, validating the running container at each meaningful checkpoint. The point is to fail small: if something is going to break, we want it to break before we have layered on more variables to disentangle.

1. **Stub container with the display stack only.** Write a minimal `Dockerfile`, `docker-compose.yml`, and `supervisord.conf` that bring up Xvfb, fluxbox, and x11vnc — no Claude Desktop yet. Confirm we can `docker compose up`, VNC into `localhost:5901`, and see an empty fluxbox session. This proves the headless display plumbing works in isolation, before we add the application that historically makes such setups hard.
2. **Add Claude Desktop and the launch wrapper.** Add the `.deb` install, the Electron runtime dependency packages, the session DBus, the fonts, and `start-claude.sh`. Confirm we can VNC in and see the Claude window render. With the defensive flags pre-committed in Section 5 (`--no-sandbox`, `--password-store=basic`, `--disable-gpu`, `--use-gl=swiftshader`, `--disable-dev-shm-usage`), the audio null device, and the `claude://` mime registration all baked into the image at build time, the failure modes that previously dominated this step are pre-empted. Anything that still goes wrong here is something genuinely unanticipated — an aaddrick-port-specific quirk, an upstream library that was renamed, or a new Electron behavior. Each such failure is fixed at this step with a comment recording the symptom; the fix is also written back into Section 5 so the doc remains the source of truth.
3. **Add the OAuth handoff and the clipboard bridge.** Add Chromium, register it as the default browser in the wrapper, and add `xclip` plus the x11vnc clipboard flag. Confirm we can paste credentials in via the VNC clipboard and complete a login.
4. **Confirm a remote MCP works end-to-end.** Connect Claude to a remote MCP server and exercise it interactively. This closes out the success criteria from Section 0.
5. **Finalize comments, write the README, add the dotfiles.** Confirm a fresh `docker compose down && docker compose up --build` reproduces the working container without manual fix-up.

If a step fails, the failure is itself the diagnostic. It tells us which component or library is missing, we add it, and we continue. The PoC is not done until step 5 reproduces cleanly from a clean clone.

## Section 4: Accepted Risks and Threat Model

### Threat model

This PoC is intended to run on a single developer's workstation while that developer interacts with Claude Desktop through a local VNC client. The container's VNC port is bound to `127.0.0.1`, meaning only processes on the host can reach it. The host is assumed to be a single-user machine, not a shared development server, and not exposed to a network where untrusted parties have access.

That threat model is what makes the choices below acceptable. If this artifact ever runs on a multi-tenant host, on a server reachable from a network, or alongside untrusted local users, the assumptions below stop holding and the configuration must be revisited before it is used.

### Risks we are explicitly accepting

The following are deliberate choices, not oversights. Each is acceptable under the threat model above and would need to be reconsidered if that model changed.

**Running as root inside the container.** The container does not create or switch to a non-root user. Combined with `--no-sandbox`, anything the Electron process does runs with root privileges inside the container. We accept this because the container is itself the isolation boundary and the only network surface it exposes is the localhost-bound VNC port.

**`--no-sandbox` for Chromium, in two places.** Chromium's built-in sandboxing does not work cleanly inside this container shape. We pass `--no-sandbox` to the Electron app at launch and also to the standalone Chromium browser used for OAuth handoff (via the launcher wrapper described in Section 3). Disabling the sandbox removes a defense-in-depth layer that exists in a normal install of either app. We accept this for the same reason as running as root: the container itself is what isolates these processes from the host. Chromium additionally refuses to start as root without `--no-sandbox`, so for the OAuth handoff browser, the flag is not optional even on top of the security argument.

**No VNC password.** `x11vnc` runs without authentication. Combined with the localhost-only port binding, anyone with shell access to the host can connect to a logged-in Claude Desktop session. On a single-user developer workstation this is acceptable; on any shared host it would not be. The compose file's port binding is the safety, not the absence of a password. If a future user changes that binding to expose VNC beyond localhost without also adding a password, they are creating real exposure — this risk transfer is intentional and is called out in the README.

**Three weaknesses stacked.** Root user, no Chromium sandbox, no VNC authentication — each individually defensible, together a meaningful compounding. Anyone with local access to the host can connect to port 5901 and drive a logged-in Claude session with root privileges inside the container. We are calling that compounding out explicitly here so that it is impossible to miss when these decisions are revisited.

**Forceful shutdown of Electron on `docker compose down`.** Docker's default ten-second grace period before SIGKILL may not be enough for Electron to flush cleanly. We are not bumping `stop_grace_period`. The usual concern this raises is profile corruption on the next run; we accept the risk because the PoC is hermetic — there is no persistent profile to corrupt, since each run starts from a fresh container with no mounted volumes. If and when persistence is added, this decision must be revisited.

**GPU and rendering flags pre-committed.** We launch Claude Desktop and the standalone Chromium handoff browser with `--disable-gpu`, `--use-gl=swiftshader`, and `--disable-dev-shm-usage` defensively, alongside `--no-sandbox` and `--password-store=basic`. These flags address standard Electron-in-container failure modes — GL initialization spins, GBM errors, black windows, shared-memory exhaustion. The container has no GPU, so disabling GPU acceleration and using the SwiftShader software renderer is correct on its own merits, not just defensive. We accept that one or more of these flags may be unnecessary for the specific aaddrick build we are pinning; the cost of an unnecessary flag is zero, and the value of avoiding a failed first build is substantial.

**Both `shm_size: 1g` and `--disable-dev-shm-usage`.** Chromium's shared-memory needs can be addressed by bumping `/dev/shm` at the compose level or by telling Electron to fall back to disk-backed IPC. We do both: `shm_size: 1g` for performance when shared memory is healthy, and `--disable-dev-shm-usage` as a belt-and-suspenders fallback. The cost of the redundancy is negligible.

**No Electron remote-debugging port.** We are not exposing `--remote-debugging-port` and not opening port 9222. Test-harness automation is explicitly out of scope for this PoC, and adding remote debugging later is a one-line change to the launch flags plus a one-line change to the compose port map — nothing about our current image, our current launch wrapper, or our current compose file forecloses adding it later. We accept the cost of a future small change in exchange for not exposing an unauthenticated debugging port that the PoC has no current use for.

**Audio routed to an ALSA `null` device.** Claude Desktop's Electron probes for ALSA and PulseAudio devices at startup; with no audio stack in the container, those probes can produce noise in the logs or, on rare versions, a startup hang. We pre-commit two small mitigations: install `libasound2-plugins` and write `/etc/asound.conf` so ALSA's default device is `type null` (probes succeed silently against a do-nothing device), and deliberately do **not** install PulseAudio so PA probes fail fast at `dlopen` rather than hanging on a missing daemon. Audio remains a non-feature; we accept that no audio actually plays, and we accept that any future Electron version that strictly requires a working audio stack would force us to revisit this.

**Per-program logs to `/tmp/` rather than container stdout.** supervisord routes each program's output to its own log file under `/tmp/`, rather than fanning everything out to PID 1's stdout where `docker logs` would pick it up. This is a deliberate departure from container-logging convention. The justification is that human triage during this PoC is meaningfully easier when each daemon's stream is cleanly separated; tailing `/tmp/x11vnc.err` is more useful than `docker logs claude-desktop` and grepping in the moments when something is actually broken. We accept that this routing will need to be undone or supplemented when this image migrates onto our CI test platform, where `docker logs` and log-driver ingestion are the standard interface. The work is small — flip each program's `stdout_logfile` to `/dev/stdout` in `supervisord.conf` — and is in scope for the CI migration, not for this PoC.

**`xclip` is the only clipboard helper we install.** We rely on `xclip` for X11 clipboard ownership. Modern Electron is moving toward different clipboard ownership semantics, and on some versions `xsel` works where `xclip` does not, or vice versa. We are not preemptively installing both. The symptom of any future incompatibility will be silent paste failure during the login flow; the fix is to add `xsel` to the package list. We accept the risk because today, `xclip` works with the version of Electron the aaddrick port ships.

**No fallback mirror for the `.deb`.** The Dockerfile pins the upstream URL and SHA256 of the aaddrick `.deb` but does not configure a mirror to fall back to. A team-owned mirror would require an internal artifact storage decision (which GCS bucket, who owns it, who has write access) that is not in scope for this single-developer PoC. We accept the risk that an unreachable upstream URL during a build will fail the build loudly with no automatic recovery. The follow-on work to add a `CLAUDE_DEB_URL_FALLBACK` build arg pointing at a team-owned GCS object is small and additive; it should be done at the same time this image is migrated onto our CI test platform.

**Apple Silicon performance penalty, with documented fallback to GCP.** The aaddrick port ships an amd64 `.deb`. On Apple Silicon hosts, Docker Desktop runs amd64 images under emulation, which is substantially slower than native execution and has a reputation for flakiness in Electron's GPU and IPC paths in particular. We are pinning the image to `linux/amd64` in the Dockerfile and accepting the performance hit for now — prior experience with headless Chromium under emulation suggests this will work, even if not quickly. If emulation turns out to be too slow or too unstable to satisfy the success criteria on M-series hardware, the documented fallback is to run this PoC on a GCP Linux instance, which is amd64 natively. We are not investing in producing an arm64 build of the aaddrick port; that is out of scope for this PoC.

**Passkey-only Anthropic logins are unsupported.** The login flow assumes the engineer attempting it has a TOTP-based second factor available. Passkey and platform-authenticator (WebAuthn) flows do not work over VNC — the underlying authenticator assertions cannot reach the host's authenticator from inside a remote Chromium session. If an engineer's Anthropic account is configured for passkey-only authentication, they will need to use a TOTP-enabled account to validate the success criteria. We accept this as a deliberate limit of the PoC; broadening it is not in scope.

**OAuth callback: `claude://` pre-registered defensively.** Anthropic's OAuth flow may complete via a `claude://` custom URL scheme (in which case the OS routes the callback back to Claude Desktop via xdg-mime registration) or via a localhost callback URL. Rather than wait to find out empirically, the Dockerfile runs `xdg-mime default claude-desktop.desktop x-scheme-handler/claude || true` after the `.deb` install. If the aaddrick `.deb` already registers the handler, our command is redundant; if not, our command provides it. The `|| true` tolerates the case where the `.deb` installs a differently-named `.desktop` file (in which event the original failure mode would be visible in build logs as a non-fatal warning, not a runtime mystery). If the OAuth flow uses a localhost callback URL instead of the custom scheme, the registration is harmless. This eliminates "OAuth window closes and nothing happens" as a runtime failure mode.

## Section 5: Verbatim File Contents

This section is the implementation. Sections 0–4 explain why each decision was made; this section gives the bytes. The implementer's job is to copy each block into a file with the named path. If the design changes, this section changes — the doc remains the source of truth.

### `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.6
#
# Claude Desktop in Docker (PoC).
# See DESIGN.md for the rationale behind every decision in this file.
#
# Pinned to amd64 because the aaddrick .deb ships amd64 only.
# On Apple Silicon hosts this runs under Docker Desktop's amd64 emulation.
FROM --platform=linux/amd64 debian:bookworm-slim

# .deb pin: aaddrick release v2.0.10+claude1.6259.0, pinned 2026-05-06.
# To update: visit https://github.com/aaddrick/claude-desktop-debian/releases,
# update both URL and SHA256 together, and rebuild.
ARG CLAUDE_DEB_URL=https://github.com/aaddrick/claude-desktop-debian/releases/download/v2.0.10%2Bclaude1.6259.0/claude-desktop_1.6259.0-2.0.10_amd64.deb
ARG CLAUDE_DEB_SHA256=04e1e5c4c89b09bdfd82b9ea6a1a7a26127b34bc5f94de68b62ad47aafa63d1b

# System packages, in commented groups so the purpose of each is obvious.
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
        # OAuth handoff browser
        chromium \
        xdg-utils \
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

# Generate en_US.UTF-8 so Electron's Intl machinery has a real locale to read.
RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# HOME is read by Electron, Chromium, and xdg-settings; supervisord under root
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

# Chromium launcher wrapper. Chromium refuses to start as root without
# --no-sandbox; --password-store=basic avoids libsecret hangs (no DBus
# secret service in the container); the GPU/IPC flags match start-claude.sh
# so the OAuth browser shares the same container-safe baseline.
RUN cat > /usr/local/bin/chromium-launcher <<'SCRIPT'
#!/bin/sh
exec /usr/bin/chromium \
    --no-sandbox \
    --password-store=basic \
    --disable-gpu \
    --use-gl=swiftshader \
    --disable-dev-shm-usage \
    "$@"
SCRIPT
RUN chmod +x /usr/local/bin/chromium-launcher

# Custom .desktop file pointing at our launcher. start-claude.sh registers
# this as the default browser at runtime.
RUN cat > /usr/share/applications/chromium-launcher.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium (container-safe)
Exec=/usr/local/bin/chromium-launcher %U
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
DESKTOP

# Our supervisord config overwrites the stock Debian top-level config rather
# than dropping a fragment into conf.d/. This makes the CMD path unambiguous
# and removes our dependency on the stock config's conf.d/*.conf include.
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY start-claude.sh /usr/local/bin/start-claude.sh
RUN chmod +x /usr/local/bin/start-claude.sh

EXPOSE 5901

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
```

### `docker-compose.yml`

```yaml
services:
  claude-desktop:
    build:
      context: .
      dockerfile: Dockerfile
    image: claude-desktop-poc:latest
    container_name: claude-desktop
    # tini at PID 1, supervisord at PID 2. Cleanly handles SIGTERM forwarding
    # and zombie reaping; removes a class of weird-shutdown bugs.
    init: true
    # Chromium's renderer crashes with the default 64 MiB /dev/shm.
    shm_size: 1g
    # Electron with Chromium plus Claude can comfortably use 2 GiB; cap at 4 GiB
    # so a runaway leak fails fast on Docker Desktop for Mac instead of grinding
    # the host VM.
    mem_limit: 4g
    ports:
      # Localhost-only on purpose. VNC runs without a password; do not change
      # this binding without also adding authentication.
      - "127.0.0.1:5901:5901"
    # No volumes — hermetic per run.
    # No environment overrides — defaults baked into the image.
```

### `supervisord.conf`

```ini
; Self-contained supervisord config. Overwrites the stock Debian top-level
; config; we do not rely on conf.d/*.conf include behavior.

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisord]
nodaemon=true
logfile=/tmp/supervisord.log
pidfile=/tmp/supervisord.pid
loglevel=info
user=root

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface.make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

; ---- programs ----

[program:xvfb]
priority=100
command=/usr/bin/Xvfb :0 -screen 0 1440x900x24 -dpi 96 -nolisten tcp
autorestart=true
startretries=3
startsecs=2
environment=HOME="/root"
stdout_logfile=/tmp/xvfb.out
stderr_logfile=/tmp/xvfb.err
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0

[program:dbus]
priority=200
command=/usr/bin/dbus-daemon --session --nofork --address=unix:path=/tmp/dbus-session-bus
autorestart=true
startretries=3
startsecs=2
environment=HOME="/root"
stdout_logfile=/tmp/dbus.out
stderr_logfile=/tmp/dbus.err
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0

[program:fluxbox]
priority=300
command=/usr/bin/fluxbox
autorestart=true
startretries=3
startsecs=2
environment=HOME="/root",DISPLAY=":0"
stdout_logfile=/tmp/fluxbox.out
stderr_logfile=/tmp/fluxbox.err
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0

[program:x11vnc]
priority=400
command=/usr/bin/x11vnc -display :0 -forever -shared -rfbport 5901 -nopw -xkb -clipboard -noxdamage
autorestart=true
startretries=3
startsecs=2
environment=HOME="/root"
stdout_logfile=/tmp/x11vnc.out
stderr_logfile=/tmp/x11vnc.err
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0

[program:claude-desktop]
priority=500
command=/usr/local/bin/start-claude.sh
autorestart=true
startretries=3
startsecs=2
environment=HOME="/root",DISPLAY=":0",DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/dbus-session-bus"
stdout_logfile=/tmp/claude-desktop.out
stderr_logfile=/tmp/claude-desktop.err
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
```

### `start-claude.sh`

```sh
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
```

### `README.md`

````markdown
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
````

### `.dockerignore`

```
.git
.gitignore
.dockerignore
DESIGN.md
README.md
.DS_Store
*.swp
*.swo
```

### `.gitignore`

```
.DS_Store
*.swp
*.swo
.idea/
.vscode/
```
