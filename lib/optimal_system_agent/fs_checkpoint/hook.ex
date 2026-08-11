defmodule OptimalSystemAgent.FSCheckpoint.Hook do
  @moduledoc """
  Pre-tool-use hook that snapshots files before destructive operations.

  Registered by `FSCheckpoint.Server.init/1` at priority 11 so it runs
  after the security check (p10) but before most other hooks.
  """

  alias OptimalSystemAgent.FSCheckpoint.{Config, Server}

  @spec pre_tool_use(map()) :: {:ok, map()} | :skip
  def pre_tool_use(%{tool_name: tool_name, arguments: args} = payload) do
    unless Config.enabled?() do
      {:ok, payload}
    else
      paths = extract_paths(tool_name, args)

      if paths != [] do
        session_id = Map.get(payload, :session_id, "unknown")

        # BLOCKS until the snapshot is on disk. That is the point: the tool's
        # write must not start until the pre-edit content has been captured.
        # See `Server.snapshot/3` for what the previous fire-and-forget cast
        # actually recorded.
        case Server.snapshot(session_id, tool_name, paths) do
          {:ok, _report} ->
            :ok

          {:error, reason} ->
            # Non-fatal: a checkpoint failure must not block the operator's
            # edit. But it is said out loud, because the alternative is an
            # operator who believes /rollback will work.
            require Logger

            Logger.warning(
              "[fs_checkpoint] No checkpoint taken before #{tool_name} (#{reason}) — " <>
                "/rollback will not be able to undo this."
            )
        end
      end

      {:ok, payload}
    end
  end

  def pre_tool_use(payload), do: {:ok, payload}

  # ── Path extraction by tool ──────────────────────────────────────────

  @doc """
  The existing regular files a call to `tool_name` with `args` is about to put
  at risk — i.e. exactly what gets snapshotted.

  Public so the extraction rules can be tested directly. Testing them through
  `pre_tool_use/1` would require a live `FSCheckpoint.Server` writing into the
  operator's real shadow repo, and would still not distinguish "extracted no
  paths" from "snapshot failed" — which is the precise distinction the
  `shell_execute` clause used to get wrong.
  """
  @spec extract_paths(String.t(), map()) :: [String.t()]

  # `notebook_edit` is here because it is a write tool like the others. It was
  # omitted, so every notebook mutation — including `delete_cell`, which is
  # destructive and not undoable by re-editing — ran with no checkpoint at all
  # and could not be recovered with /rollback.
  def extract_paths(tool_name, args) when tool_name in ~w(file_write file_edit notebook_edit) do
    case Map.get(args, "path") || Map.get(args, :path) do
      nil -> []
      path -> expand_if_exists(path)
    end
  end

  def extract_paths("multi_file_edit", args) do
    edits = Map.get(args, "edits") || Map.get(args, :edits) || []

    edits
    |> Enum.map(fn edit -> Map.get(edit, "path") || Map.get(edit, :path) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&expand_if_exists/1)
  end

  # Destructive shell commands.
  #
  # This used to compute the destructive-pattern check and then return `[]` from
  # BOTH branches of the `if` — a conditional whose two arms were identical. The
  # entire `shell_destructive_patterns` config surface existed only to feed it,
  # so `rm -rf` and `sed -i` ran with zero checkpoint coverage while the setting
  # advertised protection.
  #
  # Extraction cannot be perfect on arbitrary shell — it would need a shell
  # parser and the file set is only known after expansion. It does not have to
  # be: checkpointing is best-effort by nature, and covering the plain form
  # (`rm foo.ex`, `sed -i s/a/b/ lib/x.ex`, `mv a b`) is the difference between
  # "usually recoverable" and "never recoverable". Every token that names an
  # existing regular file is snapshotted; anything hidden behind a glob,
  # variable or subshell is not, which is why `pre_tool_use/1` reports the
  # coverage rather than implying completeness.
  def extract_paths("shell_execute", args) do
    command = Map.get(args, "command") || Map.get(args, :command) || ""

    if destructive?(command) do
      command
      |> candidate_tokens()
      |> Enum.flat_map(&expand_if_exists/1)
      |> Enum.uniq()
    else
      []
    end
  end

  def extract_paths(_tool, _args), do: []

  # A command is destructive when one of its WORDS is a destructive utility.
  # `String.contains?(command, "rm")` matched "confirm", "format" and "cp" in
  # "cpu" — noise that made the setting meaningless in both directions.
  defp destructive?(command) do
    patterns = Config.shell_destructive_patterns()

    command
    |> tokenize()
    |> Enum.any?(fn token -> Path.basename(token) in patterns end)
  end

  # Tokens that could plausibly name a file: anything that is not an option
  # flag, not a shell operator, and not the utility name itself.
  @shell_operators ["|", "||", "&&", ";", ">", ">>", "<", "&", "(", ")", "{", "}"]

  defp candidate_tokens(command) do
    patterns = Config.shell_destructive_patterns()

    command
    |> tokenize()
    |> Enum.reject(fn token ->
      token == "" or
        String.starts_with?(token, "-") or
        token in @shell_operators or
        Path.basename(token) in patterns
    end)
  end

  # Split on whitespace AND on the shell separators, so `cd x && rm y` and
  # `rm a;rm b` both yield their filenames. Deliberately simple: it does not
  # understand globbing, variable expansion or command substitution. It does
  # not need to — `expand_if_exists/1` keeps only tokens that already name an
  # existing regular file, so an unrecognised construct yields no snapshot
  # rather than a wrong one.
  defp tokenize(command) do
    command
    |> String.split(~r/[\s;|&<>]+/, trim: true)
    |> Enum.map(&unquote_token/1)
  end

  defp unquote_token(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_token(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp unquote_token(token), do: token

  defp expand_if_exists(path) do
    expanded = Path.expand(path)
    if File.regular?(expanded), do: [expanded], else: []
  end
end
