# Windows OpenComputers onboarding contract

## Entry point and ownership

The OSA release produces `osa-opencomputers-windows.zip` and its SHA-256 sidecar.
Extract the complete, checksum-verified bundle and invoke its local entrypoint in the owner's unelevated Windows PowerShell session:

```powershell
.\Install-OpenComputer.ps1 -Key $HostKey -Region default -PlatformApiUrl 'https://api.miosa.ai' -ControlUrl 'wss://api.miosa.ai/api/v1/opencomputers/hosts/ws'
```

Do not paste actual keys into committed documentation or logs.
`-InstallIfMissing` explicitly authorizes a fresh installation when the canonical `.osa` directory does not exist.
`-NoStart` configures the task without requesting execution.
`-WhatIf` performs preflight without changing files, installing software, or registering a task.
The optional `-Port` is 9089 by default and must be 1024 through 65535.

The canonical root is `%USERPROFILE%\.osa`.
Custom OSA_HOME values, network paths, and reparse-point execution paths are rejected rather than interpreted inconsistently by the launcher and runtime.
Remote endpoints require HTTPS/WSS; this enrollment path does not send credentials over insecure development HTTP/WS.

## Existing installations

An existing OSA launcher and release are reused without running the general installer, updater, stop command, or TUI.
An incomplete existing installation is an explicit repair condition, not permission to erase its release directory.
Matching enrollment configuration is preserved byte-for-byte, including custom modes and comments.
A changed host key, control URL, ambiguous field, insecure ACL, or unknown configuration syntax is rejected without rewriting the existing file.
Fingerprints, user sessions, `.env`, profiles, markers, and application databases are not reset.

An existing backend is considered reusable only when the listening process belongs to the current owner's SID and its Erlang executable lives under that installation's release directory.
A foreign or unverifiable listener is an error, never a process to kill.
The installer does not call `osa stop`, `taskkill`, `Stop-Process`, or process-name-wide cleanup.
The task runner waits while an owner backend is already listening, preserving active user work.
If that backend has not activated OpenComputers, enrollment reports that an owner-controlled restart is needed instead of pretending it connected.

## Fresh installation

Fresh installation runs the bundled general OSA installer in a unique sibling staging directory, not directly over `.osa`.
The bundle's `RELEASE_TAG` pins the runtime/TUI downloads.
Both release and TUI checksums are mandatory in this mode.
`OSA_INSTALL_SKIP_PATH=1` prevents the staging path from being written into the owner's PATH.
Successful installation is promoted with a non-overwriting directory move and its `release_root` marker is corrected to the final location.
A racing installer that creates `.osa` wins safely; the promotion fails without replacing it.
An unsuccessful staging directory is retained with its path reported for explicit recovery.
This enrollment flow does not globally change PATH; the launcher is available at `%USERPROFILE%\.osa\bin\osa.ps1`.

## Task contract

The task name is `OSA-OpenComputers-<digest>` derived from the owner SID and canonical OSA root.
Its principal is that SID, `Interactive` logon, and `Limited` run level.
It runs at that user's logon, without credentials stored in the task action, with `IgnoreNew` duplicate-instance handling and no execution-time cutoff.
It is not a Windows service, SYSTEM process, or a claim of desktop access while the owner is logged out.
Windows services run outside the interactive user desktop; this path follows Microsoft's [interactive service restrictions](https://learn.microsoft.com/en-us/windows/win32/services/interactive-services).

Private task files live under `.osa/opencomputers-host` with owner/SYSTEM ACLs.
The entrypoint validates owner SID, home, configuration and port before invoking the existing launcher's `serve` verb.
It explicitly binds the task to the selected configuration so stale `.env` identity overrides cannot redirect enrollment.
An existing task is accepted only if its principal, action, trigger and critical settings match.
Task source files and state must also match; different versions require an explicit managed update.
There is no `Register-ScheduledTask -Force`, automatic stop, task takeover, or silent replacement.
The legacy machine-wide `MIOSA OSA OpenComputers` task requires an explicit migration and is not silently adopted.

Registration is checked against the platform's existing `POST /api/v1/opencomputers/hosts/registration-status` contract.
Success requires a connected response, a running matching task and an owner-verified local listener.
This is enrollment evidence, not native desktop capability verification or permission to dispatch workloads.
NoStart, timeout and rejection are not reported as connected.
Task/config remain available for explicit diagnosis after registration rejection or timeout.

## Zeno integration handoff

The helper contract is `Windows.spawn/start` with default read-only behavior, `--display <index>` for monitor selection, and `--allow-input` only after the controller verifies the owner-authorized control grant.
Both `desktop.ex` and `desktop/controller.ex` have native Windows entrypoints; both must forward the authorized choice rather than enabling input based on OS detection or a raw request field.
An untrusted `allow_input` field is not itself authorization.
`readiness.ex` should keep helper-present capture/control marked unverified until a real permission-enabled session succeeds.
The helper announces `PORT=<ephemeral-port>` only after capture succeeds.
Shutdown must close the bridge and owner stdin before falling back to a targeted forced kill so the helper can release held input.
No Windows Elixir adapter files were edited by this implementation owner.

## MIOSA wrapper handoff

The existing platform `apps/web/priv/static/install-host.ps1` currently reinstalls OSA and rewrites enrollment itself.
Replace that behavior in the MIOSA PR with download, mandatory checksum verification, extraction, and delegation to the version-matched OSA enrollment bundle.
Forward `Key`, `Region`, `PlatformApiUrl`, and `ControlUrl` without printing the key.
Choose `InstallIfMissing` explicitly for the dashboard's fresh-install flow.
Do not mix one release's enrollment scripts with another release's installer payload.
Do not copy the host key into Task Scheduler arguments, broad environment files, or logs.
The wrapper change is a cross-repository handoff, not a deployed change in OSA PR274.

## Validation boundaries

The portable PowerShell suite validates configuration/task policy, parsing, and runs the actual installer against disposable filesystem fixtures with Windows task/process/ACL/native-installer calls replaced at their OS seam.
It verifies WhatIf, repeat enrollment, conflicts, session/fingerprint preservation, foreign-listener rejection, and staged fresh-install orchestration.
The native helper suite separately exercises 28 TCP/protocol/input-generation tests without capturing or controlling a desktop.
The helper can be built and published for Windows x64 and ARM64; the complete published OSA runtime remains Windows x64.
Windows ARM64 native-runtime distribution is not implied by a successful ARM64 helper compilation.

No actual Windows ACL application, Task Scheduler registration, OSA Windows startup, live enrollment, owner desktop access, or release deployment was performed during this cross-platform validation.
Validate those operations in an authorized native Windows session before declaring end-to-end acceptance.
The release workflow additions build/package assets; they were not executed remotely by this task.
