defmodule OptimalSystemAgent.Security.AnomalyQueue do
  @moduledoc """
  XBow chaining rule as code.

  A 500, odd SSRF clue, tiny upload, or off-scope redirect is a CLUE.
  It may not be dismissed until one more hop is recorded (or it is
  explicitly chained into a real finding). Empty open queues block a
  "clean" report.

  Named ETS table `:osa_security_anomaly`, keyed `{session_id, id}`.
  No network. No payloads.
  """

  @table :osa_security_anomaly
  @bing_rule "follow one hop before dismissing (XBow Bing rule)"
  @not_found "anomaly not found"
  @not_open "anomaly not open"

  @type kind :: :http_500 | :ssrf_clue | :odd_upload | :redirect_offscope | atom()
  @type status :: :open | :chained | :dismissed

  @type anomaly :: %{
          id: String.t(),
          kind: kind(),
          target: String.t(),
          note: String.t(),
          hops: non_neg_integer(),
          status: status(),
          inserted_at: DateTime.t()
        }

  @doc """
  Record a clue for `session_id`.

  Requires `target` (atom or string key). `kind` defaults to `:http_500`.
  Status is `:open`, hops start at 0. Generates `id` when missing.
  """
  @spec record(String.t(), map()) :: {:ok, anomaly()} | {:error, String.t()}
  def record(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    ensure_table()

    case required_target(attrs) do
      {:ok, target} ->
        rec = %{
          id: present_id(attrs) || generate_id(),
          kind: present_kind(attrs),
          target: target,
          note: optional_note(attrs),
          hops: 0,
          status: :open,
          inserted_at: optional_inserted_at(attrs) || DateTime.utc_now()
        }

        write(session_id, rec)
        {:ok, rec}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Record one follow-up hop on an open clue.

  Increments `hops`. Status stays `:open` until `dismiss/2` or `chain/2`.
  """
  @spec hop(String.t(), String.t(), String.t()) :: {:ok, anomaly()} | {:error, String.t()}
  def hop(session_id, id, note)
      when is_binary(session_id) and is_binary(id) and is_binary(note) do
    ensure_table()

    with {:ok, rec} <- fetch(session_id, id),
         :ok <- require_open(rec) do
      updated = %{rec | hops: rec.hops + 1, note: append_note(rec.note, note)}
      write(session_id, updated)
      {:ok, updated}
    end
  end

  @doc "Mark the clue `:chained` (it became a real finding). Allowed with zero hops."
  @spec chain(String.t(), String.t()) :: {:ok, anomaly()} | {:error, String.t()}
  def chain(session_id, id) when is_binary(session_id) and is_binary(id) do
    ensure_table()

    with {:ok, rec} <- fetch(session_id, id) do
      updated = %{rec | status: :chained}
      write(session_id, updated)
      {:ok, updated}
    end
  end

  @doc """
  Dismiss a clue.

  Only allowed when `hops >= 1`. Otherwise errors with the XBow Bing rule.
  """
  @spec dismiss(String.t(), String.t()) :: :ok | {:error, String.t()}
  def dismiss(session_id, id) when is_binary(session_id) and is_binary(id) do
    ensure_table()

    with {:ok, rec} <- fetch(session_id, id),
         :ok <- require_hop(rec) do
      write(session_id, %{rec | status: :dismissed})
      :ok
    end
  end

  @doc "Clues still `:open` for the session, insertion order."
  @spec open(String.t()) :: [anomaly()]
  def open(session_id) when is_binary(session_id) do
    ensure_table()

    @table
    |> :ets.match({{session_id, :_}, :"$1", :"$2"})
    |> Enum.sort_by(fn [_rec, seq] -> seq end)
    |> Enum.flat_map(fn
      [%{status: :open} = rec, _] -> [rec]
      _ -> []
    end)
  end

  @doc """
  Fail closed before a "clean" report.

  `:ok` when no `:open` clues remain. Error message includes the open count.
  """
  @spec assert_clear(String.t()) :: :ok | {:error, String.t()}
  def assert_clear(session_id) when is_binary(session_id) do
    case open(session_id) do
      [] -> :ok
      remaining -> {:error, "#{length(remaining)} open anomalies remain"}
    end
  end

  @doc """
  Record a 5xx HTTP response as `:http_500`.

  Non-5xx (including `nil`) is `:ignored`.
  """
  @spec from_http(String.t(), integer() | nil, String.t()) ::
          {:ok, anomaly()} | {:error, String.t()} | :ignored
  def from_http(session_id, status, target)
      when is_binary(session_id) and is_integer(status) and status in 500..599 and
             is_binary(target) do
    record(session_id, %{kind: :http_500, target: target, note: "HTTP #{status}"})
  end

  def from_http(session_id, _status, _target) when is_binary(session_id), do: :ignored

  defp fetch(session_id, id) do
    case :ets.lookup(@table, {session_id, id}) do
      [{_key, rec, _seq}] -> {:ok, rec}
      [] -> {:error, @not_found}
    end
  end

  defp require_open(%{status: :open}), do: :ok
  defp require_open(_), do: {:error, @not_open}

  defp require_hop(%{hops: hops}) when hops >= 1, do: :ok
  defp require_hop(_), do: {:error, @bing_rule}

  defp write(session_id, rec) do
    seq =
      case :ets.lookup(@table, {session_id, rec.id}) do
        [{_key, _rec, seq}] -> seq
        [] -> System.unique_integer([:monotonic])
      end

    :ets.insert(@table, {{session_id, rec.id}, rec, seq})
  end

  defp required_target(attrs) do
    case field(attrs, :target) do
      target when is_binary(target) and target != "" -> {:ok, target}
      _ -> {:error, "target is required"}
    end
  end

  defp present_id(attrs) do
    case field(attrs, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp present_kind(attrs) do
    case field(attrs, :kind) do
      kind when is_atom(kind) and kind != nil -> kind
      kind when is_binary(kind) and kind != "" -> String.to_existing_atom(kind)
      _ -> :http_500
    end
  rescue
    ArgumentError -> :http_500
  end

  defp optional_note(attrs) do
    case field(attrs, :note) do
      note when is_binary(note) -> note
      _ -> ""
    end
  end

  defp optional_inserted_at(attrs) do
    case field(attrs, :inserted_at) do
      %DateTime{} = dt -> dt
      _ -> nil
    end
  end

  defp append_note("", hop_note), do: hop_note

  defp append_note(existing, hop_note) when hop_note == "", do: existing

  defp append_note(existing, hop_note), do: existing <> " | " <> hop_note

  defp field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp generate_id do
    "aq-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
