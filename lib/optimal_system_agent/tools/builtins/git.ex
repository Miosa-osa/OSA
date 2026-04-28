defmodule OptimalSystemAgent.Tools.Builtins.Git do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @max_output_bytes 5_000

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "git"

  @impl true
  def description,
    do:
      "Run git commands safely. Supports: status, diff, log, add, commit, branch, checkout, stash."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" =>
            "The git subcommand to run (e.g. status, diff, log, add, commit, branch, checkout, stash)"
        },
        "args" => %{
          "type" => "string",
          "description" => "Additional arguments for the git subcommand. Optional."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory to run the command in. Defaults to ~/.osa/workspace. Optional."
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = params) when is_binary(command) do
    command = String.trim(command)
    args_str = params["args"] || ""
    path = params["path"]

    workspace = Path.expand("~/.osa/workspace")
    File.mkdir_p(workspace)

    effective_cwd =
      case path do
        nil ->
          workspace

        "" ->
          workspace

        p ->
          expanded = Path.expand(p)
          if File.dir?(expanded), do: expanded, else: :invalid
      end

    if effective_cwd == :invalid do
      {:error, "path does not exist: #{path}"}
    else
      args_list = parse_args(args_str)
      full_args = [command | args_list]

      case validate_git_call(command, args_list) do
        {:blocked, reason} ->
          {:error, "Blocked: #{reason}"}

        {:warn, message} ->
          {:ok, message}

        :ok ->
          run_git(full_args, effective_cwd)
      end
    end
  end

  def execute(%{"command" => _}), do: {:error, "command must be a string"}
  def execute(_), do: {:error, "Missing required parameter: command"}

  # --- Safety rules ---

  defp validate_git_call(command, args) do
    args_joined = Enum.join(args, " ")

    cond do
      # BLOCK: force push
      command == "push" and (Enum.member?(args, "--force") or Enum.member?(args, "-f")) ->
        {:blocked, "force push (push --force / push -f) is not permitted"}

      # BLOCK: commit --no-verify
      command == "commit" and Enum.member?(args, "--no-verify") ->
        {:blocked, "commit --no-verify skips hooks and is not permitted"}

      # BLOCK: reset --hard
      command == "reset" and Enum.member?(args, "--hard") ->
        {:blocked, "reset --hard is destructive and not permitted"}

      # BLOCK: clean -f
      command == "clean" and
          (Enum.member?(args, "-f") or String.contains?(args_joined, "-f")) ->
        {:blocked, "clean -f is destructive and not permitted"}

      # BLOCK: checkout . (discards all changes)
      command == "checkout" and (args == ["."] or args == ["--", "."]) ->
        {:blocked, "checkout . discards all local changes and is not permitted"}

      # WARN: push without explicit branch — require confirmation by returning message
      command == "push" ->
        {:warn,
         "[git push blocked — explicit confirmation required]\n" <>
           "To push changes, confirm the target branch and remote explicitly.\n" <>
           "Planned push args: #{args_joined}"}

      # WARN: add . or add -A (suggest specific files)
      command == "add" and (args == ["."] or args == ["-A"] or args == ["--all"]) ->
        {:warn,
         "[Warning] Using `git add #{args_joined}` stages ALL changes including potentially " <>
           "sensitive files (.env, credentials, keys).\n" <>
           "Prefer specifying files explicitly, e.g.: git add path/to/file.ex\n" <>
           "If you still want to add all, re-run with a specific file list."}

      # REQUIRE: commit must have -m flag
      command == "commit" and not has_message_flag?(args) ->
        {:blocked,
         "commit requires a -m flag with a message. Example: args: \"-m 'My commit message'\""}

      true ->
        :ok
    end
  end

  defp has_message_flag?([]), do: false

  defp has_message_flag?(args) do
    Enum.any?(Enum.zip(args, tl(args) ++ [nil]), fn
      {"-m", next} when not is_nil(next) -> true
      {"--message", next} when not is_nil(next) -> true
      _ -> false
    end) or
      Enum.any?(args, fn a ->
        String.starts_with?(a, "-m") and byte_size(a) > 2
      end)
  end

  # --- Execution ---

  defp run_git(args, cwd) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, maybe_truncate(output)}

      {output, code} ->
        {:error, "git exited #{code}:\n#{maybe_truncate(output)}"}
    end
  rescue
    e -> {:error, "git execution error: #{Exception.message(e)}"}
  end

  defp parse_args(""), do: []

  defp parse_args(args_str) do
    # Split on whitespace, respecting quoted strings
    args_str
    |> String.trim()
    |> split_args()
  end

  # Simple argument splitter that handles single/double quoted strings
  defp split_args(str) do
    str
    |> String.split(~r/\s+(?=(?:[^"']*["'][^"']*["'])*[^"']*$)/)
    |> Enum.map(&strip_quotes/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_quotes(<<"\"", rest::binary>>) do
    case String.split_at(rest, byte_size(rest) - 1) do
      {inner, "\""} -> inner
      _ -> rest
    end
  end

  defp strip_quotes(<<"'", rest::binary>>) do
    case String.split_at(rest, byte_size(rest) - 1) do
      {inner, "'"} -> inner
      _ -> rest
    end
  end

  defp strip_quotes(s), do: s

  defp maybe_truncate(output) do
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n[output truncated]"
    else
      output
    end
  end
end
