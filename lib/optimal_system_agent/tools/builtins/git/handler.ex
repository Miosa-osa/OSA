defmodule OptimalSystemAgent.Tools.Builtins.Git.Handler do
  @moduledoc """
  Validation, permission, and execution logic for the `git` tool.

  Stage breakdown:
    * `validate/2`          — shape-checks the input map (cheap, no I/O)
    * `check_permissions/2` — enforces the Git Safety Protocol rules
    * `execute/2`           — resolves the working directory and runs git

  Safety rules mirror the the prior generation Git Safety Protocol
  (docs/archive/flows/claude-code-v2-flow.md §6) plus OSA-specific
  additions (warn on `git add -A` / `git add .`).
  """

  alias OptimalSystemAgent.Tools.Builtins.Git.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"command" => command} = input, _ctx) when is_binary(command),
    do: {:ok, input}

  def validate(%{"command" => _}, _ctx),
    do: {:error, "command must be a string", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameter: command", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"command" => command} = input, _ctx) do
    args_str = input["args"] || ""
    args_list = parse_args(args_str)
    args_joined = Enum.join(args_list, " ")

    case safety_check(command, args_list, args_joined) do
      {:blocked, reason} -> {:deny, "Access denied: #{reason}"}
      :ok -> {:allow, input}
    end
  end

  # ── Stage 3: Execution ────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"command" => command} = input, _ctx) do
    command = String.trim(command)
    args_str = input["args"] || ""
    path = input["path"]

    workspace = Path.expand("~/.osa/workspace")
    File.mkdir_p!(workspace)

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

      # Re-run the warn-level check (add -A / add .) at execution time
      # so the user sees the advisory even if permissions passed.
      case warn_check(command, args_list) do
        {:warn, message} -> {:ok, message}
        :ok -> run_git([command | maybe_coauthor_args(command, args_list)], effective_cwd)
      end
    end
  end

  # ── Safety rules ──────────────────────────────────────────────────────

  # Returns {:blocked, reason} for hard prohibitions, :ok otherwise.
  defp safety_check(command, args_list, args_joined) do
    cond do
      # BLOCK: force push
      command == "push" and
          (Enum.member?(args_list, "--force") or
             Enum.member?(args_list, "-f") or
             Enum.member?(args_list, "--force-with-lease")) ->
        {:blocked, "force push (--force / -f / --force-with-lease) is not permitted"}

      # BLOCK: commit --no-verify
      command == "commit" and Enum.member?(args_list, "--no-verify") ->
        {:blocked, "commit --no-verify skips hooks and is not permitted"}

      # BLOCK: reset --hard
      command == "reset" and Enum.member?(args_list, "--hard") ->
        {:blocked, "reset --hard is destructive and not permitted"}

      # BLOCK: clean -f
      command == "clean" and
          (Enum.member?(args_list, "-f") or String.contains?(args_joined, "-f")) ->
        {:blocked, "clean -f is destructive and not permitted"}

      # BLOCK: checkout . (discards all local changes)
      command == "checkout" and (args_list == ["."] or args_list == ["--", "."]) ->
        {:blocked, "checkout . discards all local changes and is not permitted"}

      # BLOCK: restore . (discards all local changes)
      command == "restore" and (args_list == ["."] or args_list == ["--", "."]) ->
        {:blocked, "restore . discards all local changes and is not permitted"}

      # BLOCK: branch -D (force-delete)
      command == "branch" and Enum.member?(args_list, "-D") ->
        {:blocked, "branch -D force-deletes a branch and is not permitted"}

      # BLOCK: commit without -m flag
      command == "commit" and not has_message_flag?(args_list) ->
        {:blocked,
         "commit requires a -m flag with a message. Example: args: \"-m 'feat: my change'\""}

      true ->
        :ok
    end
  end

  # Returns {:warn, message} for advisory cases, :ok otherwise.
  # These pass the permission check but short-circuit execution.
  defp warn_check(command, args_list) do
    args_joined = Enum.join(args_list, " ")

    cond do
      # WARN: bare push — require explicit confirmation
      command == "push" ->
        {:warn,
         "[git push intercepted — explicit confirmation required]\n" <>
           "To push changes, specify the target remote and branch explicitly.\n" <>
           "Planned push args: #{args_joined}"}

      # WARN: indiscriminate staging
      command == "add" and
          (args_list == ["."] or args_list == ["-A"] or args_list == ["--all"]) ->
        {:warn,
         "[Warning] `git add #{args_joined}` stages ALL changes, including potentially sensitive " <>
           "files (.env, credentials, keys).\n" <>
           "Prefer specifying files explicitly, e.g.: git add path/to/file.ex\n" <>
           "If you still want to add all, re-run with specific file paths."}

      true ->
        :ok
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # includeCoAuthoredBy (CC-parity, OSA default FALSE — never-attribute rule):
  # only when an operator EXPLICITLY opts in (setting == true) does a commit gain
  # a Co-Authored-By trailer. Default/unset -> no trailer, so OSA never
  # self-attributes a commit. Attribution is to OSA, never to Claude.
  defp maybe_coauthor_args("commit", args_list) do
    if OptimalSystemAgent.Settings.get("includeCoAuthoredBy", false) == true do
      args_list ++ ["--trailer", "Co-Authored-By: OSA <noreply@osa.dev>"]
    else
      args_list
    end
  end

  defp maybe_coauthor_args(_command, args_list), do: args_list

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

  defp run_git(args, cwd) do
    # `hooks: :enabled` on purpose: this is the OPERATOR/model-facing git tool
    # and the safety protocol above explicitly blocks `commit --no-verify`
    # because skipping hooks is not permitted. Silently disabling hooks here
    # would contradict that. The repo-config code-execution vectors that are
    # NOT part of git's documented contract (core.fsmonitor, filter.*.clean /
    # .smudge / .process, diff.external, diff.*.textconv) are still neutralized.
    case OptimalSystemAgent.Git.cmd(args, cd: cwd, stderr_to_stdout: true, hooks: :enabled) do
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
    args_str
    |> String.trim()
    |> split_args()
  end

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
    max = Constants.max_output_bytes()

    if byte_size(output) > max do
      String.slice(output, 0, max) <> "\n[output truncated]"
    else
      output
    end
  end
end
