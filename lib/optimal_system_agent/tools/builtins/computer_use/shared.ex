defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Shared do
  @moduledoc """
  Shared utilities for xdotool-based computer use adapters (LinuxX11, Docker,
  RemoteSSH, PlatformVM).

  Provides the xdotool key map, key combo parsing, scroll button mapping,
  shell escaping, and screenshot directory management.
  """

  @local_screenshot_dir Path.expand("~/.osa/screenshots")

  # ---------------------------------------------------------------------------
  # xdotool / X11 key name map
  # ---------------------------------------------------------------------------

  @xdotool_key_map %{
    # Navigation / editing
    "return" => "Return",
    "enter" => "Return",
    "tab" => "Tab",
    "space" => "space",
    "delete" => "BackSpace",
    "backspace" => "BackSpace",
    "escape" => "Escape",
    "esc" => "Escape",
    # Arrow keys
    "left" => "Left",
    "right" => "Right",
    "up" => "Up",
    "down" => "Down",
    # Extended navigation
    "home" => "Home",
    "end" => "End",
    "pageup" => "Prior",
    "pagedown" => "Next",
    # Function keys
    "f1" => "F1",
    "f2" => "F2",
    "f3" => "F3",
    "f4" => "F4",
    "f5" => "F5",
    "f6" => "F6",
    "f7" => "F7",
    "f8" => "F8",
    "f9" => "F9",
    "f10" => "F10",
    "f11" => "F11",
    "f12" => "F12",
    # Modifiers — Linux maps Cmd/Command to the Super key
    "cmd" => "super",
    "command" => "super",
    "ctrl" => "ctrl",
    "control" => "ctrl",
    "alt" => "alt",
    "option" => "alt",
    "shift" => "shift"
  }

  @doc """
  Convert a human-readable key combo like `"cmd+shift+c"` to the xdotool
  keysym format `"super+shift+c"`.

  Each `+`-separated token is looked up in the xdotool key map. Tokens not
  present (e.g. ordinary alphanumeric keys) are passed through unchanged.
  """
  @spec parse_xdotool_combo(String.t()) :: String.t()
  def parse_xdotool_combo(combo) do
    combo
    |> String.downcase()
    |> String.split("+", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn token -> Map.get(@xdotool_key_map, token, token) end)
    |> Enum.join("+")
  end

  @doc "Return the xdotool key map for adapters that need direct access."
  @spec xdotool_key_map() :: map()
  def xdotool_key_map, do: @xdotool_key_map

  @doc """
  Validate that a parsed key combo contains only safe tokens.

  Rejects shell metacharacters ($, `, ;, |, &, etc.) that could enable
  command injection when the combo is interpolated into a shell command.
  """
  @safe_token_pattern ~r/\A[a-zA-Z0-9_+]+\z/
  @spec validate_combo_tokens(String.t()) :: :ok | {:error, String.t()}
  def validate_combo_tokens(combo) do
    if Regex.match?(@safe_token_pattern, combo) do
      :ok
    else
      {:error, "Key combo contains unsafe characters: #{inspect(combo)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Scroll button mapping
  # ---------------------------------------------------------------------------

  @doc """
  Map a scroll direction string to the xdotool mouse button number.

  xdotool scroll buttons: 4=up, 5=down, 6=left, 7=right.
  """
  @spec scroll_button(String.t()) :: 4 | 5 | 6 | 7
  def scroll_button("up"), do: 4
  def scroll_button("down"), do: 5
  def scroll_button("left"), do: 6
  def scroll_button("right"), do: 7
  def scroll_button(other), do: raise(ArgumentError, "Unknown scroll direction: #{other}")

  # ---------------------------------------------------------------------------
  # Shell escaping
  # ---------------------------------------------------------------------------

  @doc """
  Wrap `text` in single quotes, escaping any embedded single quotes.

  The technique `'...'\\''...'` ends the current single-quoted segment,
  appends a literal single-quote via `\\'`, then re-opens a new segment.
  This is the POSIX-portable approach and prevents command injection.
  """
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(text) do
    clean = String.replace(text, "\0", "")
    "'" <> String.replace(clean, "'", "'\\''") <> "'"
  end

  # ---------------------------------------------------------------------------
  # Screenshot directory
  # ---------------------------------------------------------------------------

  @doc """
  Ensure the local screenshot directory exists, falling back to a temp dir.
  Returns the directory path.
  """
  @spec ensure_screenshot_dir() :: String.t()
  def ensure_screenshot_dir do
    try do
      File.mkdir_p!(@local_screenshot_dir)
      @local_screenshot_dir
    rescue
      _ ->
        fallback = Path.join(System.tmp_dir!(), "osa_screenshots")
        File.mkdir_p!(fallback)
        fallback
    end
  end

  @doc "Default screenshot directory path."
  @spec screenshot_dir() :: String.t()
  def screenshot_dir, do: @local_screenshot_dir
end
