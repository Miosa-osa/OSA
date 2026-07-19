defmodule OptimalSystemAgent.Tools.Registry.SkillTouch do
  @moduledoc """
  Session-scoped set of filesystem paths touched this session, used for
  `paths`-glob lazy skill surfacing (progressive disclosure).

  A skill whose SKILL.md frontmatter declares `paths:` globs is withheld from
  the model-facing listing until a file matching one of those globs is touched
  during the session. This module records those touches, keyed by session id.

  Backed by a single public ETS table. The table is created lazily by the
  first caller and, in the running system, is owned by the long-lived
  `Tools.Registry` GenServer (see `Registry.init/1` → `ensure_table/0`) so the
  touched-path state survives for the life of the node. In tests the first
  caller owns it; if the owner dies the table simply resets, which is a safe
  degradation (gated skills fall back to hidden until re-touched).

  This module is a passive recorder. Wiring `record/2` into the file tools /
  agent loop is the integration hook; the loop/reminders are out of scope for
  the skills-discovery modules, so `Registry.record_touched_path/2` is exposed
  as the single-line call site for that owner.
  """

  @table :osa_skill_touched_paths

  @doc "Ensure the backing ETS table exists. Idempotent, race-safe."
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          # Lost the create race to another process — the table now exists.
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  @doc """
  Record that `path` was touched during `session_id`.

  Both are coerced to strings. No-op (best effort) on any failure.
  """
  @spec record(term(), String.t()) :: :ok
  def record(session_id, path) when is_binary(path) and path != "" do
    ensure_table()
    key = skey(session_id)

    set =
      case :ets.lookup(@table, key) do
        [{^key, existing}] -> existing
        _ -> MapSet.new()
      end

    :ets.insert(@table, {key, MapSet.put(set, path)})
    :ok
  rescue
    _ -> :ok
  end

  def record(_session_id, _path), do: :ok

  @doc "List the paths touched so far this session. Newest membership is unordered."
  @spec list(term()) :: [String.t()]
  def list(session_id) do
    ensure_table()

    case :ets.lookup(@table, skey(session_id)) do
      [{_key, set}] -> MapSet.to_list(set)
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "Clear all touched paths for a session."
  @spec reset(term()) :: :ok
  def reset(session_id) do
    ensure_table()
    :ets.delete(@table, skey(session_id))
    :ok
  rescue
    _ -> :ok
  end

  defp skey(session_id), do: {to_string(session_id)}
end
