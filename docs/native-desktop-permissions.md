# Native physical desktop permission integration

This shares the logged-in owner's physical display, not a VM or isolated desktop.
All adapters default to read-only.
Neither `job.allow_input` nor `job.input_authorized` grants control.

## Canonical authorization

The companion MIOSA change uses JSON `access: "control"` on the owner-tenant-authenticated desktop ticket endpoint for explicit control approval.
The default ticket contains only `desktop:stream`; approved control adds `desktop:control`.
Assigned tenants are not owners of the physical desktop.
The relay verifies the real signed ticket and rechecks the current host owner before sending a separate `desktop_session_grant` frame.
Generic desktop jobs cannot mint control scope from their payload or requested scopes.
The relay sends `allow_input: true` only when the verified ticket includes `desktop:control`.
Generic job dispatch needs its own verified ticket integration before it can issue this attestation; that integration is not established by the OSA handler alone.

OSA accepts the attestation only on its verified `wss` control connection after `hello_ok` identifies both `host_id` and `owner_tenant_id`.
This is control-plane attestation, not independent host-side JWT verification.
The platform HMAC signing secret is never provisioned onto customer hosts.
Attestations bind `host_id`, owner `tenant_id`, `session_id`, scopes, and `expires_at`.
They are consumed once, retained only in memory, and limited to five minutes and 32 outstanding/recent sessions per connection.
The job and controller paths receive authorization as separate internal context through `Session.FrameRouter`.
Missing attestation, older `hello_ok`, or unencrypted `ws` cannot enable input.

Each accepted grant owns a lease monitored by the desktop process or controller.
Expiry, control connection loss, owner process exit, and `desktop_stop` revoke that lease and close the owned session.
Startup checks the lease again before connecting the relay to the helper.
The control plane's revocation cache is checked when opening a session; revoking a ticket alone does not immediately broadcast to an already-open session.
Use `desktop_stop` for immediate session revocation; otherwise the original grant expiry remains the upper bound.
No automatic permission renewal is implemented.

## Helper contracts

- macOS: `--read-only|--allow-input --display N`, integer index 0 through 63.
- Windows: the same explicit arguments and display bounds.
- Wayland: `--read-only|--allow-input`, with the monitor selected through fresh portal consent.
- X11: `-viewonly` unless both the request and verified grant allow input; an actual display is required, with no guessed `:0`.

Wayland read-only requests use an explicit empty device bitmask and ignore input even if the portal returns additional devices.
Control startup fails if the portal does not grant both requested keyboard and pointer devices.
This follows the [RemoteDesktop portal's requested and granted device contract](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html).
macOS still requires Screen Recording permission for capture and Accessibility/post-event permission for input.
Windows still requires a usable interactive desktop and respects secure-desktop/integrity restrictions.
An executable helper is not evidence that capture, input, or the current display is available.

## Verification and remaining acceptance

The actual OSA inbound job path is tested using a hash-pinned executable fixture that reports which permission arguments it received.
Forged payload permission stays read-only; a matching grant enables control; replay, foreign owner/host, expired grants, and insecure transport cannot authorize control.
The controller test exercises real loopback TCP and verifies closure when the connection grant is cleared.
Native macOS tests use synthetic frames and recording-only input sinks; they do not capture the host display or post CGEvents.
Linux native tests and packaging tests run in the task-owned build container without portal capture.
Companion MIOSA ticket, HTTP/database, and relay integration must be validated separately from the OSA handler tests.
Live macOS, Windows, and Wayland capture/input/consent QA has not been performed and requires explicit native QA approval.
No merge or deployment is part of this work.
