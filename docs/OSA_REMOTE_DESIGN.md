# OSA Remote — Design

Status: Proposed (for review, not implemented)
Author: research + design pass
Scope: build "OSA remote" on top of the existing OpenComputers subsystem. No code has been changed by this document.

This document is grounded in two codebases:

- Hermes remote (source clone at `/home/miosa/projects/research/hermes-agent`), studied for its enrollment and relay model.
- OSA OpenComputers (`/home/miosa/projects/osa/OSA/lib/optimal_system_agent/open_computers/`), which is the foundation OSA remote reuses.

---

## 0. What we learned from studying Hermes "remote"

There is no `hermes remote` command and no desktop remoting in Hermes. What looks like "remote" is Hermes's **gateway relay**: a self-hosted host daemon dials OUT over a WebSocket to a hosted **connector** (relay/control server), so chat platforms can reach a firewalled Hermes instance without it exposing any inbound port. It carries chat `MessageEvent`s only. No screen streaming, no input injection, no P2P.

Key files: `hermes_cli/subcommands/gateway.py` (the `enroll`/`run` verbs), `hermes_cli/gateway_enroll.py` (`cmd_gateway_enroll`, `_post_enroll`), `gateway/relay/ws_transport.py:366` (`websockets.connect(...)`, the actual dial), `gateway/relay/auth.py` (HMAC upgrade token + delivery signature), `docs/relay-connector-contract.md` (dial-out contract).

The important takeaway: **OSA already does the hard part Hermes only does for text (dial-out relay), and OSA additionally already streams a real desktop over that relay, which Hermes does not do at all.** So OSA remote is not a port of Hermes; it is mostly the addition of a *client* and a *session-control surface* on top of machinery OSA already has. Hermes contributes a better enrollment and auth model (see the steal list in section 7).

---

## 1. OSA Remote as a product

OSA remote lets a user treat their own machine (home desktop, office workstation, a lab box) as if it were a cloud VM they can reach from anywhere:

- **Run a command on it** from another machine or the MIOSA web console, and get the output back.
- **Dispatch an agent task to it** ("go fix the failing test in ~/projects/foo"), running OSA's own agent loop on that host with that host's files and tools.
- **Open an interactive shell on it** (a real PTY, not a fake REPL), attached to your local terminal.
- **See its screen and control it** (mouse and keyboard) like a remote desktop.
- Do this **without opening any inbound port** on the host. The host always dials out to the MIOSA control plane; the client also connects to the control plane, which brokers between them. Nothing is directly reachable from the internet.

Authentication is tied to the user's MIOSA account. A host is claimed once (it holds an `oc_host_*` key plus a pinned ed25519 fingerprint); thereafter the account owner can list their hosts and open sessions to them.

The mental model for the user:

```
osa remote hosts                 # list the machines I have claimed
osa remote exec home -- uname -a # run one command on host "home"
osa remote agent home "fix CI"   # dispatch an OSA agent task to host "home"
osa remote shell home            # interactive PTY on host "home"
osa remote desktop home          # see + control the screen of host "home"
osa remote sessions home         # list live sessions on that host
osa remote kill home <sid>       # tear a session down
```

---

## 2. How it maps onto OpenComputers

OSA remote is a thin product layer over OpenComputers. Almost everything on the **host side already exists**. The new work is almost entirely a **client** and a **session-control surface**, plus control-plane brokering (which lives in `miosa-compute`, not this repo).

### 2.1 What OpenComputers already provides (reused as-is)

