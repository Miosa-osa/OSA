# macOS screen-capture helper

The Swift helper captures a display with ScreenCaptureKit and serves RFB 3.8 on an ephemeral IPv4 loopback port.
It announces `PORT=<number>` only when the listener is ready.
The Elixir adapter owns its lifetime through a subprocess pipe.

Build and test from any directory:

```sh
sh native/macos/ScreenShare/test.sh
```

`build.sh` uses `swiftc` and the macOS SDK, supporting Command Line Tools installations without Swift Package Manager.
Release builds install the generated executable into `priv/helpers/osa-screen-capture-darwin`.
The test script covers process cleanup, memory and concurrency limits, live frame conversion using synthetic buffers, and a slow network reader.
It does not require screen-recording permission.

For manual use, keep stdin open:

```sh
native/macos/ScreenShare/.build/release/ScreenShare --stub --port 5901
```

Remove `--stub` for real capture, which requires macOS screen-recording permission.
A denied capture currently falls back to a solid-color frame.
The helper exits after 60 seconds without activity, when its parent exits or closes stdin, or when a resource limit is reached.

See [macOS desktop capture](../../../docs/macos-desktop.md) for the limits, override contract, incident evidence, and live-verification requirements.
