# Windows helper implementation validation

Recorded 2026-09-11 in the OSA PR274 worktree.
Validation host: macOS ARM64, .NET SDK 8.0.425.
No Windows capture or input APIs were executed.

## Reproduced failures

The first loopback regression against the original helper failed with `Advertised unusable helper endpoint: PORT=0`.
After fixing the announced port, the invalid-version regression failed with `Invalid RFB version was accepted`.
That run also exposed the old listener shutdown loop repeatedly reporting `Not listening`.
Both regressions pass with the replacement server.

## Results

- Portable protocol/input-generation suite: **28 tests passed**.
- Windows x64 Release build/publish: **passed, zero warnings and errors**.
- Windows ARM64 Release build/publish: **passed, zero warnings and errors**.
- Executable format check: x64 is Windows PE32+ x86-64; ARM64 is Windows PE32+ Aarch64.
- Whitespace formatting and scoped `git diff --check`: passed.

```sh
dotnet run --project native/windows/ScreenShare/tests/ProtocolTests.csproj
dotnet publish native/windows/ScreenShare/ScreenShare.csproj -c Release -r win-x64 --self-contained true -o /private/tmp/osa-windows-helper-x64
dotnet publish native/windows/ScreenShare/ScreenShare.csproj -c Release -r win-arm64 --self-contained true -o /private/tmp/osa-windows-helper-arm64
```

The local SDK used for this run is `/private/tmp/osa-windows-dotnet/dotnet`.
These artifact paths are local validation outputs, not published releases.

| Artifact | SHA-256 |
| --- | --- |
| x64 `osa-screen-capture-windows.exe` | `e0cb07583a5ce9267ed09e4ccc6beeaf78133e2f8cbf72b37081d12806e1e482` |
| ARM64 `osa-screen-capture-windows.exe` | `60a1c4f5d487ebf4cc01bf05349642e822c3ddcbae00645ae4598815d60a8abc` |

## Integration handoff

The initial helper implementation was confined to `native/windows/ScreenShare/**` and `docs/windows-desktop.md`.
The authorized continuation adds Windows enrollment scripts, release packaging, and `docs/windows-onboarding.md`.
The release workflow now builds and checks the x64 helper at `priv/helpers/osa-screen-capture-windows.exe` before packaging.
The integration owner must pass `--allow-input` only for an authorized control session.
No Elixir or macOS edits, actual task installation, deployment, or PR creation were performed by the Windows implementation owner.
No arguments means read-only capture.
The controller must close the RFB bridge and owner stdin before forced process termination to allow held-input cleanup.

Native Windows permissions, actual captured pixels, real input, mixed-DPI/multi-monitor/RDP behavior, signing, release installation, performance, and authenticated MIOSA browser acceptance remain unverified.
The native QA checklist and implementation limitations are in `docs/windows-desktop.md`.

## Enrollment continuation

The portable PowerShell suite passes 11 policy/parser/installer-fixture groups using PowerShell 7.6.6 on macOS ARM64.
The actual entrypoint runs against disposable filesystem fixtures, with only the Windows process/task/ACL and native installer boundary replaced.
Repeated enrollment preserves configuration bytes and modification time, fingerprint, sessions, and task registration.
Conflicting credentials, a foreign listener, and a privileged task fail without overwriting or stopping existing work.
WhatIf is read-only, and explicit fresh installation stages and promotes without touching another installation.
These tests do not verify Windows PowerShell 5.1 execution, actual Windows ACLs, Task Scheduler, or live MIOSA registration.
