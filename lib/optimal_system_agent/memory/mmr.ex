defmodule OptimalSystemAgent.Memory.MMR do
  @moduledoc """
  Maximal Marginal Relevance re-ranking for memory recall candidates.

  Greedy MMR selects, one at a time, the candidate that maximises

      MMR(d) = lambda * relevance(d) - (1 - lambda) * max_sim(d, selected)

  where `relevance(d)` is the candidate's hybrid recall score and
  `max_sim(d, selected)` is the highest pairwise similarity between `d` and
  anything already picked. This is what keeps the memory block injected into
  context from filling up with three near-duplicate phrasings of the same
  fact (which wastes the tight `Budget.memory_context_token_cap/0` budget
  `Context.recall_scored/2` fights to protect) while still favouring the
  most query-relevant entries first.

  Reference: grok `xai-grok-memory/src/mmr.rs`.

  Pairwise similarity prefers cosine similarity over embedding vectors (when
  available — see `Memory.Search`) and gracefully falls back to keyword
  Jaccard overlap (via `Memory.Scoring.keyword_overlap/2`) when embeddings
  are missing for one or both entries, so MMR still functions in
  embeddings-unavailable / keyword-only mode.
  """

  alias OptimalSystemAgent.Memory.{Scoring, Search}

  @default_lambda 0.7

  @doc """
  Re-rank scored candidates for diversity.

  `scored_entries` — a list of `{score, entry}` tuples (as produced by
  `Memory.Scoring.score/3` or a hybrid fusion score). `entry` must be a map
  with at least `:id`/`"id"` and `:keywords`/`"keywords"`.

  Options:
    - `:limit`      — max entries to return (default: length of input)
    - `:lambda`      — relevance/diversity trade-off in `0.0..1.0`
                       (default `0.7`; `1.0` = pure relevance ranking,
                       `0.0` = pure diversity)
    - `:embeddings`  — map of `entry_id => vector` used for cosine similarity;
                       entries missing from this map fall back to keyword
                       Jaccard overlap for diversity comparisons

  Returns the re-ranked list of entries (NOT `{score, entry}` tuples), best
  first, length `<= limit`.
  """
  @spec rerank([{number(), map()}], keyword()) :: [map()]
  def rerank(scored_entries, opts \\ [])

  def rerank([], _opts), do: []

  def rerank(scored_entries, opts) when is_list(scored_entries) do
    limit = Keyword.get(opts, :limit, length(scored_entries))
    lambda = Keyword.get(opts, :lambda, @default_lambda)
    embeddings = Keyword.get(opts, :embeddings, %{})

    candidates =
      Enum.map(scored_entries, fn {score, entry} ->
        %{score: score || 0.0, entry: entry, id: entry_id(entry)}
      end)

    do_select(candidates, [], max(limit, 0), lambda, embeddings)
  end

  # ---------------------------------------------------------------------------
  # Greedy selection loop
  # ---------------------------------------------------------------------------

  defp do_select(_remaining, selected, limit, _lambda, _embeddings)
       when length(selected) >= limit do
    finalize(selected)
  end

  defp do_select([], selected, _limit, _lambda, _embeddings), do: finalize(selected)

  defp do_select(remaining, selected, limit, lambda, embeddings) do
    best =
      remaining
      |> Enum.map(fn cand ->
        diversity_penalty = max_similarity(cand, selected, embeddings)
        mmr_score = lambda * cand.score - (1 - lambda) * diversity_penalty
        {cand, mmr_score}
      end)
      |> Enum.max_by(fn {_cand, mmr_score} -> mmr_score end)
      |> elem(0)

    remaining_rest = Enum.reject(remaining, &(&1.id == best.id))
    do_select(remaining_rest, [best | selected], limit, lambda, embeddings)
  end

  defp finalize(selected), do: selected |> Enum.reverse() |> Enum.map(& &1.entry)

  # ---------------------------------------------------------------------------
  # Similarity
  # ---------------------------------------------------------------------------

  defp max_similarity(_cand, [], _embeddings), do: 0.0

  defp max_similarity(cand, selected, embeddings) do
    selected
    |> Enum.map(&pairwise_similarity(cand, &1, embeddings))
    |> Enum.max(fn -> 0.0 end)
  end

  defp pairwise_similarity(a, b, embeddings) do
    vec_a = Map.get(embeddings, a.id)
    vec_b = Map.get(embeddings, b.id)

    if is_list(vec_a) and is_list(vec_b) do
      Search.cosine_similarity(vec_a, vec_b)
    else
      Scoring.keyword_overlap(entry_keywords(a.entry), entry_keywords(b.entry))
    end
  end

  defp entry_keywords(entry) do
    (entry[:keywords] || entry["keywords"] || "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp entry_id(entry), do: entry[:id] || entry["id"]
end
