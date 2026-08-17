defmodule OptimalSystemAgent.Skills.Advisor do
  @moduledoc """
  Bounded, cached skill recommendations for the current task.

  The advisor ranks metadata only. It never loads a SKILL.md body into model
  context. The model still activates a recommendation explicitly through
  `skill_view`, preserving progressive disclosure as the library grows.
  """

  require Logger

  alias OptimalSystemAgent.Skills.Ranker

  @table :osa_skill_advisor_cache
  @ttl_ms 5 * 60 * 1_000

  @spec recommend([map()], String.t(), keyword()) :: [map()]
  def recommend(skills, query, opts \\ [])

  def recommend(skills, query, opts) when is_list(skills) and is_binary(query) do
    limit = Keyword.get(opts, :limit, 5)
    started = System.monotonic_time(:microsecond)
    ensure_table()
    sweep_expired()
    key = cache_key(skills, query, limit)

    {recommendations, cache_hit} =
      case :ets.lookup(@table, key) do
        [{^key, inserted_at, cached}] when is_integer(inserted_at) ->
          if System.monotonic_time(:millisecond) - inserted_at <= @ttl_ms do
            {cached, true}
          else
            :ets.delete(@table, key)
            {rank(skills, query, limit), false}
          end

        _ ->
          {rank(skills, query, limit), false}
      end

    unless cache_hit do
      :ets.insert(@table, {key, System.monotonic_time(:millisecond), recommendations})
    end

    :telemetry.execute(
      [:osa, :skills, :recommend],
      %{
        duration_us: System.monotonic_time(:microsecond) - started,
        candidates: length(skills),
        recommendations: length(recommendations),
        cache_hit: if(cache_hit, do: 1, else: 0)
      },
      %{query_bytes: byte_size(query)}
    )

    recommendations
  rescue
    error ->
      Logger.error("[skills.advisor] recommendation failed: #{Exception.message(error)}")
      []
  end

  def recommend(_skills, _query, _opts), do: []

  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp rank(skills, query, limit) do
    skills
    |> Enum.map(fn skill ->
      text =
        [
          value(skill, :name),
          value(skill, :description),
          value(skill, :triggers) |> List.wrap() |> Enum.join(" ")
        ]
        |> Enum.join(" ")

      score = Ranker.relevance(text, query) + trigger_bonus(skill, query)
      %{skill: skill, score: score, confidence: confidence(score)}
    end)
    |> Enum.filter(&(&1.score > 0.0))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp trigger_bonus(skill, query) do
    lower = String.downcase(query)

    skill
    |> value(:triggers)
    |> List.wrap()
    |> Enum.any?(fn trigger ->
      trigger = trigger |> to_string() |> String.downcase()
      trigger not in ["", "*"] and String.contains?(lower, trigger)
    end)
    |> if(do: 3.0, else: 0.0)
  end

  defp confidence(score) when score >= 5.0, do: :high
  defp confidence(score) when score >= 2.0, do: :medium
  defp confidence(_score), do: :low

  defp cache_key(skills, query, limit) do
    fingerprint =
      Enum.map(skills, fn skill ->
        {value(skill, :name), value(skill, :description), value(skill, :triggers)}
      end)

    :erlang.phash2({fingerprint, String.downcase(String.trim(query)), limit})
  end

  defp value(skill, key) when is_map(skill),
    do: Map.get(skill, key) || Map.get(skill, to_string(key))

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      rescue
        ArgumentError -> @table
      end
    end
  end

  defp sweep_expired do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
  end
end
