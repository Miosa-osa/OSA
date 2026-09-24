defmodule OptimalSystemAgent.Prefetch.ReadOnlyTools do
  @moduledoc """
  Runs exactly one of a fixed, provably-read-only tool set for speculative
  prefetch — deliberately NOT `Tools.Registry.execute/2`.

  `Registry.execute/2` (via `Tools.LegacyAdapter.execute_structured/3`) honours
  a tool's `{:ask, prompt}` permission answer by opening a real
  `Permissions.AskFlow` round-trip. That is correct for a call the model made
  and wrong for a call NOBODY made: a background guess must never be able to
  pop a permission dialog. So this module runs the structured
  `validate_input/2 -> check_permissions/2 -> execute/2` pipeline itself and
  treats anything other than `{:allow, _}` — `:ask` included — as "do not run
  this", not "ask the operator".

  Restricted to two modules whose `check_permissions/2` is verified (by
  reading, not by trusting the callback contract) to only ever return `:allow`
  or `:deny` — `FileRead.Tool` / `DirList.Tool`: path allow-list +
  sensitive-file deny, no `:ask` branch exists.

  Deliberately does NOT run `shell_execute` (e.g. `git status`/`git diff`):
  `Prefetch.Cache` can only prove a cached result is still fresh when it
  watches a single stat-able path, and a shell command's output does not fit
  that shape — see `Prefetch.Heuristics`' moduledoc for why no candidate for
  it is ever generated in the first place.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Builtins.DirList.Tool, as: DirListTool
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Tool, as: FileReadTool
  alias OptimalSystemAgent.Tools.UseContext

  @modules %{
    "file_read" => FileReadTool,
    "dir_list" => DirListTool
  }

  @doc "Tool names this module is willing to run at all."
  @spec supported?(String.t()) :: boolean()
  def supported?(tool_name), do: Map.has_key?(@modules, tool_name)

  @doc """
  Run `tool_name(args)` under a `UseContext` built for `session_id`, but ONLY
  if every stage (`validate_input` -> `check_permissions`) resolves to
  `{:allow, _}`. Any other outcome — a deny, a validation error, an `:ask`, or
  an unsupported tool name — returns `:skip`. Never raises: a background guess
  crashing is a lost prefetch, not a lost turn.
  """
  @spec run(String.t(), map(), String.t() | nil) :: {:ok, String.t()} | :skip
  def run(tool_name, args, session_id) do
    with mod when not is_nil(mod) <- Map.get(@modules, tool_name),
         ctx <- ctx_for(session_id),
         {:ok, validated} <- safe_call(mod, :validate_input, [args, ctx]),
         {:allow, allowed} <- safe_call(mod, :check_permissions, [validated, ctx]),
         {:ok, result} <- safe_execute(mod, allowed, ctx) do
      {:ok, result}
    else
      _ -> :skip
    end
  rescue
    e ->
      Logger.debug("[prefetch] #{tool_name} raised: #{Exception.message(e)}")
      :skip
  catch
    :exit, reason ->
      Logger.debug("[prefetch] #{tool_name} exited: #{inspect(reason)}")
      :skip
  end

  # The REAL session id, not `UseContext.empty/0`'s `"test"` sentinel: a hit
  # here must be indistinguishable, to `Tools.FileState`'s read-before-edit
  # ledger, from the model having read the file itself. Using the exempt
  # `"test"` session would make every prefetched file invisible to that
  # ledger, and a `file_edit` right after a cache-served `file_read` would be
  # wrongly told the file was never read this session.
  defp ctx_for(session_id) do
    UseContext.new(%{session_id: session_id, permission_tier: :read_only})
  end

  defp safe_call(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp safe_execute(mod, args, ctx) do
    case mod.execute(args, ctx) do
      {:ok, content} when is_binary(content) -> {:ok, content}
      # Images and any other shape are not cached — see the Engine moduledoc.
      _other -> :skip
    end
  end
end
