# macOS desktop capture

OSA runs `priv/helpers/osa-screen-capture-darwin`, built from `native/macos/ScreenShare`.
The Elixir adapter accepts a complete `PORT=<number>` line only after the helper has bound its loopback listener.
The default port is ephemeral, so concurrent sessions do not contend for port 5900.
An explicit helper override requires both `OSA_DESKTOP_HELPER_OVERRIDE` and its matching `OSA_DESKTOP_HELPER_SHA256`.

## Lifetime and memory safeguards

- At most two helpers per user can hold capture slots across backends and worktrees.
- A dedicated watchdog checks physical footprint, including compressed memory, every 250 milliseconds and exits above 512 MiB.
- The 512 MiB value is an exit threshold, not an operating-system allocation limit; sampling can permit transient overshoot.
- Helpers exit on SIGTERM, SIGINT, stdin EOF, parent death, or 60 seconds without client activity or frame requests.
- The watchdog exits independently of the main run loop and does not wait for capture shutdown to complete.
- The main run loop remains live, capture callbacks run on a serial queue with autorelease pools, and only the latest converted frame is retained.
- ScreenCaptureKit uses three queued surfaces and output dimensions no greater than 4096 by 3072 pixels.
- A slow VNC client has at most one frame send in flight; clipboard payloads are bounded to 1 MiB.
- The Elixir adapter bounds startup output, cleans failed starts, and escalates from SIGTERM to SIGKILL if the owned helper remains alive after 500 milliseconds.
- Controllers close resources on replacement, failed connection, helper exit, and shutdown.

The slot files under `/tmp/osa-screen-capture-<uid>` remain on disk deliberately.
Kernel file locks release on process death; removing an occupied lock file would break cross-process exclusion.
Lower memory and idle thresholds are available through `--max-memory-mb` and `--idle-seconds` for testing.
These flags cannot raise the production ceilings.

## Optional host backstop

`scripts/capture_watchdog.py` independently checks only this user's processes whose executable is exactly `osa-screen-capture-darwin`.
It terminates orphan helpers, helpers over 768 MiB footprint, and helpers beyond the two-process allowance.
It checks executable identity and process birth time again before signaling, and escalates after 500 milliseconds if SIGTERM is ignored.
A user LaunchAgent can run it every 10 seconds to protect against older executables restored by an update or worktree.
`--dry-run` reports eligible processes without signaling them; `--pid` restricts checks to one process for testing.
It does not inspect or terminate other coding agents.

## Build and verify

```sh
sh native/macos/ScreenShare/test.sh
mix test --no-start test/optimal_system_agent/open_computers/executor/direct/desktop/
```

The native test script rebuilds the release helper, exercises real subprocess lifetime failures, and runs a sustained synthetic frame pipeline with a slow-reader phase.
Synthetic frames pass through the production conversion and RFB code without reading the user's screen.
The macOS release workflow runs this gate before packaging the helper.

Real screen recording is excluded from ordinary `mix test` runs.
It is opt-in with `--include macos_native` and requires macOS Screen & System Audio Recording permission for the helper or its responsible application.
When permission is denied, the helper currently serves a stub frame, so a successful handshake alone does not prove live capture.

## September 7, 2026 incident

The 06:38:05 CDT Jetsam report named `osa-screen-capture-darwin` as the largest process.
Eight helpers accounted for 344.69 GiB of reported pages combined; these figures include compressed accounting and are not a claim of 344.69 GiB of physical RAM.
Six helpers had binary UUID `C6A1CC9D-C79B-345B-9A8B-955738503A83`, matching the old development helper; two had UUID `D665645C-EF62-3662-B4AC-4B704B7204A4`.
September 2 reports also showed 28 helpers and approximately 337 GiB by 04:52.

The old executable was reproduced ignoring SIGTERM and surviving owner-pipe EOF.
A process sample confirmed its main thread blocked in `_dispatch_semaphore_wait_slow` while its signal handlers were scheduled on the main queue.
The macOS native test spawned this helper and sent only SIGTERM; repeated runs could therefore leave processes alive after the test VM exited.
Startup failures and replaced controller sessions had additional resource-cleanup gaps.
The older development checkout did not rebuild the tracked helper in releases.
Current main already repairs native rebuilding; this change preserves that repair and adds the lifecycle and frame-pipeline gate.

These escape paths are reproduced and repaired.
The allocation-level cause of the historical live-capture growth is not yet established: the investigating terminal was denied screen-recording permission.
The synthetic frame test validates conversion, network backpressure and bounded memory, but does not replace a live ScreenCaptureKit soak test.
