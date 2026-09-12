# Windows native desktop helper

This .NET 8 executable captures an actual Windows display using GDI and serves RFB 3.8 over an ephemeral loopback socket.
Input uses Windows SendInput and is disabled unless explicitly enabled with `--allow-input`.
There are no stub frames or silent capture fallbacks.

See [the Windows desktop contract](../../../docs/windows-desktop.md) for permissions, bounds, architecture, integration requirements, official references, and native acceptance.

## Build

```sh
dotnet run --project tests/ProtocolTests.csproj
dotnet publish -c Release -r win-x64 --self-contained true -o publish
```

The executable is `publish/osa-screen-capture-windows.exe`.
Use `-r win-arm64` for Windows ARM64.
The protocol tests run without a Windows desktop and never invoke capture or input APIs.

## Owner-authorized native QA only

```powershell
# View only, primary monitor, ephemeral loopback port:
.\publish\osa-screen-capture-windows.exe

# Control permission explicitly granted for this test:
.\publish\osa-screen-capture-windows.exe --allow-input

# View a second monitor:
.\publish\osa-screen-capture-windows.exe --display 1 --read-only
```

Read the reported `PORT=<n>`; do not assume port 5900.
Keep owner stdin open for the helper lifetime when launched by OSA.
Closing stdin or pressing Ctrl+C initiates cleanup.
Do not run as a service, elevate, or enable UIAccess to circumvent desktop restrictions.
