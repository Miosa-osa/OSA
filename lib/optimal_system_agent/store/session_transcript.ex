defmodule OptimalSystemAgent.Store.SessionTranscript do
  @moduledoc """
  Ecto schema for session transcripts with FTS5 full-text search.

  Every user message and assistant response is persisted here so that
  the agent can search past conversations via the `session_search` tool.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias OptimalSystemAgent.Store.Repo

  schema "session_transcripts" do
    field(:session_id, :string)
    field(:role, :string)
    field(:content, :string)
    field(:tool_name, :string)
    field(:tokens, :integer, default: 0)
    timestamps()
  end

  @required ~w(session_id role content)a
  @optional ~w(tool_name tokens)a

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc "Save a conversation turn to the transcript store."
  def save_turn(session_id, role, content, opts \\ []) do
    attrs = %{
      session_id: session_id,
      role: role,
      content: content,
      tool_name: Keyword.get(opts, :tool_name),
      tokens: Keyword.get(opts, :tokens, 0)
    }

    case changeset(attrs) |> Repo.insert() do
      {:ok, record} -> {:ok, record}
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Full-text search across all session transcripts.

  Returns a list of maps with `:session_id`, `:role`, `:content`,
  `:tool_name`, `:inserted_at`, and `:highlight` (matched snippet).
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    sanitized = sanitize_fts_query(query)

    sql = """
    SELECT t.session_id, t.role, t.content, t.tool_name, t.inserted_at,
           snippet(session_transcripts_fts, 0, '**', '**', '...', 40) as highlight
    FROM session_transcripts_fts fts
    JOIN session_transcripts t ON t.id = fts.rowid
    WHERE session_transcripts_fts MATCH ?1
    ORDER BY rank
    LIMIT ?2
    """

    case Repo.query(sql, [sanitized, limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          columns |> Enum.zip(row) |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
        end)

      {:error, _reason} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "List recent sessions with message counts."
  def list_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    sql = """
    SELECT session_id,
           COUNT(*) as message_count,
           MIN(inserted_at) as started_at,
           MAX(inserted_at) as last_active,
           SUBSTR(MIN(CASE WHEN role = 'user' THEN content END), 1, 100) as first_message
    FROM session_transcripts
    GROUP BY session_id
    ORDER BY MAX(inserted_at) DESC
    LIMIT ?1
    """

    case Repo.query(sql, [limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          columns |> Enum.zip(row) |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
        end)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Get full transcript for a session."
  def get_transcript(session_id) do
    from(t in __MODULE__,
      where: t.session_id == ^session_id,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  # Sanitize FTS5 query to prevent injection — escape special chars
  defp sanitize_fts_query(query) do
    query
    |> String.replace(~r/["\(\)\*\-\+]/, " ")
    |> String.trim()
    |> case do
      "" -> "*"
      q -> q
    end
  end
end