| Capability | Existing module | What it already does |
|---|---|---|
| Outbound host session | `open_computers/session.ex`, `session/connector.ex` | Dials `wss://api.miosa.ai/api/v1/opencomputers/hosts/ws` (subprotocol `miosa-opencomputers-v1`, `connector.ex:12`), sends `{:hello, ...}`, transitions to `:active` on `hello_ok`, 30s heartbeat, 90s dead-watchdog, exponential-backoff reconnect. |
| Identity / auth | `session/hello.ex`, `session/fingerprint.ex`, `open_computers.toml` | Hello advertises `host_key` (the `oc_host_*` key) plus an ed25519 fingerprint the control plane pins on first connect (`fingerprint.ex`). Config in `~/.osa/open_computers.toml`. |
| Wire codec | `session/frame_codec.ex` | Erlang term encode / `binary_to_term(:safe)` decode of every frame. |
| Outbound frame fan-out | `open_computers/frame_router.ex` | Executors call `FrameRouter.send_frame/1`; it forwards to the registered host-client (the Session pid). Inbound frames are routed by tag to the right executor. |
| One-shot command | `executor/direct/exec.ex` (kind `:exec_on_host`) | Real. Runs a shell command, captures stdout (1 MB cap), returns exit code + duration. |
| Agent task | `executor/direct/agent.ex` (kind `:dispatch_agent`) | Real. Runs OSA's own agent loop via `Agent.Loop.process_message/3` in an isolated `oc-agent-<job_id>` session. |
| Interactive shell | `executor/direct/pty.ex` | Real. Spawns a real PTY shell via `:erlexec`, per-`session_id`, with `pty_open_request` / `pty_input` / `pty_resize` / `pty_close` inbound and `pty_output` outbound. Shell allowlist from TOML. This is the terminal-remoting primitive. |
| Desktop stream + input | `executor/direct/desktop/controller.ex`, `desktop/x11vnc.ex` | Real on Linux. Starts x11vnc, bridges its RFB byte stream over the control-plane WS as `{:desktop_data, %{session_id, direction, data}}` frames, per `session_id`. Advertises `capabilities: %{mouse: true, keyboard: true}`. Input injection is inherent in the VNC/RFB byte stream x11vnc consumes. |
| Session addressing (host side) | inside `pty.ex` and `desktop/controller.ex` | Both already key concurrent sessions by `session_id` in their state maps. Multiple simultaneous sessions per host are already supported at the executor level. |
| Supervision | `open_computers/supervisor.ex` | Starts Config, FrameRouter, the executor supervisor, the long-lived executors, and Session, gated by `open_computers_enabled`. |

### 2.2 What is genuinely NEW for OSA remote

1. **An OSA-side client.** Today the only consumer of these host frames is the MIOSA web console (browser, noVNC). There is no OSA CLI that can itself connect to the control plane as a *viewer* and open a session. This is the core new component: `OptimalSystemAgent.Remote.Client` and its CLI.
2. **A client-facing control-plane endpoint and session broker** (miosa-compute side, see section 6). Today hosts connect to `.../hosts/ws`. Clients need a peer endpoint (for example `.../opencomputers/clients/ws`) authenticated by the MIOSA account, plus a broker that routes frames between a chosen client and a chosen host and enforces ownership.
3. **A user-facing session model and CLI** (`osa remote ...`): list hosts, create/list/attach/kill sessions addressed by `host` + `session_id`. None of this verb surface exists today (`cli/opencomputers.ex` only has `status|login|connect|enable|disable|logout`).
4. **Interactive local terminal bridge.** A client that pumps the local TTY into `pty_input` frames and renders `pty_output`. The host half already exists; the client half does not.
5. **A local desktop viewer path** (Phase 2): either open the user's browser at a control-plane relay URL, or bridge to a local VNC viewer. The host streaming half already exists on Linux.
6. **Nicer enrollment** (optional, Phase 1.5): replace paste-the-`oc_host_*`-key with a one-time enrollment token, following Hermes (section 7).

Note on reuse economy: the new client can literally reuse `session/connector.ex`, `session/tls_opts.ex`, `session/frame_codec.ex`, and `session/backoff.ex` unchanged, because the client-to-control-plane transport is the same WebSocket-over-Mint pattern as the host-to-control-plane transport.

---

## 3. Gaps between Hermes remote and OSA today (itemized)

Because Hermes's "remote" is a text relay, the comparison is asymmetric. Split into two lists.

### 3.1 Where OSA is already ahead of Hermes remote

