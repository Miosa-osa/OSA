defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Windows do
  @moduledoc """
  Windows desktop streaming helper.

  Currently a stub — returns `:unsupported_platform` until the Windows Desktop
  Duplication API integration is implemented.

  TODO(#24): Implement Windows desktop streaming using the Desktop Duplication API.
  The implementation should:
    1. Use a Go/Rust native extension (via NIF or Port) that calls the DXGI Desktop
       Duplication API to capture frames and encode them as RFB protocol bytes, or
       wrap an existing VNC server like TightVNC/UltraVNC that exposes :5900 locally.
    2. Bind to 127.0.0.1:5900 so the DesktopController can connect identically.
    3. Handle UAC / consent for screen capture on Windows 10/11.
    4. Return `{:ok, os_pid}` on success, `{:error, :permission_denied}` when consent
       is denied, or `{:error, :failed_to_start}` on other errors.
  """

  require Logger

  @doc """
  Start Windows desktop streaming. Currently unsupported.

  Returns `{:error, :unsupported_platform}` until issue #24 is resolved.
  """
  @spec start(map()) :: {:error, :unsupported_platform}
  def start(_opts \\ %{}) do
    Logger.info("[Desktop.Windows] Windows desktop streaming not yet implemented (see issue #24)")
    {:error, :unsupported_platform}
  end

  @doc "Stop Windows desktop streaming. No-op while unsupported."
  @spec stop(any()) :: :ok
  def stop(_), do: :ok
end
