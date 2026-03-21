defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Docker do
  @moduledoc """
  Computer use adapter that forwards all input/output primitives to a Docker
  container via `docker exec`.

  The primary use-case is the Anthropic computer-use reference image (or any
  container that ships Xvfb + xdotool). Screenshots are taken inside the
  container and then copied to the host via `docker cp`.

  ## Configuration

      config :optimal_system_agent, :computer_use_docker,
        container: "osa-desktop",         # container name or ID  (required)
        display: ":1",                     # DISPLAY env var inside container
        screenshot_path: "/tmp/screenshots" # directory inside container

  ## Availability

  The adapter reports `available?/0 == true` only when:

  1. Configuration key `:computer_use_docker` is present and contains a
     `:container` value.
  2. The `docker` executable is on the host `$PATH`.
  3. `docker inspect` confirms the named container is currently running.

  ## Key Notes

  - All GUI commands are run via `DISPLAY=<display> <cmd>` inside the container.
  - `type_text/1` shell-escapes the input to prevent injection.
  - `get_accessibility_tree/1` is not implemented — returns a descriptive error
    so callers can fall back to screenshot mode.
  - `test_connection/0` is a public diagnostic helper, not part of the Adapter
    behaviour contract.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Shared

  require Logger

  # ---------------------------------------------------------------------------
  # Behaviour: platform / availability
  # ---------------------------------------------------------------------------

  def platform, do: :docker

  @impl true
  def available? do
    config = get_config()

    case config[:container] do
      nil ->
        false

      "" ->
        false

      container ->
        System.find_executable("docker") != nil and container_running?(container)
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: screenshot
  # ---------------------------------------------------------------------------

  @impl true
  def screenshot(opts) do
    config = get_config()
    screenshot_dir = config[:screenshot_path] || "/tmp"
    timestamp = System.system_time(:millisecond)
    container_path = "#{screenshot_dir}/osa_screenshot_#{timestamp}.png"

    region = Map.get(opts, "region")

    capture_cmd =
      case region do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          # maim supports --geometry; scrot supports -a; try maim first
          "(maim --geometry #{w}x#{h}+#{x}+#{y} #{container_path} 2>/dev/null) || " <>
            "scrot -a #{x},#{y},#{w},#{h} #{container_path}"

        _ ->
          "(maim #{container_path} 2>/dev/null) || scrot #{container_path}"
      end

    with {:ok, _} <- docker_exec(capture_cmd),
         {:ok, local_path} <- fetch_container_screenshot(container_path) do
      {:ok, "Screenshot saved to #{local_path}. Use file_read to view it."}
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y) do
    case docker_exec("xdotool mousemove #{x} #{y} click 1") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def double_click(x, y) do
    case docker_exec("xdotool mousemove #{x} #{y} click --repeat 2 1") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def move_mouse(x, y) do
    case docker_exec("xdotool mousemove #{x} #{y}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    cmd =
      "xdotool mousemove #{start_x} #{start_y} mousedown 1 " <>
        "mousemove #{end_x} #{end_y} mouseup 1"

    case docker_exec(cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    case docker_exec("xdotool type --clearmodifiers #{Shared.shell_escape(text)}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def key_press(combo) do
    xdotool_combo = Shared.parse_xdotool_combo(combo)

    case docker_exec("xdotool key #{xdotool_combo}") do
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

    case docker_exec("xdotool click --repeat #{amount} #{button}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: accessibility tree
  # ---------------------------------------------------------------------------

  @impl true
  def get_tree do
    {:error, "Accessibility tree not yet implemented for Docker adapter. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Public diagnostic helper
  # ---------------------------------------------------------------------------

  @doc """
  Test Docker container connectivity.

  Runs `uname -a && which xdotool` inside the container to confirm the
  environment is healthy. Returns `{:ok, info_map}` on success or
  `{:error, reason}` on failure.

  Not part of the `Adapter` behaviour — intended for health checks and
  debugging only.
  """
  @spec test_connection() :: {:ok, map()} | {:error, String.t()}
  def test_connection do
    config = get_config()
    container = config[:container]

    with {:ok, _} <- check_container_running(container),
         {:ok, output} <- docker_exec("uname -a && which xdotool") do
      {:ok, %{connected: true, container: container, system: output}}
    end
  end

  # ---------------------------------------------------------------------------
  # Key combo parsing (delegates to Shared)
  # ---------------------------------------------------------------------------

  @doc "Delegates to `Shared.parse_xdotool_combo/1`."
  @spec parse_key_combo(String.t()) :: String.t()
  def parse_key_combo(combo), do: Shared.parse_xdotool_combo(combo)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Run a shell command inside the container with DISPLAY set.
  defp docker_exec(command) do
    config = get_config()
    container = config[:container]
    display = config[:display] || ":1"

    full_command = "DISPLAY=#{display} #{command}"

    case System.cmd(
           "docker",
           ["exec", container, "bash", "-c", full_command],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("docker exec exited #{code}: #{trimmed}")
        {:error, "docker exec failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("docker exec raised: #{Exception.message(e)}")
      {:error, "docker exec raised: #{Exception.message(e)}"}
  end

  # Copy a file from the container to the local host.
  # Returns {:ok, local_path} and cleans up the container-side file.
  defp fetch_container_screenshot(container_path) do
    config = get_config()
    container = config[:container]
    local_dir = ensure_local_screenshot_dir()
    timestamp = System.system_time(:millisecond)
    local_path = Path.join(local_dir, "docker_screenshot_#{timestamp}.png")

    case System.cmd(
           "docker",
           ["cp", "#{container}:#{container_path}", local_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Best-effort cleanup — ignore errors
        docker_exec("rm -f #{container_path}")
        {:ok, local_path}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("docker cp failed (exit #{code}): #{trimmed}")
        {:error, "docker cp failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("docker cp raised: #{Exception.message(e)}")
      {:error, "docker cp raised: #{Exception.message(e)}"}
  end

  # Returns true when the container is in the Running state.
  defp container_running?(container) do
    case System.cmd(
           "docker",
           ["inspect", "-f", "{{.State.Running}}", container],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  rescue
    _ -> false
  end

  # Same logic as container_running? but surfaces the error for with-chains.
  defp check_container_running(container) do
    case System.cmd(
           "docker",
           ["inspect", "-f", "{{.State.Running}}", container],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if String.trim(output) == "true" do
          {:ok, true}
        else
          {:error, "Container #{container} is not running"}
        end

      {output, _code} ->
        {:error, "Container #{container} is not running: #{String.trim(output)}"}
    end
  rescue
    e ->
      {:error, "docker inspect raised: #{Exception.message(e)}"}
  end

  defp ensure_local_screenshot_dir, do: Shared.ensure_screenshot_dir()

  defp get_config do
    Application.get_env(:optimal_system_agent, :computer_use_docker, [])
  end
end
