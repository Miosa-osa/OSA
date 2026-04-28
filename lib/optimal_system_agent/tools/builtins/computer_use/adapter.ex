defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter do
  @moduledoc """
  Behaviour contract for computer use platform adapters.

  Each adapter implements platform-native commands for desktop interaction.
  """

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters

  @callback available?() :: boolean()
  @callback screenshot(opts :: map()) :: {:ok, String.t()} | {:error, String.t()}
  @callback click(x :: integer(), y :: integer()) :: :ok | {:error, String.t()}
  @callback double_click(x :: integer(), y :: integer()) :: :ok | {:error, String.t()}
  @callback type_text(text :: String.t()) :: :ok | {:error, String.t()}
  @callback key_press(combo :: String.t()) :: :ok | {:error, String.t()}
  @callback scroll(direction :: String.t(), amount :: integer()) :: :ok | {:error, String.t()}
  @callback move_mouse(x :: integer(), y :: integer()) :: :ok | {:error, String.t()}
  @callback drag(from_x :: integer(), from_y :: integer(), to_x :: integer(), to_y :: integer()) ::
              :ok | {:error, String.t()}
  @callback get_tree() :: {:ok, list()} | {:error, String.t()}

  @doc """
  Detect the current platform. Priority: config override → OS detection → env vars.
  """
  @spec detect_platform() :: :macos | :linux_x11 | :linux_wayland | :unknown
  def detect_platform do
    case Application.get_env(:optimal_system_agent, :computer_use_platform) do
      nil -> detect_from_os()
      platform when is_atom(platform) -> platform
      platform when is_binary(platform) -> String.to_existing_atom(platform)
    end
  rescue
    _ -> detect_from_os()
  end

  @doc """
  Map a platform atom to its concrete adapter module.
  """
  @spec adapter_for(atom()) :: {:ok, module()} | {:error, String.t()}
  def adapter_for(:macos), do: {:ok, Adapters.MacOS}
  def adapter_for(:linux_x11), do: {:ok, Adapters.LinuxX11}
  def adapter_for(:linux_wayland), do: {:error, "Wayland adapter not yet implemented"}

  def adapter_for(:unknown),
    do:
      {:error,
       "No display server detected (no DISPLAY or WAYLAND_DISPLAY). Computer use requires a desktop environment."}

  def adapter_for(platform), do: {:error, "Unknown platform: #{platform}"}

  # ── Private ──────────────────────────────────────────────────────────

  defp detect_from_os do
    case :os.type() do
      {:unix, :darwin} ->
        :macos

      {:unix, :linux} ->
        cond do
          System.get_env("WAYLAND_DISPLAY") not in [nil, ""] -> :linux_wayland
          System.get_env("DISPLAY") not in [nil, ""] -> :linux_x11
          # headless — no display server
          true -> :unknown
        end

      _ ->
        :unknown
    end
  end
end
