# OSA Wayland desktop runtime requirements

This helper is dynamically linked and requires GStreamer 1.20 or newer, its app/video/base libraries, the PipeWire GStreamer plugin, and the base plugin set.
On Ubuntu 22.04 or 24.04 the administrator can install `gstreamer1.0-pipewire gstreamer1.0-plugins-base` with the distribution package manager.
Those packages resolve the corresponding shared-library dependencies for that distribution.
The OSA installer does not install these packages or change global desktop settings silently.

A logged-in Wayland desktop must provide PipeWire, a user D-Bus session, `xdg-desktop-portal`, and a compositor-specific backend implementing RemoteDesktop and ScreenCast.
GNOME/KDE support must be checked against the installed portal backend; the generic portal package or Wayland environment variables alone are insufficient.
The helper uses the existing user's `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, and `DBUS_SESSION_BUS_ADDRESS`.
It must not borrow a different user's environment or run a hidden desktop to bypass consent.

`osa-screen-capture-wayland --check` checks prerequisites without creating a capture session.
A successful check is not consent or proof of working capture/input.
Actual use prompts for fresh monitor and input consent, with no persisted restore token.
Missing shared libraries may prevent even the check from starting; surface loader diagnostics as unavailable prerequisites.

The Linux x64 release helper is built on the same Ubuntu 22.04 baseline as OSA's Linux release.
It is covered by the enclosing OSA release tarball's SHA-256 sidecar.
No separate unsigned helper download or runtime compilation is needed.
Readiness and native QA must remain separate: this package has automated build/protocol checks, not a guarantee of every compositor or device configuration.
