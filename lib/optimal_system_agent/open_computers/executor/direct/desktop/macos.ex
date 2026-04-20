defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOS do
  @moduledoc """
  macOS desktop streaming helper.

  Currently a stub — returns `:unsupported_platform` until the ScreenCaptureKit
  integration is implemented.

  TODO(#23): Implement macOS desktop streaming using ScreenCaptureKit.
  The implementation should:
    1. Use ScreenCaptureKit (macOS 12.3+) to capture the display as a VNC-compatible
       byte stream, or start a macOS-compatible VNC server (e.g., Apple Remote Desktop
       or an open-source alternative like LibVNCServer compiled for macOS).
    2. Bind to 127.0.0.1:5900 so the DesktopController can connect identically.
    3. Handle permissions: ScreenCaptureKit requires `com.apple.security.screen-recording`
       entitlement + user consent via `SCStreamConfiguration`.
    4. Return `{:ok, os_pid}` on success, `{:error, :permission_denied}` when consent
       is denied, or `{:error, :failed_to_start}` on other errors.
  """

  require Logger

  @doc """
  Start macOS desktop streaming. Currently unsupported.

  Returns `{:error, :unsupported_platform}` until issue #23 is resolved.
  """
  @spec start(map()) :: {:error, :unsupported_platform}
  def start(_opts \\ %{}) do
    Logger.info("[Desktop.MacOS] macOS desktop streaming not yet implemented (see issue #23)")
    {:error, :unsupported_platform}
  end

  @doc "Stop macOS desktop streaming. No-op while unsupported."
  @spec stop(any()) :: :ok
  def stop(_), do: :ok
end
