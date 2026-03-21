defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.PlatformVM do
  @moduledoc """
  Computer use adapter that forwards desktop control commands to a Firecracker
  microVM managed by the Sprites.dev sandbox backend
  (`OptimalSystemAgent.Sandbox.Sprites`).

  The VMs run Linux with Xvfb + xdotool, so all GUI primitives use the same
  X11 command set as the Docker and LinuxX11 adapters.

  ## Configuration

      config :optimal_system_agent, :computer_use_vm,
        sprite_id: "abc123",   # Sprites.dev VM identifier (required)
        display: ":1"          # DISPLAY env var inside the VM

  ## Availability

  The adapter reports `available?/0 == true` only when:

  1. Configuration key `:computer_use_vm` is present and contains a non-empty
     `:sprite_id` value.
  2. `Sprites.available?()` returns true (i.e. `SPRITES_TOKEN` is set).

  ## Screenshot transfer

  Since we cannot SCP from a Sprites VM, screenshots are captured via
  `maim` inside the VM, then base64-encoded in-VM and decoded on the host.
  Local files land in `~/.osa/screenshots/`.

  ## Key Notes

  - All GUI commands are run via `DISPLAY=<display> <cmd>` inside the VM.
  - `type_text/1` shell-escapes the input to prevent injection.
  - `get_accessibility_tree/1` is not implemented -- returns a descriptive error
    so callers can fall back to screenshot mode.
  - `test_connection/0` is a public diagnostic helper, not part of the Adapter
    behaviour contract.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  alias OptimalSystemAgent.Sandbox.Sprites
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Shared

  require Logger

  # ---------------------------------------------------------------------------
  # Behaviour: platform / availability
  # ---------------------------------------------------------------------------

  def platform, do: :platform_vm

  @impl true
  def available? do
    config = get_config()

    case config[:sprite_id] do
      nil -> false
      "" -> false
      _sprite_id -> sprites_available?()
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: screenshot
  # ---------------------------------------------------------------------------

  @impl true
  def screenshot(opts) do
    remote_path = "/tmp/osa_screenshot_#{timestamp()}.png"
    region = Map.get(opts, "region")

    capture_cmd =
      case region do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          "maim --geometry #{w}x#{h}+#{x}+#{y} #{remote_path}"

        _ ->
          "maim #{remote_path}"
      end

    # Capture, then base64-encode in-VM (no SCP from Sprites VMs)
    with {:ok, _output, 0} <- vm_exec(capture_cmd),
         {:ok, b64_output, 0} <- vm_exec("base64 -w 0 #{remote_path}"),
         {:ok, local_path} <- decode_and_save_screenshot(b64_output) do
      # Best-effort remote cleanup
      vm_exec("rm -f #{remote_path}")
      {:ok, "Screenshot saved to #{local_path}. Use file_read to view it."}
    else
      {:ok, _output, code} ->
        {:error, "Screenshot command failed (exit #{code})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y) do
    case vm_exec("xdotool mousemove #{x} #{y} click 1") do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool click failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def double_click(x, y) do
    case vm_exec("xdotool mousemove #{x} #{y} click --repeat 2 1") do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool double-click failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def move_mouse(x, y) do
    case vm_exec("xdotool mousemove #{x} #{y}") do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool mousemove failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    cmd =
      "xdotool mousemove #{start_x} #{start_y} mousedown 1 " <>
        "mousemove #{end_x} #{end_y} mouseup 1"

    case vm_exec(cmd) do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool drag failed (exit #{code})"}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    case vm_exec("xdotool type --clearmodifiers #{Shared.shell_escape(text)}") do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool type failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def key_press(combo) do
    xdotool_combo = Shared.parse_xdotool_combo(combo)

    case vm_exec("xdotool key #{xdotool_combo}") do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool key failed (exit #{code})"}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: scroll
  # ---------------------------------------------------------------------------

  @impl true
  def scroll(direction, amount) do
    button = Shared.scroll_button(direction)

    case vm_exec("xdotool click --repeat #{amount} #{button}") do
      {:ok, _, 0} -> :ok
      {:ok, _, code} -> {:error, "xdotool scroll failed (exit #{code})"}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: accessibility tree
  # ---------------------------------------------------------------------------

  @impl true
  def get_tree do
    {:error, "Accessibility tree not yet implemented for PlatformVM adapter. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Public diagnostic helper
  # ---------------------------------------------------------------------------

  @doc """
  Test Sprites VM connectivity.

  Runs `uname -a && which xdotool` inside the VM to confirm the environment
  is healthy. Returns `{:ok, info_map}` on success or `{:error, reason}` on
  failure.

  Not part of the `Adapter` behaviour -- intended for health checks and
  debugging only.
  """
  @spec test_connection() :: {:ok, map()} | {:error, String.t()}
  def test_connection do
    config = get_config()
    sprite_id = config[:sprite_id]

    case vm_exec("uname -a && which xdotool") do
      {:ok, output, 0} ->
        preview =
          case sprites_preview_url(sprite_id) do
            {:ok, url} -> url
            _ -> nil
          end

        {:ok, %{connected: true, sprite_id: sprite_id, system: output, preview_url: preview}}

      {:ok, output, code} ->
        {:error, "VM health check failed (exit #{code}): #{output}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Key combo parsing
  # ---------------------------------------------------------------------------

  @doc "Delegates to `Shared.parse_xdotool_combo/1`."
  @spec parse_key_combo(String.t()) :: String.t()
  def parse_key_combo(combo), do: Shared.parse_xdotool_combo(combo)

  @doc "Delegates to `Shared.shell_escape/1`."
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(text), do: Shared.shell_escape(text)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Execute a command inside the Sprites VM with DISPLAY set.
  # Returns the raw Sprites.execute/2 result: {:ok, output, exit_code} | {:error, reason}
  defp vm_exec(command) do
    config = get_config()
    sprite_id = config[:sprite_id]
    display = config[:display] || ":1"

    full_command = "DISPLAY=#{display} #{command}"

    Logger.debug("[PlatformVM] executing in sprite #{sprite_id}: #{full_command}")

    case sprites_execute(full_command, sprite_id: sprite_id) do
      {:ok, output, exit_code} ->
        {:ok, String.trim(output), exit_code}

      {:error, reason} ->
        Logger.warning("[PlatformVM] Sprites.execute failed: #{inspect(reason)}")
        {:error, "Sprites VM exec failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("[PlatformVM] vm_exec raised: #{Exception.message(e)}")
      {:error, "Sprites VM exec raised: #{Exception.message(e)}"}
  end

  # Decode base64-encoded PNG data and write it to the local screenshot directory.
  defp decode_and_save_screenshot(b64_data) do
    local_dir = ensure_screenshot_dir()
    local_path = Path.join(local_dir, "vm_screenshot_#{timestamp()}.png")

    case Base.decode64(String.trim(b64_data)) do
      {:ok, png_bytes} ->
        File.write!(local_path, png_bytes)
        {:ok, local_path}

      :error ->
        Logger.warning("[PlatformVM] Failed to decode base64 screenshot data")
        {:error, "Failed to decode base64 screenshot data from VM"}
    end
  rescue
    e ->
      Logger.error("[PlatformVM] screenshot save raised: #{Exception.message(e)}")
      {:error, "Screenshot save failed: #{Exception.message(e)}"}
  end

  defp ensure_screenshot_dir, do: Shared.ensure_screenshot_dir()

  defp get_config do
    Application.get_env(:optimal_system_agent, :computer_use_vm, [])
  end

  defp timestamp, do: System.system_time(:millisecond)

  # ---------------------------------------------------------------------------
  # Guarded Sprites helpers — degrade gracefully when the module is absent
  # ---------------------------------------------------------------------------

  defp sprites_available? do
    if Code.ensure_loaded?(Sprites) do
      Sprites.available?()
    else
      false
    end
  end

  defp sprites_preview_url(sprite_id) do
    if Code.ensure_loaded?(Sprites) do
      Sprites.preview_url(sprite_id)
    else
      {:error, :sprites_unavailable}
    end
  end

  defp sprites_execute(command, opts) do
    if Code.ensure_loaded?(Sprites) do
      Sprites.execute(command, opts)
    else
      {:error, :sprites_unavailable}
    end
  end
end
