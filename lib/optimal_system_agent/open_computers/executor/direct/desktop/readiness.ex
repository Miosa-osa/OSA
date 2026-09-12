defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Readiness do
  @moduledoc """
  Non-invasive prerequisites for access to the physical desktop.

  This does not create a display, request permissions, capture pixels or grant
  remote control. Display selection alone is not proof of display access.
  """

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{HelperPath, HelperProbe}

  @doc "Select a native protocol backend; this is not a readiness or permission assertion."
  def backend(os_type \\ :os.type())

  def backend({:unix, :linux}) do
    if System.get_env("XDG_SESSION_TYPE") == "wayland" or
         nonblank?(System.get_env("WAYLAND_DISPLAY")), do: :wayland, else: :x11vnc
  end

  def backend({:unix, :darwin}), do: :macos
  def backend({:win32, _}), do: :windows
  def backend(_), do: :unsupported

  @doc """
  Inspect prerequisites without starting a helper or accessing the screen.

  `:unverified` means prerequisites exist, not that capture or input works.
  An OS name, executable, DISPLAY or RFB listener cannot prove live capture.
  This inventory must not be used as a verified-capability advertisement.
  """
  @spec check(tuple()) :: map()
  def check(os_type \\ :os.type())

  def check({:unix, :linux}) do
    if backend({:unix, :linux}) == :wayland, do: check_wayland(), else: check_x11()
  end

  def check({:unix, :darwin}), do: native(:macos, "osa-screen-capture-darwin")
  def check({:win32, _}), do: native(:windows, "osa-screen-capture-windows.exe")
  def check(_), do: report(nil, :unavailable, :unsupported_platform)

  defp check_x11 do
    with helper when is_binary(helper) <- System.find_executable("x11vnc"),
         {:ok, selected} <- display() do
      report(:x11vnc, :unverified, :live_probe_required)
      |> Map.merge(%{helper: helper, display: selected})
    else
      nil -> report(:x11vnc, :unavailable, :missing_binary)
      {:error, reason} -> report(:x11vnc, :unavailable, reason)
    end
  end

  defp check_wayland do
    if Enum.all?(
         ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"],
         &nonblank?(System.get_env(&1))
       ) do
      case native(:wayland, "osa-screen-capture-wayland") do
        %{status: :unverified, helper: path} = result ->
          case HelperProbe.check(path, "READY=wayland_portal") do
            :ok -> result
            {:error, reason} -> report(:wayland, :unavailable, reason)
          end

        result ->
          result
      end
    else
      report(:wayland, :unavailable, {:unsupported_display, :wayland_session_unavailable})
    end
  end

  defp native(backend, name) do
    path = Path.join(:code.priv_dir(:optimal_system_agent), "helpers/#{name}")

    case HelperPath.resolve(name, path, nil, "docs/#{backend}-desktop.md") do
      {:ok, helper} ->
        Map.put(report(backend, :unverified, :live_probe_required), :helper, helper)

      {:error, reason} ->
        report(backend, :unavailable, reason)
    end
  end

  defp report(backend, status, reason) do
    %{
      backend: backend,
      status: status,
      reason: reason,
      scope: :physical_desktop,
      capture: :unverified,
      control: :unverified
    }
  end

  @doc "Select an explicit display or DISPLAY, never an assumed console display."
  @spec display(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def display(explicit \\ nil) do
    selected = if is_nil(explicit), do: System.get_env("DISPLAY"), else: explicit

    cond do
      System.get_env("XDG_SESSION_TYPE") == "wayland" or
          nonblank?(System.get_env("WAYLAND_DISPLAY")) ->
        {:error,
         {:unsupported_display,
          "Wayland physical desktop requires a RemoteDesktop portal backend; x11vnc is X11-only."}}

      nonblank?(selected) ->
        {:ok, selected}

      true ->
        {:error,
         {:missing_display,
          "Set DISPLAY or select an explicit X display; native desktop does not create one."}}
    end
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
