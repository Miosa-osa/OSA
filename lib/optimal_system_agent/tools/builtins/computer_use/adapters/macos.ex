defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.MacOS do
  @moduledoc """
  macOS adapter helpers: AppleScript sanitization, key combo parsing,
  and screenshot command generation.

  Semantic inspection and actions use the bundled `osa-accessibility-darwin`
  AXUIElement helper. Interaction falls back to `osascript`/System Events and
  `cliclick` when an application does not expose a usable accessibility action;
  screenshots use `screencapture` as the final perception fallback.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  alias OptimalSystemAgent.Tools.BoundedCmd

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

    # `screencapture` waits on the window server. A machine at the login window,
    # or one whose WindowServer has wedged, never answers.
    case BoundedCmd.run("screencapture", args,
           label: "screencapture",
           target: "the macOS window server"
         ) do
      {:ok, _, 0} ->
        {:ok, path}

      {:ok, output, _} ->
        {:error, "Screenshot failed: #{String.trim(output)}"}

      # Returning `path` here would hand back a zero-byte or absent PNG that a
      # later read would present as the screen.
      {:timeout, why} ->
        _ = File.rm(path)
        {:error, why}
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

  @doc "Report whether the bundled semantic helper is installed and trusted by macOS."
  def accessibility_status do
    with {:ok, helper} <- accessibility_helper(),
         {:ok, %{"trusted" => trusted}} <-
           run_json_helper(helper, ["permissions"], "Accessibility permission") do
      {:ok, %{helper: helper, trusted: trusted == true}}
    end
  end

  def click(x, y), do: native_click(x, y, "left", 1, "Click", ["c:#{x},#{y}"])

  def double_click(x, y),
    do: native_click(x, y, "left", 2, "Double click", ["dc:#{x},#{y}"])

  def move_mouse(x, y) do
    native_pointer(
      ["--event", "move", "--x", to_string(x), "--y", to_string(y)],
      "Move mouse",
      ["m:#{x},#{y}"]
    )
  end

  def drag(from_x, from_y, to_x, to_y) do
    native_pointer(
      [
        "--event",
        "drag",
        "--x",
        to_string(from_x),
        "--y",
        to_string(from_y),
        "--target-x",
        to_string(to_x),
        "--target-y",
        to_string(to_y)
      ],
      "Drag",
      ["dd:#{from_x},#{from_y}", "du:#{to_x},#{to_y}"]
    )
  end

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
    native_pointer(
      ["--event", "scroll", "--direction", direction, "--amount", to_string(amount)],
      "Scroll",
      nil
    )
  end

  def get_tree do
    case native_accessibility_snapshot(%{}) do
      {:ok, elements} -> {:ok, elements}
      {:error, _} -> legacy_accessibility_tree()
    end
  end

  defp legacy_accessibility_tree do
    script = ~S'''
    set rows to {}
    tell application "System Events"
      set frontProcess to first application process whose frontmost is true
      try
        tell front window of frontProcess
          set roleList to role of every UI element
          set nameList to name of every UI element
          set positionList to position of every UI element
          set sizeList to size of every UI element
        end tell
      end try
    end tell
    try
        repeat with itemIndex from 1 to count of roleList
          try
            set roleName to item itemIndex of roleList as text
            set rawName to item itemIndex of nameList
            if rawName is missing value then
              set elementName to ""
            else
              set elementName to my cleanField(rawName as text)
            end if
            set elementPosition to item itemIndex of positionList
            set elementSize to item itemIndex of sizeList
            set end of rows to roleName & tab & elementName & tab & ((item 1 of elementPosition) as text) & tab & ((item 2 of elementPosition) as text) & tab & ((item 1 of elementSize) as text) & tab & ((item 2 of elementSize) as text)
          end try
        end repeat
    end try
    set AppleScript's text item delimiters to linefeed
    return rows as text

    on cleanField(valueText)
      set AppleScript's text item delimiters to {tab, return, linefeed}
      set pieces to text items of valueText
      set AppleScript's text item delimiters to " "
      set valueText to pieces as text
      set AppleScript's text item delimiters to ""
      return valueText
    end cleanField
    '''

    with {:ok, output} <- osascript_output(script, "Accessibility tree") do
      elements =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_accessibility_row/1)

      {:ok, elements}
    end
  end

  def perform_element(element, action, value \\ nil) when is_map(element) do
    ax_action =
      case action do
        :press -> "AXPress"
        :confirm -> "AXConfirm"
        :raise -> "AXRaise"
        :show_menu -> "AXShowMenu"
        :scroll_to_visible -> "AXScrollToVisible"
        :set_value -> "AXSetValue"
        binary when is_binary(binary) -> binary
      end

    args =
      [
        "perform",
        "--pid",
        to_string(element[:pid] || element["pid"] || ""),
        "--path",
        encode_path(element[:path] || element["path"] || []),
        "--role",
        to_string(element[:role] || element["role"] || ""),
        "--name",
        to_string(element[:name] || element["name"] || ""),
        "--identifier",
        to_string(element[:identifier] || element["identifier"] || ""),
        "--action",
        ax_action
      ] ++ if(is_binary(value), do: ["--value", value], else: [])

    with {:ok, helper} <- accessibility_helper(),
         {:ok, _json} <- run_json_helper(helper, args, "Accessibility action") do
      :ok
    end
  end

  def wait(seconds) when is_number(seconds) do
    Process.sleep(round(seconds * 1_000))
    :ok
  end

  def list_apps do
    with {:ok, output} <-
           osascript_output(
             ~s(tell application "System Events" to get name of every application process whose background only is false),
             "List apps"
           ) do
      {:ok, String.split(output, ", ", trim: true)}
    end
  end

  def list_windows do
    script = ~S'''
    set rows to {}
    tell application "System Events"
      set processNames to name of every application process whose visible is true
    end tell
    repeat with processNameRef in processNames
      set processName to processNameRef as text
      try
        tell application "System Events" to set windowNames to name of every window of application process processName
          repeat with windowIndex from 1 to count of windowNames
            set windowName to item windowIndex of windowNames as text
            set end of rows to processName & tab & windowIndex & tab & windowName
          end repeat
      end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    return rows as text
    '''

    with {:ok, output} <- osascript_output(script, "List windows") do
      windows =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn row ->
          case String.split(row, "\t", parts: 3) do
            [app, index, title] -> [%{"id" => "#{app}:#{index}", "app" => app, "title" => title}]
            _ -> []
          end
        end)

      {:ok, windows}
    end
  end

  def focus_window(window_id) when is_binary(window_id) do
    with {:ok, app, index} <- parse_window_id(window_id) do
      script = """
      tell application "System Events"
        tell application process "#{sanitize_for_applescript(app)}"
          set frontmost to true
          perform action "AXRaise" of window #{index}
        end tell
      end tell
      """

      osascript(script, "Focus window")
    end
  end

  def close_window(window_id) when is_binary(window_id) do
    with {:ok, app, index} <- parse_window_id(window_id) do
      case close_window_semantically(app, index) do
        :ok -> :ok
        {:error, _} -> close_window_via_system_events(app, index)
      end
    end
  end

  def list_tabs(%{"app" => app}) when is_binary(app) and app != "" do
    script = """
    set rows to {}
    set fieldSeparator to ASCII character 9
    tell application "#{sanitize_for_applescript(app)}"
      set windowIndex to 0
      repeat with windowRef in every window
        set windowIndex to windowIndex + 1
        set tabIndex to 0
        repeat with tabRef in every tab of windowRef
          set tabIndex to tabIndex + 1
          set tabID to ""
          set tabTitle to ""
          set tabURL to ""
          try
            set tabID to id of tabRef as text
          end try
          try
            set tabTitle to title of tabRef as text
          end try
          try
            set tabURL to URL of tabRef as text
          end try
          set end of rows to (windowIndex as text) & fieldSeparator & (tabIndex as text) & fieldSeparator & tabID & fieldSeparator & tabTitle & fieldSeparator & tabURL
        end repeat
      end repeat
    end tell
    set AppleScript's text item delimiters to linefeed
    return rows as text
    """

    with {:ok, output} <- osascript_output(script, "List browser tabs") do
      {:ok, parse_browser_tabs(output, app)}
    end
  end

  def list_tabs(_), do: {:error, "list_tabs requires an app name"}

  def close_tabs(%{"app" => app} = params) when is_binary(app) and app != "" do
    url_needle = String.trim(Map.get(params, "url_contains", ""))
    title_needle = String.trim(Map.get(params, "title_contains", ""))

    if url_needle == "" and title_needle == "" do
      {:error, "close_tabs requires url_contains or title_contains"}
    else
      script = """
      set urlNeedle to "#{sanitize_for_applescript(url_needle)}"
      set titleNeedle to "#{sanitize_for_applescript(title_needle)}"
      set closedCount to 0
      tell application "#{sanitize_for_applescript(app)}"
        repeat with windowRef in every window
          set matchedTabs to {}
          repeat with tabRef in every tab of windowRef
            set tabTitle to ""
            set tabURL to ""
            try
              set tabTitle to title of tabRef as text
            end try
            try
              set tabURL to URL of tabRef as text
            end try
            ignoring case
              set urlMatches to (urlNeedle is not "" and tabURL contains urlNeedle)
              set titleMatches to (titleNeedle is not "" and tabTitle contains titleNeedle)
            end ignoring
            if urlMatches or titleMatches then
              set end of matchedTabs to tabRef
            end if
          end repeat
          repeat with tabRef in matchedTabs
            close tabRef
            set closedCount to closedCount + 1
          end repeat
        end repeat
      end tell
      return closedCount as text
      """

      with {:ok, output} <- osascript_output(script, "Close matching browser tabs"),
           {closed, ""} <- Integer.parse(String.trim(output)),
           {:ok, remaining_tabs} <- list_tabs(%{"app" => app}) do
        remaining = Enum.filter(remaining_tabs, &tab_matches?(&1, url_needle, title_needle))

        {:ok,
         %{
           "app" => app,
           "closed" => closed,
           "remaining_matches" => length(remaining),
           "verified" => remaining == [],
           "remaining" => remaining
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, "Close matching browser tabs returned an invalid result"}
      end
    end
  end

  def close_tabs(_), do: {:error, "close_tabs requires an app name and a URL/title matcher"}

  def launch(app) when is_binary(app), do: run_cmd("open", ["-a", app], "Launch")

  def cursor, do: native_pointer_result(["--event", "cursor"], "Cursor")

  def right_click(%{"x" => x, "y" => y}),
    do: native_click(x, y, "right", 1, "Right click", ["rc:#{x},#{y}"])

  def right_click(_), do: {:error, "Right click requires x and y coordinates"}

  def triple_click(%{"x" => x, "y" => y}),
    do: native_click(x, y, "left", 3, "Triple click", ["tc:#{x},#{y}"])

  def triple_click(_), do: {:error, "Triple click requires x and y coordinates"}
  def middle_click(x, y), do: native_click(x, y, "middle", 1, "Middle click", nil)

  def left_mouse_down(x, y) do
    native_pointer(
      ["--event", "down", "--x", to_string(x), "--y", to_string(y)],
      "Mouse down",
      ["m:#{x},#{y}", "dd:#{x},#{y}"]
    )
  end

  def left_mouse_up(x, y) do
    native_pointer(
      ["--event", "up", "--x", to_string(x), "--y", to_string(y)],
      "Mouse up",
      ["m:#{x},#{y}", "du:#{x},#{y}"]
    )
  end

  def clipboard_get do
    case BoundedCmd.run("pbpaste", [], label: "Clipboard read", target: "clipboard") do
      {:ok, output, 0} -> {:ok, output}
      {:ok, output, code} -> {:error, "Clipboard read failed (exit #{code}): #{output}"}
      {:timeout, why} -> {:error, why}
    end
  end

  def clipboard_set(text) when is_binary(text), do: clipboard_write(text)
  def clipboard_clear, do: clipboard_write("")

  def snapshot(params), do: native_accessibility_snapshot(params)
  def list_surfaces(_params), do: list_windows()

  def set_value(%{"x" => x, "y" => y, "text" => text}) do
    with :ok <- click(x, y), :ok <- key_press("cmd+a"), do: type_text(text)
  end

  def set_value(%{"element" => element, "text" => text}),
    do: perform_element(element, :set_value, text)

  def set_value(_), do: {:error, "set_value requires x, y, and text on macOS"}

  def scroll_to(%{"x" => x, "y" => y} = params) do
    with :ok <- move_mouse(x, y) do
      scroll(Map.get(params, "direction", "down"), Map.get(params, "amount", 3))
    end
  end

  def scroll_to(_), do: {:error, "scroll_to requires x and y on macOS"}

  def resize_window(%{"window_id" => id, "width" => width, "height" => height}),
    do: window_geometry(id, "set size of window #{window_index(id)} to {#{width}, #{height}}")

  def move_window(%{"window_id" => id, "x" => x, "y" => y}),
    do: window_geometry(id, "set position of window #{window_index(id)} to {#{x}, #{y}}")

  def hold_key(combo, duration) do
    {mods, key} = parse_key_combo(combo)

    if mods == [] and String.length(key) == 1 do
      script = ~s(tell application "System Events" to key down "#{sanitize_for_applescript(key)}")
      release = ~s(tell application "System Events" to key up "#{sanitize_for_applescript(key)}")

      with :ok <- osascript(script, "Key down") do
        Process.sleep(round(duration * 1_000))
        osascript(release, "Key up")
      end
    else
      {:error, "hold_key currently requires one literal key without modifiers"}
    end
  end

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

  defp cliclick(args, label) do
    if System.find_executable("cliclick") do
      run_cmd("cliclick", args, label)
    else
      {:error, "#{label} requires `cliclick` on macOS (install: brew install cliclick)"}
    end
  end

  defp osascript(script, label), do: run_cmd("osascript", ["-e", script], label)

  defp osascript_output(script, label) do
    case BoundedCmd.run("osascript", ["-e", script], label: label, target: "macOS accessibility") do
      {:ok, output, 0} -> {:ok, String.trim(output)}
      {:ok, output, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}
      {:timeout, why} -> {:error, why}
    end
  end

  defp native_accessibility_snapshot(params) do
    base_args =
      [
        "snapshot",
        "--max-depth",
        to_string(Map.get(params, "max_depth", 12)),
        "--max-elements",
        to_string(Map.get(params, "max_elements", 800))
      ] ++ if(Map.get(params, "interactive_only") == true, do: ["--interactive-only"], else: [])

    with {:ok, target_args} <- snapshot_target_args(params),
         {:ok, helper} <- accessibility_helper(),
         {:ok, decoded} <-
           run_json_helper(helper, base_args ++ target_args, "Accessibility snapshot"),
         true <- is_list(decoded) do
      {:ok, decoded}
    else
      false -> {:error, "Accessibility helper returned invalid snapshot data"}
      {:error, _} = error -> error
    end
  end

  defp snapshot_target_args(params) do
    app =
      cond do
        is_binary(params["window_id"]) and params["window_id"] != "" ->
          case parse_window_id(params["window_id"]) do
            {:ok, name, _index} -> name
            _ -> nil
          end

        is_binary(params["app"]) and params["app"] != "" ->
          params["app"]

        true ->
          nil
      end

    if app do
      script =
        ~s(tell application "System Events" to get unix id of first application process whose name is "#{sanitize_for_applescript(app)}")

      with {:ok, output} <- osascript_output(script, "Resolve application"),
           {pid, ""} <- Integer.parse(String.trim(output)) do
        {:ok, ["--pid", to_string(pid)]}
      else
        _ -> {:error, "Could not resolve running application #{inspect(app)}"}
      end
    else
      {:ok, []}
    end
  end

  defp accessibility_helper do
    configured = System.get_env("OSA_AX_HELPER")

    bundled =
      Path.join(
        to_string(:code.priv_dir(:optimal_system_agent)),
        "helpers/osa-accessibility-darwin"
      )

    source =
      Path.expand(
        "../../../../../../native/macos/AccessibilityHelper/.build/release/osa-accessibility-darwin",
        __DIR__
      )

    [configured, bundled, source]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.find(&(File.regular?(&1) and executable?(&1)))
    |> case do
      nil -> {:error, "Bundled macOS accessibility helper is missing"}
      path -> {:ok, path}
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp run_json_helper(helper, args, label) do
    case BoundedCmd.run(helper, args, label: label, target: "macOS Accessibility API") do
      {:ok, output, 0} ->
        case Jason.decode(output) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, _} ->
            {:error, "#{label} returned invalid JSON: #{String.slice(output, 0, 200)}"}
        end

      {:ok, output, code} ->
        message =
          case Jason.decode(output) do
            {:ok, %{"error" => error}} -> error
            _ -> String.trim(output)
          end

        {:error, "#{label} failed (exit #{code}): #{message}"}

      {:timeout, why} ->
        {:error, why}
    end
  end

  defp native_click(x, y, button, clicks, label, fallback) do
    native_pointer(
      [
        "--event",
        "click",
        "--button",
        button,
        "--clicks",
        to_string(clicks),
        "--x",
        to_string(x),
        "--y",
        to_string(y)
      ],
      label,
      fallback
    )
  end

  defp native_pointer(args, label, fallback) do
    case accessibility_helper() do
      {:ok, helper} ->
        case run_json_helper(helper, ["pointer" | args], label) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} when is_list(fallback) ->
        cliclick(fallback, label)

      {:error, _} = error ->
        error
    end
  end

  defp native_pointer_result(args, label) do
    case accessibility_helper() do
      {:ok, helper} ->
        run_json_helper(helper, ["pointer" | args], label)

      {:error, _} ->
        case BoundedCmd.run("cliclick", ["p"], label: label, target: "mouse pointer") do
          {:ok, output, 0} ->
            case Regex.run(~r/(\d+)\s*,\s*(\d+)/, output) do
              [_, x, y] -> {:ok, %{"x" => String.to_integer(x), "y" => String.to_integer(y)}}
              _ -> {:error, "Could not parse cursor position: #{String.trim(output)}"}
            end

          {:ok, output, code} ->
            {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}

          {:timeout, why} ->
            {:error, why}
        end
    end
  end

  defp encode_path(path) when is_list(path), do: Enum.join(path, ".")
  defp encode_path(_), do: ""

  defp parse_accessibility_row(row) do
    case String.split(row, "\t", parts: 6) do
      [role, name, x, y, width, height] ->
        with {:ok, x} <- parse_coordinate(x),
             {:ok, y} <- parse_coordinate(y),
             {:ok, width} <- parse_coordinate(width),
             {:ok, height} <- parse_coordinate(height) do
          [%{role: normalize_role(role), name: name, x: x, y: y, width: width, height: height}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp normalize_role("AX" <> role), do: role |> String.downcase() |> String.replace(" ", "")
  defp normalize_role(role), do: String.downcase(role)

  defp parse_coordinate(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, round(number)}
      _ -> :error
    end
  end

  defp parse_window_id(id) do
    case String.split(id, ":") do
      parts when length(parts) >= 2 ->
        index = List.last(parts)
        app = parts |> Enum.drop(-1) |> Enum.join(":")

        case Integer.parse(index) do
          {n, ""} when n > 0 -> {:ok, app, n}
          _ -> {:error, "Invalid window id: #{id}"}
        end

      _ ->
        {:error, "Invalid window id: #{id}"}
    end
  end

  defp close_window_semantically(app, index) do
    with {:ok, elements} <-
           native_accessibility_snapshot(%{"app" => app, "max_elements" => 1_500}),
         windows <- Enum.filter(elements, &(&1["role"] == "window")),
         %{"path" => window_path} <- Enum.at(windows, index - 1),
         %{} = close_button <-
           Enum.find(elements, fn element ->
             element["subrole"] == "AXCloseButton" and
               path_descendant?(element["path"], window_path)
           end) do
      perform_element(close_button, :press, nil)
    else
      _ -> {:error, "No semantic close button found"}
    end
  end

  defp close_window_via_system_events(app, index) do
    script = """
    tell application "System Events"
      tell application process "#{sanitize_for_applescript(app)}"
        click button 1 of window #{index}
      end tell
    end tell
    """

    osascript(script, "Close window")
  end

  defp path_descendant?(path, prefix) when is_list(path) and is_list(prefix) do
    Enum.take(path, length(prefix)) == prefix
  end

  defp path_descendant?(_, _), do: false

  defp parse_browser_tabs(output, app) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row, "\t", parts: 5) do
        [window_index, tab_index, id, title, url] ->
          [
            %{
              "app" => app,
              "window_index" => parse_positive_integer(window_index),
              "tab_index" => parse_positive_integer(tab_index),
              "id" => id,
              "title" => title,
              "url" => url
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp tab_matches?(tab, url_needle, title_needle) do
    contains_ci?(tab["url"], url_needle) or contains_ci?(tab["title"], title_needle)
  end

  defp contains_ci?(_value, ""), do: false

  defp contains_ci?(value, needle) do
    String.contains?(String.downcase(value || ""), String.downcase(needle))
  end

  defp window_index(id) do
    case parse_window_id(id) do
      {:ok, _, index} -> index
      _ -> 1
    end
  end

  defp window_geometry(id, command) do
    with {:ok, app, _index} <- parse_window_id(id) do
      script =
        "tell application \"System Events\" to tell application process \"#{sanitize_for_applescript(app)}\" to #{command}"

      osascript(script, "Window geometry")
    end
  end

  defp clipboard_write(text) do
    osascript(
      ~s(set the clipboard to "#{sanitize_for_applescript(text)}"),
      "Clipboard write"
    )
  end

  # The generic dispatch for `osascript` and `cliclick`. An AppleScript that
  # triggers a modal dialog blocks until somebody dismisses it, which on a
  # headless or unattended Mac is never.
  defp run_cmd(cmd, args, label) do
    case BoundedCmd.run(cmd, args, label: label, target: "the macOS window server") do
      {:ok, _, 0} -> :ok
      {:ok, output, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}
      {:timeout, why} -> {:error, why}
    end
  rescue
    e in ErlangError ->
      {:error, "#{label} failed: #{inspect(e)}"}
  end

  defp screenshots_dir do
    Path.expand("~/.osa/screenshots")
  end
end
