defmodule OptimalSystemAgent.Agent.Fleet.Journal do
  @moduledoc """
  Durable per-item record of one `Fleet.fan_out/3`, so a coordinator crash does
  not lose the work its nodes already finished.

  ## What was missing

  `Fleet.fan_out/3` accumulated results only in the return value of its
  `Enum.map` over the `Task.async_stream`. That value lives in the coordinator
  process and nowhere else, so if the coordinator died — crash, daemon restart,
  the user killing `osa` — every finished node's result was lost even though
  the work itself had been done and, under worktree isolation, committed to a
  branch on disk.

  `Agent.FleetResumer` does NOT close this. It is a boot-time re-dispatcher for
  orphaned `:running` **nodes**: it walks `RunStore`, claims ownership leases,
  and restarts individual subagents through `Orchestrator.resume_subagent/2`.
  It has no notion of a fan-out at all — no run id, no item list, no result
  set — and it says so itself: only STARTED nodes are durable, a queued item
  that had not begun has no `RunStore` row and "CANNOT be recovered". This
  module is the coordinator-side half the resumer explicitly leaves out.

  ## Shape

  One append-only JSONL file per fan-out run:

      ~/.osa/fleet/<run_id>.jsonl

  Each line is one entry keyed by `(seq, kind, request_hash)`:

    * `seq` — the item's submission index, its position in the caller's list.
    * `kind` — `"queued"` when the item was accepted for this run, `"result"`
      when it reached a terminal outcome.
    * `request_hash` — a hash of the normalized item. It is what makes replay
      safe: a `"result"` entry is only honoured when the item at that `seq`
      still hashes the same. A resumed run whose item list changed underneath
      it re-executes rather than silently adopting a result for different work.

  Append-only, one `File.write(:append)` per entry: a torn final line loses at
  most the newest entry and every earlier one still replays, which is why this
  is not an atomic whole-file rewrite.

  ## Replay contract

  `completed/2` is read BEFORE anything is spawned. Every item with a matching
  `"result"` entry is returned from the journal instead of being re-executed,
  so a resumed run never re-runs a sibling that already finished — the
  expensive and destructive half of a naive retry, since a fan-out node is a
  full agent turn that writes to the repo.
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.System.AtomicFile

  @type entry :: %{
          seq: non_neg_integer(),
          kind: :queued | :result,
          request_hash: String.t(),
          result: map() | nil
        }

  @doc "Directory holding every fan-out journal."
  @spec dir() :: String.t()
  def dir, do: Path.join(ConfigFile.config_dir(), "fleet")

  @doc "Absolute path to one run's journal."
  @spec path(String.t()) :: String.t()
  def path(run_id) when is_binary(run_id) do
    Path.join(dir(), "#{safe_id(run_id)}.jsonl")
  end

  defp safe_id(id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")

  @doc """
  Stable hash of a fan-out item.

  Normalizes the three accepted item shapes (binary task, keyword list, map) to
  one canonical sorted form first, so `[task: "x", agent_type: "y"]` and
  `%{"agent_type" => "y", "task" => "x"}` hash alike — the same item written
  two ways must not look like different work on replay.
  """
  @spec request_hash(term()) :: String.t()
  def request_hash(item) do
    item
    |> normalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp normalize(item) when is_binary(item), do: normalize(task: item)

  defp normalize(item) when is_list(item) do
    item
    |> Enum.map(fn {k, v} -> {to_string(k), inspect(v)} end)
    |> Enum.sort()
  end

  defp normalize(item) when is_map(item) do
    item |> Map.to_list() |> normalize()
  end

  defp normalize(item), do: [{"raw", inspect(item)}]

  @doc """
  Record that `item` at position `seq` was accepted for this run.

  Written BEFORE the item is spawned, so a run that dies mid-drain still leaves
  evidence of the items it had taken on — the gap `FleetResumer` cannot see.
  """
  @spec record_queued(String.t(), non_neg_integer(), term()) :: :ok
  def record_queued(run_id, seq, item) do
    append(run_id, %{
      "seq" => seq,
      "kind" => "queued",
      "request_hash" => request_hash(item),
      "at" => now()
    })
  end

  @doc """
  Record the terminal `result` of the item at `seq`.

  Written as soon as the item reaches a terminal outcome rather than at the end
  of the drain — the whole point is that a coordinator dying at item 9 of 10
  keeps items 1..8.
  """
  @spec record_result(String.t(), non_neg_integer(), term(), map()) :: :ok
  def record_result(run_id, seq, item, result) when is_map(result) do
    append(run_id, %{
      "seq" => seq,
      "kind" => "result",
      "request_hash" => request_hash(item),
      "result" => encode_result(result),
      "at" => now()
    })
  end

  @doc """
  Results already durably recorded for `run_id`, as `%{seq => result}`.

  Only entries whose `request_hash` still matches the item now at that `seq` are
  returned; anything else is ignored (and logged), so a changed item list can
  never adopt a stale result.
  """
  @spec completed(String.t(), [term()]) :: %{non_neg_integer() => map()}
  def completed(run_id, items) when is_binary(run_id) and is_list(items) do
    hashes = items |> Enum.with_index() |> Map.new(fn {i, s} -> {s, request_hash(i)} end)

    run_id
    |> read_entries()
    |> Enum.filter(&(&1["kind"] == "result"))
    |> Enum.reduce(%{}, fn e, acc ->
      seq = e["seq"]

      cond do
        not is_integer(seq) or not Map.has_key?(hashes, seq) ->
          acc

        Map.get(hashes, seq) != e["request_hash"] ->
          Logger.warning(
            "[Fleet.Journal] run #{run_id} seq #{seq}: journalled result is for different " <>
              "work than the item now at that position — re-executing rather than adopting it"
          )

          acc

        true ->
          Map.put(acc, seq, decode_result(e["result"]))
      end
    end)
  rescue
    e ->
      Logger.warning("[Fleet.Journal] replay failed for #{run_id}: #{Exception.message(e)}")
      %{}
  end

  def completed(_run_id, _items), do: %{}

  @doc """
  Every entry in a run's journal, oldest first. Malformed lines (a torn final
  append) are skipped, not fatal.
  """
  @spec read_entries(String.t()) :: [map()]
  def read_entries(run_id) when is_binary(run_id) do
    case File.read(path(run_id)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{} = entry} -> [entry]
            _ -> []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Items accepted for the run that never reached a result — what a resumed run
  still owes. Returns their `seq` values, ascending.
  """
  @spec outstanding(String.t()) :: [non_neg_integer()]
  def outstanding(run_id) when is_binary(run_id) do
    entries = read_entries(run_id)

    queued = for e <- entries, e["kind"] == "queued", is_integer(e["seq"]), do: e["seq"]
    done = for e <- entries, e["kind"] == "result", is_integer(e["seq"]), do: e["seq"]

    (queued -- done) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Delete a run's journal (the run is finished with and fully accounted for)."
  @spec discard(String.t()) :: :ok
  def discard(run_id) when is_binary(run_id) do
    _ = File.rm(path(run_id))
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────

  # Append-only. A journal write must never break the fan-out, but it is never
  # silent either: losing it is losing the crash recovery it exists to provide.
  defp append(run_id, entry) do
    file = path(run_id)
    _ = File.mkdir_p(Path.dirname(file))

    case File.write(file, Jason.encode!(entry) <> "\n", [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Fleet.Journal] could not journal #{entry["kind"]} for run #{run_id} " <>
            "(#{inspect(reason)}) — a crash from here would lose this item's outcome"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("[Fleet.Journal] append raised: #{Exception.message(e)}")
      :ok
  end

  # The O2 result map is a frozen contract of JSON-safe scalars plus atoms for
  # `gate`; round-trip the atoms explicitly so a replayed result is `==` to a
  # freshly produced one.
  defp encode_result(result) do
    %{
      "node_id" => to_string(Map.get(result, :node_id, "")),
      "worktree_ref" => Map.get(result, :worktree_ref),
      "files_changed" => Map.get(result, :files_changed, []),
      "gate" => to_string(Map.get(result, :gate, :fail)),
      "stubbed" => Map.get(result, :stubbed, []),
      "summary" => to_string(Map.get(result, :summary, "")),
      "error" => Map.get(result, :error) && inspect(Map.get(result, :error))
    }
  end

  @gates %{"pass" => :pass, "fail" => :fail, "skipped" => :skipped}

  defp decode_result(%{} = r) do
    %{
      node_id: to_string(Map.get(r, "node_id", "")),
      worktree_ref: Map.get(r, "worktree_ref"),
      files_changed: list_of_strings(Map.get(r, "files_changed")),
      # Unknown gate decodes to :fail, never :pass — a corrupted journal must
      # not be able to declare unverified work green.
      gate: Map.get(@gates, Map.get(r, "gate"), :fail),
      stubbed: list_of_strings(Map.get(r, "stubbed")),
      summary: to_string(Map.get(r, "summary", "")),
      error: Map.get(r, "error"),
      resumed: true
    }
  end

  defp decode_result(_) do
    %{
      node_id: "",
      worktree_ref: nil,
      files_changed: [],
      gate: :fail,
      stubbed: [],
      summary: "failed: unreadable journal entry",
      error: :unreadable_journal_entry,
      resumed: true
    }
  end

  defp list_of_strings(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp list_of_strings(_), do: []

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc false
  # Exposed so the fan-out can write the run manifest atomically; kept here so
  # every fleet-durability path resolves its directory the same way.
  def write_manifest(run_id, manifest) do
    AtomicFile.write(
      Path.join(dir(), "#{safe_id(run_id)}.manifest.json"),
      Jason.encode!(manifest)
    )
  rescue
    _ -> :ok
  end
end
