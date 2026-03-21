defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.RemoteSSH do
  @moduledoc """
  Computer use adapter that forwards input/output primitives to a remote machine
  over SSH.

  ## Configuration

  Set in `config.exs` (or environment-specific config):

      config :optimal_system_agent, :computer_use_remote,
        host: "192.168.1.100",
        port: 22,
        user: "ubuntu",
        key_path: "~/.ssh/id_rsa",    # path to private key (optional — omit for agent auth)
        remote_display: ":0",          # X11 DISPLAY env var on the remote host
        remote_platform: :linux_x11   # :linux_x11 (default) | :linux_wayland

  ## Authentication

  The adapter uses `BatchMode=yes`, so interactive password prompts are
  disabled. Only public-key or SSH agent authentication is supported.

  ## Security notes

  - `StrictHostKeyChecking=no` is used for convenience when connecting to VMs
    and containers where the host key changes frequently. Set this to `accept-new`
    or `yes` for production environments by forking this adapter.
  - All user-supplied text is shell-escaped before being interpolated into remote
    command strings, preventing command injection.

  ## Screenshot transfer

  Screenshots are captured remotely via `maim` (X11) or `grim` (Wayland), then
  transferred to the local host via `scp`. The remote file is deleted after
  retrieval. Local files land in `~/.osa/screenshots/`.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Shared

  require Logger

  # ---------------------------------------------------------------------------
  # Behaviour: platform / availability
  # ---------------------------------------------------------------------------

  def platform, do: :remote_ssh

  @impl true
  def available? do
    config = get_config()
    host = config[:host]

    cond do
      is_nil(host) or host == "" ->
        false

      System.find_executable("ssh") == nil ->
        false

      true ->
        true
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
      case remote_platform() do
        :linux_wayland -> build_wayland_screenshot_cmd(remote_path, region)
        _ -> build_x11_screenshot_cmd(remote_path, region)
      end

    with {:ok, _} <- ssh_cmd(capture_cmd),
         {:ok, local_path} <- fetch_remote_screenshot(remote_path) do
      {:ok, "Screenshot saved to #{local_path}. Use file_read to view it."}
    end
  end

  defp build_x11_screenshot_cmd(path, nil) do
    display = remote_display()
    "DISPLAY=#{display} maim #{path}"
  end

  defp build_x11_screenshot_cmd(path, %{"x" => x, "y" => y, "width" => w, "height" => h}) do
    display = remote_display()
    "DISPLAY=#{display} maim --geometry #{w}x#{h}+#{x}+#{y} #{path}"
  end

  defp build_x11_screenshot_cmd(path, _), do: build_x11_screenshot_cmd(path, nil)

  defp build_wayland_screenshot_cmd(path, nil) do
    "grim #{path}"
  end

  defp build_wayland_screenshot_cmd(path, %{"x" => x, "y" => y, "width" => w, "height" => h}) do
    "grim -g #{Shared.shell_escape("#{x},#{y} #{w}x#{h}")} #{path}"
  end

  defp build_wayland_screenshot_cmd(path, _), do: build_wayland_screenshot_cmd(path, nil)

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y) do
    cmd = xdotool_or_ydotool("mousemove #{x} #{y} click 1")

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def double_click(x, y) do
    cmd = xdotool_or_ydotool("mousemove #{x} #{y} click --repeat 2 1")

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def move_mouse(x, y) do
    cmd = xdotool_or_ydotool("mousemove #{x} #{y}")

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    cmd =
      xdotool_or_ydotool(
        "mousemove #{start_x} #{start_y} mousedown 1 mousemove #{end_x} #{end_y} mouseup 1"
      )

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    escaped = Shared.shell_escape(text)

    cmd =
      case remote_platform() do
        :linux_wayland ->
          "ydotool type --clearmodifiers -- #{escaped}"

        _ ->
          display = remote_display()
          "DISPLAY=#{display} xdotool type --clearmodifiers -- #{escaped}"
      end

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def key_press(combo) do
    xdotool_combo = Shared.parse_xdotool_combo(combo)

    cmd =
      case remote_platform() do
        :linux_wayland ->
          "ydotool key #{xdotool_combo}"

        _ ->
          display = remote_display()
          "DISPLAY=#{display} xdotool key #{xdotool_combo}"
      end

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: scroll
  # ---------------------------------------------------------------------------

  @impl true
  def scroll(direction, amount) do
    button = Shared.scroll_button(direction)
    cmd = xdotool_or_ydotool("click --repeat #{amount} #{button}")

    case ssh_cmd(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: accessibility tree
  # ---------------------------------------------------------------------------

  @impl true
  def get_tree do
    {:error, "Accessibility tree not yet implemented for RemoteSSH. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Public utilities
  # ---------------------------------------------------------------------------

  @doc """
  Test SSH connectivity to the configured remote host.

  Returns `{:ok, %{connected: true, system: uname_output}}` on success or
  `{:error, reason}` on failure. Useful for health checks and config validation.
  """
  @spec test_connection() :: {:ok, map()} | {:error, String.t()}
  def test_connection do
    case ssh_cmd("uname -a") do
      {:ok, output} -> {:ok, %{connected: true, system: output}}
      {:error, _} = err -> err
    end
  end

  @doc "Delegates to `Shared.parse_xdotool_combo/1`."
  @spec parse_key_combo(String.t()) :: String.t()
  def parse_key_combo(combo), do: Shared.parse_xdotool_combo(combo)

  # ---------------------------------------------------------------------------
  # SSH / SCP execution
  # ---------------------------------------------------------------------------

  @doc false
  @spec ssh_cmd(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ssh_cmd(command) do
    config = get_config()
    ssh_args = build_ssh_args(config) ++ ["#{config[:user] || "root"}@#{config[:host]}", command]

    Logger.debug("[RemoteSSH] ssh #{Enum.join(ssh_args, " ")}")

    case System.cmd("ssh", ssh_args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("[RemoteSSH] ssh exited #{code}: #{trimmed}")
        {:error, "SSH command failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("[RemoteSSH] ssh raised: #{Exception.message(e)}")
      {:error, "SSH raised: #{Exception.message(e)}"}
  end

  defp fetch_remote_screenshot(remote_path) do
    config = get_config()
    local_dir = ensure_screenshot_dir()
    local_path = Path.join(local_dir, "remote_screenshot_#{timestamp()}.png")

    scp_args = build_scp_args(config, remote_path, local_path)

    Logger.debug("[RemoteSSH] scp #{Enum.join(scp_args, " ")}")

    case System.cmd("scp", scp_args, stderr_to_stdout: true) do
      {_, 0} ->
        # Best-effort remote cleanup — ignore errors
        ssh_cmd("rm -f #{remote_path}")
        {:ok, local_path}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("[RemoteSSH] scp exited #{code}: #{trimmed}")
        {:error, "SCP failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("[RemoteSSH] scp raised: #{Exception.message(e)}")
      {:error, "SCP raised: #{Exception.message(e)}"}
  end

  defp build_ssh_args(config) do
    base = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "ConnectTimeout=10",
      "-o", "BatchMode=yes"
    ]

    base = if config[:port] && config[:port] != 22 do
      base ++ ["-p", "#{config[:port]}"]
    else
      base
    end

    if config[:key_path] do
      base ++ ["-i", Path.expand(config[:key_path])]
    else
      base
    end
  end

  defp build_scp_args(config, remote_path, local_path) do
    base = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "ConnectTimeout=10",
      "-o", "BatchMode=yes"
    ]

    base = if config[:port] && config[:port] != 22 do
      base ++ ["-P", "#{config[:port]}"]
    else
      base
    end

    base = if config[:key_path] do
      base ++ ["-i", Path.expand(config[:key_path])]
    else
      base
    end

    user = config[:user] || "root"
    host = config[:host]

    base ++ ["#{user}@#{host}:#{remote_path}", local_path]
  end

  @doc "Delegates to `Shared.shell_escape/1`."
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(text), do: Shared.shell_escape(text)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_config do
    Application.get_env(:optimal_system_agent, :computer_use_remote, [])
  end

  defp remote_platform do
    get_config()[:remote_platform] || :linux_x11
  end

  defp remote_display do
    get_config()[:remote_display] || ":0"
  end

  # Returns the xdotool command with DISPLAY set (X11) or ydotool command
  # (Wayland), pre-pended with the appropriate environment.
  defp xdotool_or_ydotool(args) do
    case remote_platform() do
      :linux_wayland ->
        "ydotool #{args}"

      _ ->
        display = remote_display()
        "DISPLAY=#{display} xdotool #{args}"
    end
  end

  defp ensure_screenshot_dir, do: Shared.ensure_screenshot_dir()

  defp timestamp, do: System.system_time(:millisecond)
end
