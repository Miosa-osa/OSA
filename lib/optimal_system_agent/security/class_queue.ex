defmodule OptimalSystemAgent.Security.ClassQueue do
  @moduledoc """
  Per-session queue of exploit candidates, keyed by vuln class.

  The exploitation gate fail-closes on an untouched class:
  never-created queues are `:not_assessed`, not "clean". Exploit work is
  allowed only when the class is `:queued` (has at least one candidate) or
  `:confirmed`. An empty unassessed class must not be marked clean.

  Named ETS table `:osa_security_class_queue`. No network. No payloads.
  """

  @table :osa_security_class_queue

  @type candidate :: %{
          id: String.t(),
          target: String.t(),
          note: String.t(),
          inserted_at: DateTime.t()
        }

  @type status :: :not_assessed | :queued | :exhausted | :confirmed

  @not_assessed_msg "class not assessed (empty queue) - do not mark clean"
  @exhausted_msg "class queue exhausted"

  @doc """
  Enqueue a candidate for `class` in `session_id`.

  Requires `target` (atom or string key). Generates `id` when missing.
  """
  @spec put(String.t(), atom(), map()) :: {:ok, candidate()} | {:error, String.t()}
  def put(session_id, class, candidate)
      when is_binary(session_id) and is_atom(class) and is_map(candidate) do
    ensure_table()

    case required_target(candidate) do
      {:ok, target} ->
        rec = %{
          id: present_id(candidate) || generate_id(),
          target: target,
          note: optional_note(candidate),
          inserted_at: optional_inserted_at(candidate) || DateTime.utc_now()
        }

        enqueue(session_id, class, rec)
        {:ok, rec}

      {:error, _} = err ->
        err
    end
  end

  @doc "Candidates for `class` in insertion order. Empty when the class was never queued."
  @spec list(String.t(), atom()) :: [candidate()]
  def list(session_id, class) when is_binary(session_id) and is_atom(class) do
    ensure_table()

    case lookup(session_id, class) do
      nil -> []
      %{candidates: candidates} -> candidates
    end
  end

  @doc """
  Class status.

  * no queue ever created -> `:not_assessed` (fail closed)
  * queue exists, marked exhausted -> `:exhausted`
  * queue has items -> `:queued`
  * `mark_confirmed/2` -> `:confirmed`
  """
  @spec status(String.t(), atom()) :: status()
  def status(session_id, class) when is_binary(session_id) and is_atom(class) do
    ensure_table()

    case lookup(session_id, class) do
      nil -> :not_assessed
      %{mark: :confirmed} -> :confirmed
      %{mark: :exhausted} -> :exhausted
      %{candidates: [_ | _]} -> :queued
      _ -> :exhausted
    end
  end

  @doc "True only when status is `:queued` or `:confirmed`."
  @spec exploit_allowed?(String.t(), atom()) :: boolean()
  def exploit_allowed?(session_id, class) when is_binary(session_id) and is_atom(class) do
    status(session_id, class) in [:queued, :confirmed]
  end

  @doc "Hard gate: `:ok` when queued or confirmed, else a fail-closed error."
  @spec assert_exploit(String.t(), atom()) :: :ok | {:error, String.t()}
  def assert_exploit(session_id, class) when is_binary(session_id) and is_atom(class) do
    case status(session_id, class) do
      :queued -> :ok
      :confirmed -> :ok
      :exhausted -> {:error, @exhausted_msg}
      :not_assessed -> {:error, @not_assessed_msg}
    end
  end

  @doc "Mark the class queue exhausted (creates the queue if it did not exist)."
  @spec mark_exhausted(String.t(), atom()) :: :ok
  def mark_exhausted(session_id, class) when is_binary(session_id) and is_atom(class) do
    ensure_table()
    write(session_id, class, %{candidates: [], mark: :exhausted})
    :ok
  end

  @doc "Mark the class confirmed. Exploit remains allowed."
  @spec mark_confirmed(String.t(), atom()) :: :ok
  def mark_confirmed(session_id, class) when is_binary(session_id) and is_atom(class) do
    ensure_table()
    existing = lookup(session_id, class) || %{candidates: []}
    write(session_id, class, %{candidates: existing.candidates, mark: :confirmed})
    :ok
  end

  @doc """
  Render every class that exists in the session.

  Unknown (never-created) classes are stated as `not_assessed`.
  """
  @spec render(String.t()) :: String.t()
  def render(session_id) when is_binary(session_id) do
    ensure_table()

    rows =
      @table
      |> :ets.match({{session_id, :"$1"}, :"$2"})
      |> Enum.sort_by(fn [class, _] -> Atom.to_string(class) end)
      |> Enum.map(fn [class, rec] ->
        "  #{class}: #{status_of(rec)} (#{length(rec.candidates)} candidates)"
      end)

    body =
      case rows do
        [] -> "  (none)"
        _ -> Enum.join(rows, "\n")
      end

    """
    class queue session=#{session_id}
    #{body}
    unknown classes: not_assessed
    """
    |> String.trim()
  end

  defp enqueue(session_id, class, rec) do
    case lookup(session_id, class) do
      nil ->
        write(session_id, class, %{candidates: [rec], mark: :queued})

      %{mark: :confirmed, candidates: existing} ->
        write(session_id, class, %{candidates: existing ++ [rec], mark: :confirmed})

      %{candidates: existing} ->
        write(session_id, class, %{candidates: existing ++ [rec], mark: :queued})
    end
  end

  defp status_of(%{mark: :confirmed}), do: :confirmed
  defp status_of(%{mark: :exhausted}), do: :exhausted
  defp status_of(%{candidates: [_ | _]}), do: :queued
  defp status_of(_), do: :exhausted

  defp lookup(session_id, class) do
    case :ets.lookup(@table, {session_id, class}) do
      [{_, rec}] -> rec
      [] -> nil
    end
  end

  defp write(session_id, class, rec) do
    :ets.insert(@table, {{session_id, class}, rec})
  end

  defp required_target(candidate) do
    case field(candidate, :target) do
      target when is_binary(target) and target != "" -> {:ok, target}
      _ -> {:error, "target is required"}
    end
  end

  defp present_id(candidate) do
    case field(candidate, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp optional_note(candidate) do
    case field(candidate, :note) do
      note when is_binary(note) -> note
      _ -> ""
    end
  end

  defp optional_inserted_at(candidate) do
    case field(candidate, :inserted_at) do
      %DateTime{} = dt -> dt
      _ -> nil
    end
  end

  defp field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp generate_id do
    "cq-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
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