- OSA streams a **real desktop with input** over its dial-out relay (`desktop/controller.ex`). Hermes has nothing equivalent in its relay.
- OSA runs **real host command execution, agent tasks, and interactive PTYs** as first-class relay capabilities (`exec.ex`, `agent.ex`, `pty.ex`). Hermes's relay carries chat messages only.
- OSA already advertises a **capability set and multiple modes** at handshake (`hello.ex` `derive_capabilities/1`). Hermes has a `CapabilityDescriptor` but for messaging surfaces.

### 3.2 Where OSA is missing pieces Hermes has (the real gaps to close)

1. **No client.** Hermes's "client" is the chat platform user; the connector fronts them. OSA has no user-facing way to *initiate* a session against a host. This is the biggest gap.
2. **No one-time enrollment token.** Hermes issues a single-use enrollment token, POSTs it to `POST /relay/enroll`, and receives a per-host secret + per-tenant delivery key (`gateway_enroll.py`). OSA instead has the user paste a long-lived `oc_host_*` key (`cli/opencomputers.ex:cmd_login`). OSA's is weaker UX and weaker rotation story.
3. **No rotating/multi-secret auth or delivery signatures.** Hermes uses an HMAC upgrade token plus a per-tenant delivery signature with a replay-skew window and a multi-secret verify list for rotation (`gateway/relay/auth.py`). OSA presents a static `host_key` string in the hello and relies on fingerprint pinning; there is no per-message signature or rotation path.
4. **No explicit "managed install refuses self-enroll" guard.** Hermes blocks `enroll` under `is_managed()` (`gateway_enroll.py:170`). OSA has no equivalent for fleet installs.
5. **No structured session-key addressing for multi-tenant/multi-profile.** Hermes builds a session key from a structured `SessionSource` (platform, chat, user, profile). OSA keys sessions by a bare `session_id` UUID with no owner/tenant/profile envelope visible to the host.
6. **No terminal-close semantics for revoked credentials.** Hermes treats a 4401 close after a good handshake as terminal (revoked secret). OSA reconnects on essentially any close.

---

## 4. Phased build plan

Each phase names the specific OSA modules to add or change and the user-facing commands. Phase 1 is deliberately the smallest thing that is genuinely useful.

### Phase 1 — Remote command / agent / shell sessions (no desktop video)

Goal: from any machine, run a command, dispatch an agent task, or open an interactive shell on a claimed host, brokered through the control plane. This reuses the host side wholesale and adds the client.

New OSA modules (host repo):

- `lib/optimal_system_agent/remote/client.ex` — a GenServer that dials the client-facing control-plane WS, authenticates with the MIOSA account credential, and exposes `hosts/0`, `open_session/2`, `send_frame/2`, `close_session/2`. Reuses `OpenComputers.Session.Connector`, `Session.TlsOpts`, `Session.FrameCodec`, `Session.Backoff` (no duplication).
- `lib/optimal_system_agent/remote/pty_bridge.ex` — puts the local terminal into raw mode, streams stdin to `pty_input` frames, renders `pty_output`, handles SIGWINCH to `pty_resize`, and closes on `pty_close`.
- `lib/optimal_system_agent/remote/auth.ex` — resolves the MIOSA account token for the client connection (mirrors how OSA already resolves provider auth).
- `lib/optimal_system_agent/cli/remote.ex` — the `osa remote <verb>` dispatcher, mirroring the shape of `cli/opencomputers.ex`.

Changes to existing OSA modules:

- `lib/optimal_system_agent/cli.ex` — add a `remote/1` entry (mirror of the existing `opencomputers/1` at `cli.ex:57`) and wire the top-level `remote` verb to `CLI.Remote.dispatch/1`.
- No change needed to `exec.ex`, `agent.ex`, or `pty.ex`. The host already accepts `{:job, %{kind: :exec_on_host}}`, `{:job, %{kind: :dispatch_agent}}`, and the `pty_*` frame family. Phase 1 sends exactly those, addressed by the broker to the chosen host.
- Optional: extend `session/frame_router.ex` `handle/2` only if the broker requires a new ack frame; the existing `:job_accept` / `:job_done` / `:job_fail` path already reports results.

