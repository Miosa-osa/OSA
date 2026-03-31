defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11 do
  @moduledoc """
  Linux X11 adapter — uses xdotool for input and maim/scrot for screenshots.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  require Logger

  @scroll_buttons %{"up" => "4", "down" => "5", "left" => "6", "right" => "7"}


  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl true
  def available? do
    has_xdotool?() and (has_maim?() or has_scrot?())
  end

  @impl true
  def screenshot(opts \\ %{}) do
    dir = screenshots_dir()
    File.mkdir_p!(dir)

    filename = "screenshot_#{System.system_time(:millisecond)}.png"
    path = Path.join(dir, filename)

    {cmd, args} = screenshot_cmd(Map.put(opts, :path, path))
    run_cmd(cmd, args, "Screenshot")
    |> case do
      :ok -> {:ok, path}
      {:error, _} = err -> err
    end
  end

  @impl true
  def click(x, y) do
    # Click targets absolute screen coordinates — no focus restore needed
    {cmd, args} = click_cmd(x, y)
    run_cmd(cmd, args, "Click")
  end

  @impl true
  def double_click(x, y) do
    {cmd, args} = double_click_cmd(x, y)
    run_cmd(cmd, args, "Double click")
  end

  @impl true
  def type_text(text) do
    {cmd, args} = type_cmd(text)
    run_cmd(cmd, args, "Type")
  end

  @impl true
  def key_press(combo) do
    {cmd, args} = key_cmd(combo)
    run_cmd(cmd, args, "Key press")
  end

  @impl true
  def scroll(direction, amount \\ 3) do
    {cmd, args} = scroll_cmd(direction, amount)
    run_cmd(cmd, args, "Scroll")
  end

  @impl true
  def move_mouse(x, y) do
    {cmd, args} = move_mouse_cmd(x, y)
    run_cmd(cmd, args, "Move mouse")
  end

  @impl true
  def drag(from_x, from_y, to_x, to_y) do
    cmds = drag_cmd(from_x, from_y, to_x, to_y)

    Enum.reduce_while(cmds, :ok, fn {cmd, args}, :ok ->
      case run_cmd(cmd, args, "Drag") do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @impl true
  def get_tree do
    script = atspi_script_path()

    case System.cmd("python3", [script, "--max-depth", "10", "--max-elements", "100"],
           stderr_to_stdout: true, env: [{"PYTHONDONTWRITEBYTECODE", "1"}]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, elements} when is_list(elements) -> {:ok, elements}
          {:ok, _} -> {:error, "AT-SPI2 returned invalid data"}
          {:error, _} -> {:error, "AT-SPI2 JSON parse error: #{String.slice(output, 0, 200)}"}
        end

      {output, code} ->
        {:error, "AT-SPI2 failed (exit #{code}): #{String.slice(String.trim(output), 0, 200)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "AT-SPI2 unavailable: #{inspect(e)}"}
  end

  defp atspi_script_path do
    # Try priv directory first (release), then source tree (dev)
    priv = :code.priv_dir(:optimal_system_agent)

    case priv do
      path when is_list(path) ->
        Path.join(List.to_string(path), "scripts/atspi_tree.py")

      _ ->
        Path.join([File.cwd!(), "priv", "scripts", "atspi_tree.py"])
    end
  end

  # ── Public Command Generators (tested directly) ──────────────────────

  @doc "Generate screenshot command tuple {binary, args}."
  def screenshot_cmd(%{path: path, region: %{"x" => x, "y" => y, "width" => w, "height" => h}}) do
    if has_maim?() do
      {"maim", ["-g", "#{w}x#{h}+#{x}+#{y}", path]}
    else
      # scrot doesn't support region capture directly — take full screen
      {"scrot", [path]}
    end
  end

  def screenshot_cmd(%{path: path}) do
    if has_maim?() do
      {"maim", [path]}
    else
      {"scrot", [path]}
    end
  end

  @doc "Generate click command tuple."
  def click_cmd(x, y) do
    {"xdotool", ["mousemove", "--sync", "#{x}", "#{y}", "click", "1"]}
  end

  @doc "Generate double-click command tuple."
  def double_click_cmd(x, y) do
    {"xdotool", ["mousemove", "--sync", "#{x}", "#{y}", "click", "--repeat", "2", "1"]}
  end

  @doc "Generate type command tuple."
  def type_cmd(text) do
    {"xdotool", ["type", "--clearmodifiers", "--", text]}
  end

  @doc "Generate key press command tuple with cmd→super translation."
  def key_cmd(combo) do
    {"xdotool", ["key", translate_key_combo(combo)]}
  end

  @doc "Generate scroll command tuple. Direction maps to X11 button numbers."
  def scroll_cmd(direction, amount) do
    button = Map.fetch!(@scroll_buttons, direction)
    {"xdotool", ["click", "--repeat", "#{amount}", button]}
  end

  @doc "Generate move mouse command tuple."
  def move_mouse_cmd(x, y) do
    {"xdotool", ["mousemove", "--sync", "#{x}", "#{y}"]}
  end

  @doc "Generate drag as a sequence of command tuples."
  def drag_cmd(from_x, from_y, to_x, to_y) do
    [
      {"xdotool", ["mousemove", "--sync", "#{from_x}", "#{from_y}"]},
      {"xdotool", ["mousedown", "1"]},
      {"xdotool", ["mousemove", "--sync", "#{to_x}", "#{to_y}"]},
      {"xdotool", ["mouseup", "1"]}
    ]
  end

  @doc """
  Translate a key combo: cmd→super, lowercase all parts.
  Simple keys (no +) pass through as-is.
  """
  def translate_key_combo(combo) do
    if String.contains?(combo, "+") do
      combo
      |> String.split("+")
      |> Enum.map(fn
        part ->
          case String.downcase(part) do
            "cmd" -> "super"
            other -> other
          end
      end)
      |> Enum.join("+")
    else
      combo
    end
  end

  @doc """
  Safely wraps a string in single quotes for shell usage.
  Existing single quotes are escaped using the '\\'' idiom so the result
  is always safe to pass as a shell argument.

  Examples:
      shell_escape("hello world")  → "'hello world'"
      shell_escape("it's here")    → "'it'\\''s here'"
      shell_escape("")             → "''"
  """
  def shell_escape(str) when is_binary(str) do
    escaped = String.replace(str, "'", "'\\''")
    "'" <> escaped <> "'"
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp run_cmd(cmd, args, label) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "#{label} failed: #{inspect(e)}"}
  end

  defp has_xdotool?, do: System.find_executable("xdotool") != nil
  defp has_maim?, do: System.find_executable("maim") != nil
  defp has_scrot?, do: System.find_executable("scrot") != nil

  defp screenshots_dir, do: Path.expand("~/.osa/screenshots")
end
