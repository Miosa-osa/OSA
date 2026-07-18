defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.MacOS do
  @moduledoc """
  macOS adapter helpers: AppleScript sanitization, key combo parsing,
  and screenshot command generation.

  Interaction is driven by `osascript`/System Events (keyboard) and `cliclick`
  (mouse); screenshots use `screencapture`. `get_tree` (accessibility) is not yet
  implemented.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  @doc """
  Escape a string for safe embedding inside AppleScript double-quoted strings.
  Backslashes first, then double quotes.
  """
  @spec sanitize_for_applescript(String.t()) :: String.t()
  def sanitize_for_applescript(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\0", "")
  end

  @doc """
  Parse a key combo string like "cmd+shift+v" into {modifiers, key}.
  Case-insensitive. Last segment is always the key, rest are modifiers.
  """
  @spec parse_key_combo(String.t()) :: {[String.t()], String.t()}
  def parse_key_combo(combo) do
    parts =
      combo
      |> String.downcase()
      |> String.split("+")

    case parts do
      [key] -> {[], key}
      segments -> {Enum.slice(segments, 0..-2//1), List.last(segments)}
    end
  end

  @doc """
  Generate a screenshot command. Returns {:ok, path} on success, {:error, reason} on failure.
  """
  @spec screenshot(map()) :: {:ok, String.t()} | {:error, String.t()}
  def screenshot(opts \\ %{}) do
    dir = screenshots_dir()
    File.mkdir_p!(dir)

    filename = "screenshot_#{System.system_time(:millisecond)}.png"
    path = Path.join(dir, filename)

    args =
      case opts["region"] do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          ["-x", "-R#{x},#{y},#{w},#{h}", path]

        _ ->
          ["-x", path]
      end

    case System.cmd("screencapture", args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, path}

      {output, _} ->
        {:error, "Screenshot failed: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Screenshot failed: #{inspect(e)}"}
  end

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  def available? do
    case :os.type() do
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  def click(x, y), do: cliclick(["c:#{x},#{y}"], "Click")
  def double_click(x, y), do: cliclick(["dc:#{x},#{y}"], "Double click")
  def move_mouse(x, y), do: cliclick(["m:#{x},#{y}"], "Move mouse")

  def drag(from_x, from_y, to_x, to_y),
    do: cliclick(["dd:#{from_x},#{from_y}", "du:#{to_x},#{to_y}"], "Drag")

  def type_text(text) do
    osascript(
      ~s(tell application "System Events" to keystroke "#{sanitize_for_applescript(text)}"),
      "Type"
    )
  end

  def key_press(combo) do
    {mods, key} = parse_key_combo(combo)
    osascript(key_press_script(mods, key), "Key press")
  end

  def scroll(direction, amount \\ 3) do
    case scroll_key_code(direction) do
      nil ->
        {:error, "Unknown scroll direction: #{direction}"}

      code ->
        # cliclick has no scroll verb; approximate a wheel scroll with repeated
        # arrow-key presses via System Events.
        lines = for _ <- 1..max(amount, 1), do: "key code #{code}"
        script = "tell application \"System Events\"\n" <> Enum.join(lines, "\n") <> "\nend tell"
        osascript(script, "Scroll")
    end
  end

  def get_tree, do: {:error, "macOS accessibility tree not yet implemented"}

  # ── Private helpers ──────────────────────────────────────────────────

  # Build AppleScript for a key combo. Modifiers use the "using {… down}" form;
  # named keys map to virtual key codes, otherwise a literal keystroke is sent.
  defp key_press_script(mods, key) do
    using = mods |> Enum.map(&applescript_modifier/1) |> Enum.reject(&is_nil/1)

    keystroke =
      case special_key_code(key) do
        nil -> ~s(keystroke "#{sanitize_for_applescript(key)}")
        code -> "key code #{code}"
      end

    inner =
      case using do
        [] -> keystroke
        list -> "#{keystroke} using {#{Enum.join(list, ", ")}}"
      end

    ~s(tell application "System Events" to #{inner})
  end

  defp applescript_modifier(m) when m in ["cmd", "command"], do: "command down"
  defp applescript_modifier(m) when m in ["ctrl", "control"], do: "control down"
  defp applescript_modifier(m) when m in ["alt", "opt", "option"], do: "option down"
  defp applescript_modifier("shift"), do: "shift down"
  defp applescript_modifier(_), do: nil

  defp special_key_code(k) when k in ["return", "enter"], do: 36
  defp special_key_code("tab"), do: 48
  defp special_key_code("space"), do: 49
  defp special_key_code(k) when k in ["delete", "backspace"], do: 51
  defp special_key_code(k) when k in ["escape", "esc"], do: 53
  defp special_key_code("left"), do: 123
  defp special_key_code("right"), do: 124
  defp special_key_code("down"), do: 125
  defp special_key_code("up"), do: 126
  defp special_key_code(_), do: nil

  defp scroll_key_code("up"), do: 126
  defp scroll_key_code("down"), do: 125
  defp scroll_key_code("left"), do: 123
  defp scroll_key_code("right"), do: 124
  defp scroll_key_code(_), do: nil

  defp cliclick(args, label) do
    if System.find_executable("cliclick") do
      run_cmd("cliclick", args, label)
    else
      {:error, "#{label} requires `cliclick` on macOS (install: brew install cliclick)"}
    end
  end

  defp osascript(script, label), do: run_cmd("osascript", ["-e", script], label)

  defp run_cmd(cmd, args, label) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "#{label} failed: #{inspect(e)}"}
  end

  defp screenshots_dir do
    Path.expand("~/.osa/screenshots")
  end
end