User-facing commands:

```
osa remote hosts                         # list claimed hosts + online status
osa remote exec <host> -- <cmd...>       # one-shot :exec_on_host, prints stdout/exit
osa remote agent <host> "<prompt>" [--dir <path>] [--model <m>]   # :dispatch_agent
osa remote shell <host> [--shell /bin/bash]                       # interactive PTY
osa remote sessions <host>               # list live sessions on that host
osa remote kill <host> <session_id>      # pty_close / desktop_stop / job cancel
```

What Phase 1 does not need: no desktop video, no native helpers, no VM slicing. It is shippable against Linux, macOS, and Windows hosts for exec and agent, and against Unix hosts for shell (PTY is Unix-only today per `supervisor.ex` `pty_children/0`; Windows ConPTY is a known TODO in `pty.ex`).

### Phase 2 — Desktop streaming + input

Goal: `osa remote desktop <host>` shows the host screen and forwards mouse/keyboard.

Reuse: `desktop/controller.ex` and `desktop/x11vnc.ex` already stream Linux desktops with input over the control-plane WS as `desktop_data` frames. Input injection is already inherent in the RFB stream.

New OSA work:

- `lib/optimal_system_agent/remote/desktop_viewer.ex` — the client half. Two supported targets: (a) open the user's default browser at a control-plane-provided noVNC relay URL (simplest, leans on miosa-compute), or (b) expose a local `127.0.0.1:<port>` RFB endpoint that pumps `desktop_data` frames to/from a native VNC viewer the user already has.
- Add `osa remote desktop <host> [--browser | --local-vnc]` to `cli/remote.ex`.

Ship the already-written native helpers so desktop works beyond Linux:

- `native/macos/ScreenShare/` (Swift, ScreenCaptureKit + CGEventPost) and `native/windows/ScreenShare/` (Desktop Duplication + SendInput) exist in source but the binaries are not shipped (see `docs/macos-desktop.md` and `docs/windows-desktop.md`, both "Ship Status: not yet shipped"). Building and bundling them into `priv/` is the concrete Phase 2 host-side task. The Elixir adapters `desktop/macos.ex` and `desktop/windows.ex` already exist and follow the same `PORT=<n>` contract as x11vnc.

No protocol change is required: `desktop_start_request` / `desktop_data` / `desktop_stop` already carry everything.

### Phase 3 — Multi-session and VM slicing

Goal: run many independent sessions, and optionally carve throwaway sub-VMs on the host so a remote session is isolated from the user's own desktop.

Reuse: `hello.ex` already advertises `:slicing` and `:vm_dispatch` modes with per-OS backends (`:apple_containerization`, `:firecracker`, `:hyper_v`), and `executor.ex` already reserves the `:create_computer` kind. The multi-session bookkeeping in `pty.ex` and `desktop/controller.ex` already keys by `session_id`.

New OSA work:

- `lib/optimal_system_agent/open_computers/executor/direct/vm/` — real executors for `:create_computer` on Firecracker (Linux), Apple Containerization (macOS), Hyper-V (Windows). Today these modes are advertised but not executed (see the Phase 2/3 notes in `open_computers.ex` and `executor.ex`).
- A session-pool/registry so the control plane can address `{host, vm_id, session_id}` and the host can run exec/agent/pty/desktop *inside* a sliced VM rather than on the bare host.
- Add `osa remote vm create|list|destroy <host>` and let `exec`/`shell`/`desktop` target a `--vm <vm_id>`.

This phase is genuinely large and can be deferred; Phases 1 and 2 already deliver the "use my machine as a cloud VM" product.

---

## 5. User-facing command surface and session model

### 5.1 Command surface

Enrollment and host mode stay where they are (`osa opencomputers ...`) because that is the *host* claiming itself. `osa remote ...` is the *client* verb surface. They are two sides of the same subsystem.

