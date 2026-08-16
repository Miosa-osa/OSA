defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11 do
  @moduledoc """
  Linux X11 adapter — uses xdotool for input and maim/scrot for screenshots.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  require Logger

  alias OptimalSystemAgent.Tools.BoundedCmd
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.AppAllowlist

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

    # AT-SPI2 walks the live accessibility tree over D-Bus. An application that
    # stops answering its a11y calls hangs the walk with no error, forever.
    case BoundedCmd.run("python3", [script, "--max-depth", "10", "--max-elements", "100"],
           label: "AT-SPI2 tree walk",
           target: "the desktop accessibility bus",
           env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
         ) do
      {:timeout, why} ->
        {:error, why}

      {:ok, output, 0} ->
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

  # ── Extended action callbacks (standard-contract parity) ─────────────
  # These are not part of the base Adapter behaviour; the Server guards each
  # with function_exported?/3 before calling, so implementing them here simply
  # lights the action up on X11.

  @doc "Right-click at coordinates."
  def right_click(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y) do
    run_cmd("xdotool", ["mousemove", "--sync", "#{x}", "#{y}", "click", "3"], "Right click")
  end

  def right_click(_), do: {:error, "right_click on X11 requires x,y coordinates"}

  @doc "Triple-click at coordinates."
  def triple_click(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y) do
    run_cmd(
      "xdotool",
      ["mousemove", "--sync", "#{x}", "#{y}", "click", "--repeat", "3", "1"],
      "Triple click"
    )
  end

  def triple_click(_), do: {:error, "triple_click on X11 requires x,y coordinates"}

  @doc "Middle-click at coordinates."
  def middle_click(x, y) do
    run_cmd("xdotool", ["mousemove", "--sync", "#{x}", "#{y}", "click", "2"], "Middle click")
  end

  @doc "Press the left button down at coordinates without releasing."
  def left_mouse_down(x, y) do
    run_cmd("xdotool", ["mousemove", "--sync", "#{x}", "#{y}", "mousedown", "1"], "Mouse down")
  end

  @doc "Release the left button at coordinates."
  def left_mouse_up(x, y) do
    run_cmd("xdotool", ["mousemove", "--sync", "#{x}", "#{y}", "mouseup", "1"], "Mouse up")
  end

  @doc "Hold a key combo down for `duration` seconds, then release it."
  def hold_key(combo, duration) do
    key = translate_key_combo(combo)

    with :ok <- run_cmd("xdotool", ["keydown", key], "Key down") do
      Process.sleep(trunc(max(0, min(duration || 1, 30)) * 1000))
      run_cmd("xdotool", ["keyup", key], "Key up")
    end
  end

  @doc "Pause for `seconds` (clamped 0-30)."
  def wait(seconds) do
    Process.sleep(trunc(max(0, min(seconds || 1, 30)) * 1000))
    :ok
  end

  @doc "Return the current pointer coordinates."
  def cursor do
    case BoundedCmd.run("xdotool", ["getmouselocation", "--shell"],
           label: "xdotool getmouselocation",
           target: "the X display"
         ) do
      {:ok, out, 0} -> {:ok, parse_mouse_location(out)}
      {:ok, output, code} -> {:error, "cursor failed (exit #{code}): #{String.trim(output)}"}
      {:timeout, why} -> {:error, why}
    end
  rescue
    e in ErlangError -> {:error, "cursor failed: #{inspect(e)}"}
  end

  @doc "List open windows via wmctrl."
  def list_windows do
    case BoundedCmd.run("wmctrl", ["-l"], label: "wmctrl -l", target: "the window manager") do
      {:ok, out, 0} -> {:ok, out}
      {:ok, output, code} -> {:error, "list_windows failed (exit #{code}): #{String.trim(output)}"}
      # An empty window list would read as "nothing is open". It is not.
      {:timeout, why} -> {:error, why}
    end
  rescue
    e in ErlangError -> {:error, "list_windows unavailable (install wmctrl): #{inspect(e)}"}
  end

  @doc "Activate a window by its X11 window id."
  def focus_window(window_id) when is_binary(window_id) do
    run_cmd("xdotool", ["windowactivate", "--sync", window_id], "Focus window")
  end

  @doc "Launch an allowlisted application."
  def launch(app) when is_binary(app) do
    if AppAllowlist.allowed?(app) do
      # unbounded: deliberate. This is a LAUNCH, not a query — the whole point
      # is that the application outlives this call. A deadline here would kill
      # the app the operator just asked for, 120s after it started. Nothing
      # waits on this result, so it cannot wedge a turn.
      _ = spawn(fn -> System.cmd("nohup", [app], stderr_to_stdout: true) end)
      Process.sleep(1500)
      :ok
    else
      {:error, "'#{app}' is not in the allowed application list"}
    end
  end

  @doc "Read the clipboard via xclip."
  def clipboard_get do
    # `xclip -o` blocks until the selection OWNER answers. An unresponsive owner
    # window hangs it indefinitely, and an empty string would be indistinguishable
    # from a genuinely empty clipboard.
    case BoundedCmd.run("xclip", ["-selection", "clipboard", "-o"],
           label: "xclip -o",
           target: "the clipboard selection owner",
           stderr_to_stdout: false
         ) do
      {:ok, out, 0} -> {:ok, out}
      {:ok, output, code} -> {:error, "clipboard_get failed (exit #{code}): #{String.trim(output)}"}
      {:timeout, why} -> {:error, why}
    end
  rescue
    e in ErlangError -> {:error, "clipboard_get unavailable (install xclip): #{inspect(e)}"}
  end

  @doc "Write text to the clipboard via xclip."
  def clipboard_set(text) when is_binary(text), do: clipboard_write(text)

  @doc "Clear the clipboard."
  def clipboard_clear, do: clipboard_write("")

  defp parse_mouse_location(shell_output) do
    vals =
      shell_output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> {k, v}
          _ -> {line, ""}
        end
      end)

    "Cursor at (#{Map.get(vals, "X", "0")}, #{Map.get(vals, "Y", "0")})"
  end

  defp clipboard_write(text) do
    tmp = Path.join(System.tmp_dir!(), "osa_clip_#{System.unique_integer([:positive])}")

    try do
      File.write!(tmp, text)

      case BoundedCmd.run("sh", ["-c", "xclip -selection clipboard < #{tmp}"],
             label: "xclip clipboard write",
             target: "the X display"
           ) do
        {:ok, _, 0} ->
          :ok

        {:ok, output, code} ->
          {:error, "clipboard write failed (exit #{code}): #{String.trim(output)}"}

        {:timeout, why} ->
          {:error, why}
      end
    after
      File.rm(tmp)
    end
  rescue
    e -> {:error, "clipboard write unavailable (install xclip): #{inspect(e)}"}
  end

  # ── Public Command Generators (tested directly) ──────────────────────

  @doc "Generate screenshot command tuple {binary, args}."
  # Pure command generators (availability is checked at the call site in
  # screenshot/1). These return the maim invocation form; scrot fallback, when
  # needed, is selected by the executor, not baked into command generation.
  def screenshot_cmd(%{path: path, region: %{"x" => x, "y" => y, "width" => w, "height" => h}}) do
    {"maim", ["-g", "#{w}x#{h}+#{x}+#{y}", path]}
  end

  def screenshot_cmd(%{path: path}) do
    {"maim", [path]}
  end

  @doc """
  POSIX single-quote escape a string for safe shell interpolation: wrap in
  single quotes and replace embedded single quotes with the '\\'' sequence.
  """
  def shell_escape(str) when is_binary(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
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

  # ── Private ──────────────────────────────────────────────────────────

  # The generic dispatch every input primitive goes through — `xdotool`,
  # `wmctrl`, and in particular `xdotool windowactivate --sync`, which blocks
  # until the window manager confirms and never returns if it does not.
  defp run_cmd(cmd, args, label) do
    case BoundedCmd.run(cmd, args, label: label, target: "the X display") do
      {:ok, _, 0} -> :ok
      {:ok, output, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}
      {:timeout, why} -> {:error, why}
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
