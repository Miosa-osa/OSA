defmodule OptimalSystemAgent.Tools.Builtins.Git.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Maps git tool stages to structured payloads the TUI consumes over
  PubSub. Each `kind` corresponds to a TUI component.

  Payload kinds:
    `git_status`  — parsed list of changed files from porcelain output
    `git_diff`    — byte count + line count of the diff
    `git_log`     — number of commits returned
    `git_commit`  — commit sha and subject extracted from output
    `git_generic` — catch-all for subcommands without specialised rendering

  Stages:
    `:tool_use`    — model invoked the tool (before result)
    `:tool_result` — successful result from git
    `:rejected`    — permission denied by check_permissions/2
    `:error`       — execution failure
    `:progress`    — reserved, unused for git
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"command" => command} = input, _opts) do
    %{
      kind: "git_invoke",
      command: command,
      args: input["args"],
      path: input["path"]
    }
  end

  def render(:tool_result, {command, output}, _opts) when is_binary(output) do
    case command do
      "status" -> render_status(output)
      "diff" -> render_diff(output)
      "log" -> render_log(output)
      "commit" -> render_commit(output)
      _ -> render_generic(command, output)
    end
  end

  def render(:tool_result, output, _opts) when is_binary(output) do
    %{kind: "git_generic", bytes: byte_size(output)}
  end

  def render(:rejected, _input, _opts) do
    %{kind: "git_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "git_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil

  # ── Private renderers ─────────────────────────────────────────────────

  # Parse `git status --porcelain`-style output (regular status too).
  # Extract the short status codes and file paths.
  defp render_status(output) do
    lines = String.split(output, "\n", trim: true)

    changed =
      lines
      |> Enum.filter(fn line ->
        # Porcelain lines start with 2-char status code + space
        byte_size(line) > 3 and String.at(line, 2) == " "
      end)
      |> Enum.map(fn line ->
        status = String.slice(line, 0, 2) |> String.trim()
        file = String.slice(line, 3..-1//1) |> String.trim()
        %{status: status, file: file}
      end)

    %{
      kind: "git_status",
      changed_count: length(changed),
      changed: changed,
      raw_lines: length(lines)
    }
  end

  defp render_diff(output) do
    lines = String.split(output, "\n")
    added = Enum.count(lines, &String.starts_with?(&1, "+"))
    removed = Enum.count(lines, &String.starts_with?(&1, "-"))

    %{
      kind: "git_diff",
      bytes: byte_size(output),
      lines: length(lines),
      added: added,
      removed: removed
    }
  end

  defp render_log(output) do
    # Each commit block starts with "commit <sha>"
    commit_count =
      output
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "commit "))

    %{
      kind: "git_log",
      commit_count: commit_count,
      bytes: byte_size(output)
    }
  end

  defp render_commit(output) do
    # Extract SHA from output line like "[main abc1234] feat: ..."
    sha =
      case Regex.run(~r/\[[\w\s]*\s+([a-f0-9]+)\]/, output) do
        [_, sha] -> sha
        _ -> nil
      end

    subject =
      case Regex.run(~r/\]\s+(.+)/, output) do
        [_, s] -> String.trim(s)
        _ -> nil
      end

    %{kind: "git_commit", sha: sha, subject: subject}
  end

  defp render_generic(command, output) do
    %{
      kind: "git_generic",
      command: command,
      bytes: byte_size(output),
      lines: output |> String.split("\n") |> length()
    }
  end
end
