defmodule OptimalSystemAgent.Store.SessionTranscript do
  @moduledoc """
  Ecto schema for session transcripts with FTS5 full-text search.

  Every user message and assistant response is persisted here so that
  the agent can search past conversations via the `session_search` tool.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

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
      content: normalize_content(content),
      tool_name: Keyword.get(opts, :tool_name),
      tokens: Keyword.get(opts, :tokens, 0)
    }

    case changeset(attrs) |> Repo.insert() do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        # Callers ignore this return value, so log the failure to make otherwise
        # silent transcript loss (e.g. lock contention) observable.
        Logger.warning(
          "[transcript] save_turn failed for session #{inspect(session_id)}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  rescue
    e ->
      Logger.warning(
        "[transcript] save_turn raised for session #{inspect(session_id)}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
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
      order_by: [asc: t.inserted_at, asc: t.id]
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @default_retention_days 30
  @default_max_rows 200_000

  @doc """
  Apply the retention policy (see the moduledoc) and return
  `{:ok, %{by_age: n, by_cap: n}}` — the row counts removed by each half.

  Best-effort and never raises: a retention sweep must never be able to stop the
  daemon booting. Options (`:days`, `:max_rows`) exist for tests; production
  callers pass nothing and get the configured/default policy.
  """
  @spec purge_expired(keyword()) :: {:ok, %{by_age: non_neg_integer(), by_cap: non_neg_integer()}}
  def purge_expired(opts \\ []) do
    days = Keyword.get_lazy(opts, :days, fn -> setting("transcriptRetentionDays", @default_retention_days) end)
    max_rows = Keyword.get_lazy(opts, :max_rows, fn -> setting("transcriptMaxRows", @default_max_rows) end)

    by_age = purge_by_age(days)
    by_cap = purge_by_cap(max_rows)

    if by_age + by_cap > 0 do
      Logger.info(
        "[transcript] retention: removed #{by_age} row(s) older than #{days}d, " <>
          "#{by_cap} row(s) over the #{max_rows}-row cap"
      )
    end

    {:ok, %{by_age: by_age, by_cap: by_cap}}
  rescue
    e ->
      Logger.warning("[transcript] retention sweep failed: #{Exception.message(e)}")
      {:ok, %{by_age: 0, by_cap: 0}}
  end

  # 0 disables the age half of the policy (keep everything, rely on the cap).
  defp purge_by_age(days) when not is_integer(days) or days <= 0, do: 0

  defp purge_by_age(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.to_naive()

    {count, _} =
      from(t in __MODULE__, where: t.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  rescue
    _ -> 0
  end

  # 0 disables the cap half. Deletes oldest-first by id (monotonic rowid — a
  # stabler ordering than inserted_at, whose second resolution ties within a
  # burst of turns).
  defp purge_by_cap(max_rows) when not is_integer(max_rows) or max_rows <= 0, do: 0

  defp purge_by_cap(max_rows) do
    total = Repo.aggregate(__MODULE__, :count, :id)

    if total > max_rows do
      excess = total - max_rows

      # Sub-select the ids to drop so the cap is applied in a single statement
      # and the FTS delete trigger fires for each row.
      doomed =
        from(t in __MODULE__, order_by: [asc: t.id], limit: ^excess, select: t.id)
        |> Repo.all()

      {count, _} = from(t in __MODULE__, where: t.id in ^doomed) |> Repo.delete_all()
      count
    else
      0
    end
  rescue
    _ -> 0
  end

  defp setting(key, default) do
    case OptimalSystemAgent.Settings.get(key, default) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  rescue
    _ -> default
  end

  @doc "Current row count — used by retention tests and diagnostics."
  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(__MODULE__, :count, :id)

  # The :content column is :string. Structured messages (vision turns carry
  # a list of content blocks — see MessageHandler.build_messages/3) would
  # fail the Ecto cast and be silently dropped; flatten block lists to text
  # ("[image]" placeholder per image block) so every turn survives
  # persistence. nil passes through so validate_required still catches
  # genuine caller bugs.
  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: "text", text: text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: "image"} -> "[image]"
      %{"type" => "image"} -> "[image]"
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp normalize_content(nil), do: nil
  defp normalize_content(content), do: inspect(content)

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
