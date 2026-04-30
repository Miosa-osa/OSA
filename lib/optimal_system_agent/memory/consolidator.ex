defmodule OptimalSystemAgent.Memory.Consolidator do
  @moduledoc """
  Pattern consolidation for the SICA learning engine.

  Two consolidation modes:

    - **Incremental** (every 5 interactions) — Merge similar patterns, prune
      entries not seen in 7 days with fewer than 2 occurrences.
    - **Full** (every 50 interactions) — Same as incremental but with a stricter
      3-day staleness window and skill-candidate identification.

  Pattern similarity is measured with Jaccard similarity on description words.
  Two patterns are considered mergeable when their triggers match exactly and
  their descriptions share >= 70% of words.

  All SQLite writes go through `OptimalSystemAgent.Store.Pattern` via Ecto.
  """

  require Logger

  alias OptimalSystemAgent.Store.{Repo, Pattern}
  import Ecto.Query

  @similarity_threshold 0.7
  @stale_days_incremental 7
  @stale_days_full 3
  @maturity_threshold 5

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run an incremental consolidation pass.

  Loads all patterns from SQLite, merges similar ones, prunes stale single-
  occurrence entries, and returns a report map.
  """
  @spec incremental() :: map()
  def incremental do
    patterns = load_all()
    run_pass(patterns, @stale_days_incremental, :incremental)
  end

  @doc """
  Run a full consolidation pass.

  Same as incremental but uses a 3-day staleness window and additionally
  identifies skill-generation candidates (patterns seen >= 5 times).
  """
  @spec full() :: map()
  def full do
    patterns = load_all()
    run_pass(patterns, @stale_days_full, :full)
  end

  @doc """
  Upsert a pattern by trigger key.

  If a pattern with the same trigger exists, its occurrence count is
  incremented. Otherwise a new record is inserted.
  """
  @spec upsert(map()) :: :ok
  def upsert(attrs) when is_map(attrs) do
    trigger = attrs.trigger
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(Pattern, trigger: trigger) do
      nil ->
        id = generate_id(trigger)

        %Pattern{}
        |> Pattern.changeset(%{
          id: id,
          description: attrs.description,
          trigger: trigger,
          response: to_string(attrs.response),
          category: attrs[:category] || "context",
          occurrences: 1,
          success_rate: 1.0,
          tags: attrs[:tags] || "",
          created_at: now,
          last_seen: now
        })
        |> Repo.insert()
        |> case do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning("[Consolidator] insert failed: #{inspect(changeset.errors)}")
        end

      existing ->
        existing
        |> Pattern.changeset(%{occurrences: existing.occurrences + 1, last_seen: now})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning("[Consolidator] update failed: #{inspect(changeset.errors)}")
        end
    end
  rescue
    e ->
      Logger.warning("[Consolidator] upsert error: #{Exception.message(e)}")
  end

  @doc "Load all patterns from SQLite as plain maps."
  @spec load_all() :: [map()]
  def load_all do
    Repo.all(Pattern)
    |> Enum.map(&to_map/1)
  rescue
    e ->
      Logger.warning("[Consolidator] load_all error: #{Exception.message(e)}")
      []
  end

  @doc "Load solution/correction patterns from SQLite."
  @spec load_solutions() :: [map()]
  def load_solutions do
    from(p in Pattern, where: p.category == "solution" or p.category == "correction")
    |> Repo.all()
    |> Enum.map(&to_map/1)
  rescue
    e ->
      Logger.warning("[Consolidator] load_solutions error: #{Exception.message(e)}")
      []
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_pass(patterns, stale_days, mode) do
    {merged, merge_count} = merge_similar(patterns)

    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-stale_days * 86_400, :second)
      |> DateTime.to_iso8601()

    {active, pruned} =
      Enum.split_with(merged, fn p ->
        p.occurrences >= 2 or (p.last_seen || "") >= cutoff
      end)

    pruned_ids = Enum.map(pruned, & &1.id)
    delete_by_ids(pruned_ids)

    base = %{
      type: mode,
      patterns_before: length(patterns),
      patterns_after: length(active),
      merged: merge_count,
      pruned: length(pruned),
      timestamp: DateTime.utc_now()
    }

    if mode == :full do
      mature =
        active |> Enum.filter(&(&1.occurrences >= @maturity_threshold)) |> Enum.map(& &1.id)

      # Auto-generate skills from mature patterns
      if length(mature) > 0 do
        try do
          OptimalSystemAgent.Memory.SkillGenerator.generate_all_pending()
        rescue
          e -> Logger.debug("[Consolidator] Skill generation skipped: #{inspect(e)}")
        end
      end

      Map.merge(base, %{skill_candidates: length(mature), skill_candidate_ids: mature})
    else
      base
    end
  end

  defp merge_similar(patterns) do
    {result, count} =
      Enum.reduce(patterns, {[], 0}, fn pattern, {acc, merge_count} ->
        case find_similar_in(pattern, acc) do
          nil ->
            {[pattern | acc], merge_count}

          existing ->
            merged = merge_two(existing, pattern)
            updated = Enum.map(acc, fn p -> if p.id == existing.id, do: merged, else: p end)
            {updated, merge_count + 1}
        end
      end)

    {Enum.reverse(result), count}
  end

  defp find_similar_in(pattern, candidates) do
    Enum.find(candidates, fn c ->
      c.id != pattern.id and
        c.trigger == pattern.trigger and
        jaccard(pattern.description, c.description) >= @similarity_threshold
    end)
  end

  defp merge_two(a, b) do
    total = a.occurrences + b.occurrences
    weighted = (a.success_rate * a.occurrences + b.success_rate * b.occurrences) / max(total, 1)

    merged_tags =
      [a.tags || "", b.tags || ""]
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join(",")

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get(Pattern, a.id) do
      nil ->
        :ok

      record ->
        record
        |> Pattern.changeset(%{
          occurrences: total,
          success_rate: min(1.0, weighted),
          tags: merged_tags,
          last_seen: now
        })
        |> Repo.update()
    end

    Map.merge(a, %{
      occurrences: total,
      success_rate: min(1.0, weighted),
      tags: merged_tags,
      last_seen: now
    })
  rescue
    e ->
      Logger.warning("[Consolidator] merge_two error: #{Exception.message(e)}")
      a
  end

  defp jaccard(a, b) when is_binary(a) and is_binary(b) do
    wa = a |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()
    wb = b |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()
    inter = MapSet.intersection(wa, wb) |> MapSet.size()
    union = MapSet.union(wa, wb) |> MapSet.size()
    if union == 0, do: 0.0, else: inter / union
  end

  defp jaccard(_, _), do: 0.0

  defp delete_by_ids([]), do: :ok

  defp delete_by_ids(ids) do
    Repo.delete_all(from(p in Pattern, where: p.id in ^ids))
  rescue
    e ->
      Logger.warning("[Consolidator] delete_by_ids error: #{Exception.message(e)}")
  end

  defp to_map(%Pattern{} = p) do
    %{
      id: p.id,
      description: p.description,
      trigger: p.trigger,
      response: p.response,
      category: p.category,
      occurrences: p.occurrences,
      success_rate: p.success_rate,
      tags: p.tags,
      created_at: p.created_at,
      last_seen: p.last_seen
    }
  end

  defp generate_id(seed) do
    ts = System.system_time(:nanosecond) |> to_string()
    :crypto.hash(:sha256, seed <> ts) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