Host side (already exists, `cli/opencomputers.ex`):

```
osa opencomputers login --key <oc_host_key>   # claim this machine
osa opencomputers enable                       # turn on host mode
osa opencomputers status                        # show connection state
osa opencomputers logout                        # unclaim
```

Client side (new, `cli/remote.ex`):

```
osa remote hosts
osa remote exec <host> -- <cmd...>
osa remote agent <host> "<prompt>" [--dir <path>] [--model <m>]
osa remote shell <host> [--shell <path>]
osa remote desktop <host> [--browser | --local-vnc]      # Phase 2
osa remote sessions <host>
osa remote kill <host> <session_id>
osa remote vm create|list|destroy <host>                 # Phase 3
```

`<host>` is a friendly alias the account owner assigns at claim time or a host id returned by `osa remote hosts`.

### 5.2 Session model

- **Creation.** The client asks the control plane to open a session against a host and a session kind (`exec`, `agent`, `shell`, `desktop`). The control plane allocates a `session_id` (UUID, same shape the host executors already expect), verifies the account owns the host, and relays the opening frame (`{:job, ...}`, `pty_open_request`, or `desktop_start_request`) to that host over its existing `hosts/ws` connection.
- **Addressing.** A session is addressed by `{host, session_id}`. Phase 3 extends this to `{host, vm_id, session_id}`. This matches how `pty.ex` and `desktop/controller.ex` already key their state maps.
- **Attach.** `exec` and `agent` are request/response and do not need re-attach. `shell` and `desktop` are long-lived; re-attach means the client reconnects to the control plane and resubscribes to the existing `session_id` (the host keeps the PTY or VNC alive independent of the client, since the executors are supervised and per-session).
- **Listing.** `osa remote sessions <host>` asks the control plane (or the host) for the live `session_id`s and their kinds. A small new host-side query frame (for example `sessions_list_request` handled by a lightweight collector over `pty.ex` and `desktop/controller.ex` state) may be added, or the control plane can track sessions it brokered.
- **Kill.** `osa remote kill` maps to `pty_close` / `desktop_stop` / job-cancel depending on kind. The host already handles `pty_close` and `desktop_stop`.
- **Auth.** The client authenticates to the control plane with the MIOSA account credential (`remote/auth.ex`). The host authenticates with its `oc_host_*` key plus pinned ed25519 fingerprint (unchanged). Ownership (this account may address this host) is enforced by the control plane, which is the only party that sees both sides.
- **Lifecycle safety.** Host executors are already supervised and self-clean on disconnect (`desktop/controller.ex close_session`, `pty.ex` SIGHUP on close). A client dropping does not leak host processes.

---

## 6. Control-plane (miosa-compute) dependencies for Phase 1

These live in `miosa-compute`, not in this repo. The host already speaks its half; Phase 1 cannot ship until the control plane provides:

1. **A client-facing WS endpoint.** For example `wss://api.miosa.ai/api/v1/opencomputers/clients/ws`, peer to the existing `.../hosts/ws`. Authenticated by the MIOSA account (JWT / session), not by an `oc_host_*` key.
2. **A host-ownership model and directory.** Map each `oc_host_*` host to the owning account, expose "list this account's hosts + online status" so `osa remote hosts` has data. Host enrollment already mints the `oc_host_*` key, so the ownership record likely half-exists already.
3. **A session broker.** Allocate `session_id`, verify ownership, and relay frames bidirectionally between a specific client socket and a specific host socket:
   - Client to host: `{:job, %{kind: :exec_on_host | :dispatch_agent, ...}}`, `pty_open_request` / `pty_input` / `pty_resize` / `pty_close`, `desktop_start_request` / `desktop_data(direction: :upstream)` / `desktop_stop`.
   - Host to client: `:job_accept` / `:job_done` / `:job_fail`, `pty_opened` / `pty_output` / `pty_close` / `pty_error`, `desktop_ready` / `desktop_data(direction: :downstream)` / `desktop_error`.
   These are exactly the frames the host already sends and receives; the broker only needs to forward them to the right client, not interpret them.
