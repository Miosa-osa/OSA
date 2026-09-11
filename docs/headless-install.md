# Headless OpenComputers installation

The prebuilt installer supports `OSA_INSTALL_MODE=headless` for service hosts that do not need the terminal UI.
It installs the bundled Erlang runtime and the Bash `osa` launcher without downloading, installing, or executing the standalone Rust TUI.
This avoids the TUI's ALSA dependency on minimal Linux servers.
It does not remove native dependencies required by the backend.

```sh
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh -o install-osa.sh
OSA_INSTALL_MODE=headless bash install-osa.sh
```

`OSA_HOME` still defaults to `$HOME/.osa`, and `OSA_VERSION` still accepts a pinned release tag.
Bash, a download tool with CA certificates, tar/gzip, and sha256sum or shasum are required.
Headless install and update fail if the runtime checksum sidecar is unavailable, hashing is unavailable, or the checksum does not match.
No system packages are installed automatically.

## Saved mode and existing installations

The successful installation records exactly `headless\n` or `full\n` in `$OSA_HOME/install_mode`.
An explicit `OSA_INSTALL_MODE` takes precedence over that file.
Without an explicit setting, reinstall and `osa update` preserve the saved mode.
An installation without a saved mode is treated as legacy `full`; a new installation defaults to `full`.
An invalid setting or unreadable/invalid saved mode fails instead of silently selecting another mode.

Automation should preserve the saved mode, preserve legacy full installations, and explicitly select headless only for a new service installation or a requested conversion.
After invoking the installer, check the exit status, the executable launcher, and the exact saved mode before proceeding.
Checking the mode prevents an older installer that ignores `OSA_INSTALL_MODE` from being reported as a successful headless installation.

Explicitly changing an existing full installation to headless does not delete its TUI or change its shell profiles.
The retained TUI is disabled and no longer updated in headless mode.
To resume using and updating it, rerun the installer with `OSA_INSTALL_MODE=full`.
Fresh headless installations do not edit shell profiles; use the absolute launcher path in a service.

`osa serve`, `osa opencomputers`, `osa doctor`, `osa setup`, and `osa version` work without the TUI.
An interactive invocation such as bare `osa`, `osa resume`, or `osa overdrive` exits with an explanation before warming a background daemon.
Headless `osa update` updates the backend and launcher, preserves the mode, and exits without launching a TUI or prompting to do so.
The updater refuses a target launcher without headless support, including historical release launchers, before an upgrade stops the service or swaps its runtime.
The first release containing this installer change must be published before the normal tag-based update path supports headless installations.

## Service environment

Use the same service account, `HOME`, and `OSA_HOME` for login and runtime startup.
Login persists the host configuration with mode 0600.
Set `OSA_OPEN_COMPUTERS_ENABLED=true` in the service environment and run the launcher with `serve` in the foreground.
The environment variable activates host mode without an enable marker or a call to `osa opencomputers enable`.
Use a UTF-8 locale, such as `LANG=C.UTF-8` on Debian.

Running as root does not provide OpenComputers interactive PTY sessions: erlexec refuses root.
Use a non-root service identity if PTY is required, and verify PTY separately before advertising that capability.
A successful installation, local health response, or local mock handshake does not establish authenticated MIOSA enrollment, remote execution, or desktop functionality.

## Validation

The offline regression suite executes the real installer and generated launcher against small checksummed fixtures.
It covers full/headless install, existing-user preservation, reinstall, same-version repair, version upgrades, launcher re-exec, checksum failures, invalid mode, and rejection of a legacy launcher.
It requires Python 3.9 or later, Bash, tar, and a checksum tool; no Elixir dependencies are needed for the standalone run.
The ExUnit wrapper also runs it in the normal test suite.

```sh
python3 test/shell/install_modes_test.py
elixir -e 'ExUnit.start()' -r test/scripts/install_modes_test.exs -r test/scripts/launcher_args_test.exs
```

For native compatibility, use the real published release in a disposable amd64 Debian 12 container without ALSA or a TUI.
Copy the candidate `scripts/install.sh` to `/tmp/candidate-install.sh` in that container, install only curl, ca-certificates, libstdc++6, libncurses6, libssl3, and Python for the smoke harness, and run:

```sh
mkdir -p /smoke-home /evidence
HOME=/smoke-home OSA_HOME=/smoke-home/.osa OSA_VERSION=v1.0.195 OSA_INSTALL_MODE=headless bash /tmp/candidate-install.sh
```

Run this command inside the container, never against a user's real HOME.
The installer verifies the published tarball checksum before extraction.
To test same-version and v1.0.194-to-v1.0.195 updates before this change is released, set the existing `OSA_LAUNCHER_RAW_BASE` test override to a local `file://` directory containing the candidate installer at `v1.0.195/scripts/install.sh`.
Leave the runtime asset URLs and checksums pointing at the actual published releases.
This tests the candidate launcher with published binaries; it must not be described as a released headless updater.

Disconnect the task container from Docker networking, copy `test/shell/headless_runtime_smoke.py` into it, and run that script with Python.
The script refuses to run outside Docker or with a configured network route, asserts TUI/ALSA/marker absence, writes only a dummy host key, verifies a local WebSocket upgrade and binary hello, checks HTTP health, and stops its runtime process group.
It retains focused logs in `/evidence` without copying private fingerprint files or release cookies.
It deliberately sends no backend acceptance response and makes no enrollment or capability claim.

The v1.0.195 Debian 12 smoke used tarball SHA256 `60299959594885ae8b2fec3fa60e9df5c42e35632ee58f62eef462b800cfe23e`.
The original full installer failed without `libasound.so.2`; the candidate headless installer and updater succeeded without that library.
These results were obtained under Docker amd64 emulation on an arm64 host, not a physical x64 machine.
