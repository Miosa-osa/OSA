defmodule OptimalSystemAgent.Agent.Memory.SQLiteBridge do
  @moduledoc """
  Secondary store bridge from OptimalSystemAgent.Memory to OSA's Ecto/SQLite message store.

  Implements the secondary_store contract expected by OptimalSystemAgent.Memory.Store:
    - append/2 — persist a message entry to SQLite
    - load/1   — load messages for a session from SQLite (falls back to nil on error)
    - session_stats/1 — query aggregated stats for a session

  Configured via:

      config :miosa_memory, secondary_store: OptimalSystemAgent.Agent.Memory.SQLiteBridge
  """

  require Logger

  alias OptimalSystemAgent.Store.{Repo, Message}
  import Ecto.Query

  @doc "Persist a message entry to SQLite."
  def append(session_id, entry) do
    attrs = %{
      session_id: session_id,
      role: to_string(Map.get(entry, :role, Map.get(entry, "role", "user"))),
      content: ensure_utf8(Map.get(entry, :content, Map.get(entry, "content", ""))),
      tool_calls: Map.get(entry, :tool_calls, Map.get(entry, "tool_calls")),
      tool_call_id: Map.get(entry, :tool_call_id, Map.get(entry, "tool_call_id")),
      token_count: parse_int(Map.get(entry, :token_count, Map.get(entry, "token_count"))),
      channel: get_string(entry, :channel),
      metadata: Map.get(entry, :metadata, Map.get(entry, "metadata", %{}))
    }

    case Message.changeset(attrs) |> Repo.insert() do
      {:ok, _msg} ->
        :ok

      {:error, changeset} ->
        Logger.warning("[SQLiteBridge] Failed to persist message: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[SQLiteBridge] append error: #{Exception.message(e)}")
      :ok
  end

  @doc "Load messages for a session from SQLite. Returns nil on failure (triggers JSONL fallback)."
  def load(session_id) do
    messages =
      from(m in Message,
        where: m.session_id == ^session_id,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(fn msg ->
        base = %{
          "role" => msg.role,
          "content" => msg.content,
          "timestamp" => NaiveDateTime.to_iso8601(msg.inserted_at)
        }

        base
        |> maybe_put("tool_calls", msg.tool_calls)
        |> maybe_put("tool_call_id", msg.tool_call_id)
        |> maybe_put("token_count", msg.token_count)
        |> maybe_put("channel", msg.channel)
      end)

    if messages == [], do: nil, else: messages
  rescue
    _ -> nil
  end

  @doc "Search messages across all sessions by content (SQLite LIKE query)."
  def search_messages(query, opts) do
    limit = Keyword.get(opts, :limit, 20)
    pattern = "%#{query}%"

    from(m in Message,
      where: like(m.content, ^pattern),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      select: %{
        id: m.id,
        session_id: m.session_id,
        role: m.role,
        content: m.content,
        inserted_at: m.inserted_at
      }
    )
    |> Repo.all()
  rescue
    e ->
      Logger.warning("[SQLiteBridge] search_messages error: #{Exception.message(e)}")
      []
  end

  @doc "Get aggregated session statistics from SQLite."
  def session_stats(session_id) do
    stats =
      from(m in Message,
        where: m.session_id == ^session_id,
        select: %{
          count: count(m.id),
          total_tokens: sum(m.token_count),
          first_at: min(m.inserted_at),
          last_at: max(m.inserted_at)
        }
      )
      |> Repo.one()

    role_counts =
      from(m in Message,
        where: m.session_id == ^session_id,
        group_by: m.role,
        select: {m.role, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.put(stats || %{}, :roles, role_counts)
  rescue
    _ -> %{count: 0, total_tokens: 0, roles: %{}}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp get_string(entry, key) do
    case Map.get(entry, key, Map.get(entry, to_string(key))) do
      nil -> nil
      val -> to_string(val)
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp ensure_utf8(nil), do: ""

  # Charlists are lists of Unicode codepoints. Pass :unicode as the input
  # encoding so :unicode.characters_to_binary/2 emits a valid UTF-8 binary.
  # The 1-arity form defaults to :latin1 input, which corrupts any codepoint
  # above 127 (accented letters, CJK, emoji become replacement characters).
  defp ensure_utf8(val) when is_list(val), do: :unicode.characters_to_binary(val, :unicode)

  defp ensure_utf8(val) when is_binary(val) do
    if String.valid?(val) do
      val
    else
      case :unicode.characters_to_binary(val, :utf8, :utf8) do
        bin when is_binary(bin) -> bin
        {:error, good, _bad} -> good
        {:incomplete, good, _rest} -> good
      end
    end
  end

  defp ensure_utf8(val), do: to_string(val)
end
