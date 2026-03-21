defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.MacOS do
  @moduledoc """
  macOS adapter helpers: AppleScript sanitization, key combo parsing,
  and screenshot command generation.

  Full adapter implementation (all 10 callbacks) comes in Phase 7.
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

  # ── Stub callbacks (Phase 7) ─────────────────────────────────────────

  def available? do
    case :os.type() do
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  def click(_x, _y), do: {:error, "macOS click not yet implemented (Phase 7)"}
  def double_click(_x, _y), do: {:error, "macOS double_click not yet implemented (Phase 7)"}
  def type_text(_text), do: {:error, "macOS type_text not yet implemented (Phase 7)"}
  def key_press(_combo), do: {:error, "macOS key_press not yet implemented (Phase 7)"}
  def scroll(_direction, _amount), do: {:error, "macOS scroll not yet implemented (Phase 7)"}
  def move_mouse(_x, _y), do: {:error, "macOS move_mouse not yet implemented (Phase 7)"}
  def drag(_from_x, _from_y, _to_x, _to_y), do: {:error, "macOS drag not yet implemented (Phase 7)"}
  def get_tree, do: {:error, "macOS accessibility tree not yet implemented (Phase 7)"}

  defp screenshots_dir do
    Path.expand("~/.osa/screenshots")
  end
end