4. **Low-latency forwarding for interactive kinds.** `pty_output` and `desktop_data` must be forwarded promptly for the shell and desktop experiences to feel live.
5. **(Optional, Phase 1.5) an enrollment-token endpoint** `POST /opencomputers/enroll` returning a per-host secret, to replace paste-the-key (see section 7).

The frame codec (`term_to_binary`) is already what the host uses on `.../hosts/ws`; the broker must speak the same `miosa-opencomputers-v1` subprotocol and codec on the client side, or transcode. Keeping both sides on the same erlang-term codec is simplest.

---

## 7. Steal list from Hermes remote

Specific, worth-adopting ideas, each with where it lives in Hermes and where it lands in OSA:

1. **One-time single-use enrollment token.** Hermes `gateway_enroll.py` (`cmd_gateway_enroll`, `_post_enroll`): the host POSTs a single-use token with a bearer identity to `POST /relay/enroll` and receives a per-host secret it stores. Adopt as `osa remote enroll --token <t>` (or `osa opencomputers enroll`), replacing the paste-`oc_host_*`-key flow in `cli/opencomputers.ex:cmd_login`. Better security posture and better first-run UX.
2. **Dial-out-only as an advertised guarantee.** `docs/relay-connector-contract.md` frames "no gateway-side inbound port" as a security property. OSA already dials out from both host and (planned) client. Document this explicitly as an OSA remote selling point: nothing on the host is internet-reachable.
3. **HMAC upgrade token instead of a static key in the payload.** `gateway/relay/auth.py` `make_upgrade_token` puts `base64url("{id}:{exp}:{sig}")` in the `Authorization` header on the WS upgrade. OSA today sends the raw `host_key` inside the hello body. Move host auth to a short-lived HMAC upgrade token derived from a stored secret; keeps the long-lived secret off the wire.
4. **Rotating multi-secret verify list.** `auth.py` verifies against a list of secrets to allow rotation without downtime. Adopt for OSA host secrets so keys can be rotated by the control plane without a re-claim.
5. **Per-message delivery signature with a replay-skew window.** `auth.py` `x-relay-timestamp` / `x-relay-signature`. Adopt for control-plane-to-host frames so a compromised transport cannot inject forged jobs, complementing the existing fingerprint pinning.
6. **Managed-mode refuses self-enroll.** `gateway_enroll.py:170` `is_managed()` guard. Add an equivalent so OSA fleet/managed installs get their secret stamped in and cannot be re-enrolled by a local user.
7. **Terminal 4401 semantics.** `ws_transport.py` treats a 4401 close after a good handshake as "secret revoked, stop trying." OSA's `session.ex` reconnects on essentially any close; add a terminal-close code so a deprovisioned host stops hammering reconnect.
8. **Structured session-key addressing.** Hermes builds session keys from a structured `SessionSource` (tenant/profile/user). When OSA adds multi-user or multi-VM addressing (Phase 3), carry an explicit `{account, host, vm_id, session_id}` envelope rather than a bare UUID.

Items 1, 2, and 7 are small and high-value for Phase 1.5. Items 3 to 6 are the security hardening track. Item 8 pairs with Phase 3.

---

## 8. Summary

- Hermes "remote" is a text relay; its value to OSA is the enrollment and auth model, not the feature itself.
- OSA already has, on the host side, real exec, agent, PTY, and Linux desktop-with-input streaming over a dial-out relay. That is the entire host half of "use my machine as a cloud VM."
- The missing pieces are an OSA client, a `osa remote` session-control surface, and control-plane brokering between client and host. Phase 1 adds the client and CLI and reuses the host untouched. Phase 2 turns on desktop by shipping the already-written native helpers and adding a viewer. Phase 3 adds VM slicing using modes OSA already advertises.
- Nothing here requires reinventing OpenComputers; it is a product layer plus a client on top of it.
