defmodule OptimalSystemAgent.Channels.CLI.Permissions do
  @moduledoc """
  Interactive permission prompts for the CLI.

  When a tool execution requires user approval, renders an inline
  permission dialog with single-keypress response capture.
  """

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @white IO.ANSI.white()
  @green IO.ANSI.green()
  @red IO.ANSI.red()

  @doc """
  Display an interactive permission prompt and capture user decision.

  Returns `:allow_once`, `:allow_always`, or `:deny`.
  """
  def prompt_permission(tool_name, args, _opts \\ []) do
    desc = format_tool_description(tool_name, args)
    width = min(terminal_width() - 4, 70)

    IO.puts("")
    IO.puts("  #{@dim}┌─ #{@yellow}Permission Required#{@dim} #{String.duplicate("─", max(width - 24, 2))}┐#{@reset}")
    IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width)}#{@dim}│#{@reset}")
    IO.puts("  #{@dim}│#{@reset}  #{@yellow}⚠#{@reset}  #{@bold}#{tool_name}#{@reset} wants to:")
    IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width)}#{@dim}│#{@reset}")

    # Word-wrap the description inside the box
    desc
    |> String.split("\n")
    |> Enum.each(fn line ->
      padded = String.pad_trailing("     #{line}", width)
      IO.puts("  #{@dim}│#{@reset}#{padded}#{@dim}│#{@reset}")
    end)

    # Show affected paths if present
    paths = extract_paths(tool_name, args)
    if paths != [] do
      IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width)}#{@dim}│#{@reset}")
      Enum.each(paths, fn path ->
        padded = String.pad_trailing("     #{@cyan}#{path}#{@reset}", width + String.length(@cyan) + String.length(@reset))
        IO.puts("  #{@dim}│#{@reset}#{padded}#{@dim}│#{@reset}")
      end)
    end

    IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width)}#{@dim}│#{@reset}")
    IO.puts("  #{@dim}│#{@reset}  #{@green}[Y]#{@reset} Allow once  #{@cyan}[A]#{@reset} Allow always  #{@red}[N]#{@reset} Deny")
    IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width)}#{@dim}│#{@reset}")
    IO.puts("  #{@dim}└#{String.duplicate("─", width)}┘#{@reset}")

    IO.write("  #{@dim}> #{@reset}")

    decision = read_single_key()

    case decision do
      key when key in ["y", "Y", "\r", "\n"] ->
        IO.puts("#{@green}  ✓ Allowed#{@reset}\n")
        :allow_once

      key when key in ["a", "A"] ->
        IO.puts("#{@green}  ✓ Always allowed#{@reset}\n")
        :allow_always

      _ ->
        IO.puts("#{@red}  ✗ Denied#{@reset}\n")
        :deny
    end
  end

  # ── Tool Description Formatting ──────────────────────────────────────

  defp format_tool_description("shell_execute", args) do
    cmd = Map.get(args, "command", Map.get(args, :command, "?"))
    "Run command:\n     #{cmd}"
  end

  defp format_tool_description("file_write", args) do
    path = Map.get(args, "path", Map.get(args, :path, "?"))
    "Create/overwrite file:\n     #{path}"
  end

  defp format_tool_description("file_edit", args) do
    path = Map.get(args, "path", Map.get(args, :path, "?"))
    "Edit file:\n     #{path}"
  end

  defp format_tool_description("file_delete", args) do
    path = Map.get(args, "path", Map.get(args, :path, "?"))
    "Delete file:\n     #{path}"
  end

  defp format_tool_description("delegate", args) do
    role = Map.get(args, "role", Map.get(args, :role, "?"))
    task = Map.get(args, "task", Map.get(args, :task, ""))
    "Spawn agent: #{role}\n     Task: #{String.slice(task, 0, 60)}"
  end

  defp format_tool_description(name, _args) do
    "Execute tool: #{name}"
  end

  # ── Path Extraction ──────────────────────────────────────────────────

  defp extract_paths("shell_execute", _args), do: []

  defp extract_paths(_tool, args) do
    path = Map.get(args, "path", Map.get(args, :path))
    if path, do: [path], else: []
  end

  # ── Key Reading ──────────────────────────────────────────────────────

  defp read_single_key do
    case File.open("/dev/tty", [:read, :raw, :binary]) do
      {:ok, tty} ->
        # Set raw mode
        System.cmd("stty", ["raw", "-echo"], into: "", stderr_to_stdout: true)

        result =
          case :file.read(tty, 1) do
            {:ok, char} -> char
            _ -> "n"
          end

        # Restore cooked mode
        System.cmd("stty", ["sane"], into: "", stderr_to_stdout: true)
        File.close(tty)
        result

      {:error, _} ->
        # Fallback to IO.gets for environments without /dev/tty
        case IO.gets("") do
          :eof -> "n"
          line when is_binary(line) -> String.trim(line) |> String.first() || "n"
          _ -> "n"
        end
    end
  rescue
    _ -> "n"
  end

  defp terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end
end
