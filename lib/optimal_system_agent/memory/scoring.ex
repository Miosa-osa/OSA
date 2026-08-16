defmodule OptimalSystemAgent.Memory.Scoring do
  @moduledoc """
  Relevance scoring for memory entries — pure functions, no state.

  Computes a composite relevance score for a memory entry given a set of
  query keywords and a session context. The final score is a weighted sum:

      score = (base * 0.30) + (context * 0.50) + (recency * 0.20)

  Where:
    - base    — category importance weight (0.5–1.0)
    - context — Jaccard similarity between memory keywords and query keywords
    - recency — exponential decay from accessed_at (half-life: 48 hours)
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Category base weights
  # ---------------------------------------------------------------------------

  @category_weights %{
    "decision" => 1.00,
    "preference" => 0.90,
    "pattern" => 0.85,
    "lesson" => 0.80,
    "project" => 0.75,
    "context" => 0.50
  }

  @default_category_weight 0.50

  # Exponential decay half-life in hours
  @recency_half_life_hours 48.0

  # Stop words excluded from keyword extraction (mirrors Memory.Store)
  @stop_words ~w(a an the and or but in on at to for of is are was were be been
                 being have has had do does did will would could should may might
                 this that these those i you he she it we they me him her us them
                 my your his its our their what which who when where how with from
                 by about into than then also just not no nor so yet both either
                 each other such while if as after before since until unless though
                 although because since while where whether can cannot am)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Compute composite relevance score for a memory entry.

  Returns a float in 0.0–1.0.

  - `memory_entry`    — map with at least `:keywords`, `:category`, `:accessed_at`
  - `query_keywords`  — list of keyword strings from the current user query
  - `_session_id`     — reserved for future session-scoped boosting (unused)
  """
  @spec score(map(), [String.t()], String.t() | nil) :: float()
  def score(memory_entry, query_keywords, _session_id \\ nil)

  def score(memory_entry, query_keywords, _session_id) when is_map(memory_entry) do
    base = base_score(memory_entry)
    context = context_score(memory_entry, query_keywords)
    recency = recency_score(memory_entry)

    base * 0.30 + context * 0.50 + recency * 0.20
  end

  def score(_memory_entry, _query_keywords, _session_id), do: 0.0

  @doc """
  Extract meaningful keywords from a text string.

  Tokenises, downcases, removes stop words, and deduplicates.
  Words shorter than 3 characters are also removed.

  Returns a list of lowercase keyword strings.
  """
  @spec extract_keywords(String.t() | nil) :: [String.t()]
  def extract_keywords(nil), do: []
  def extract_keywords(""), do: []

  def extract_keywords(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  def extract_keywords(_), do: []

  @doc """
  Compute Jaccard similarity between two keyword lists.

      similarity = |A ∩ B| / |A ∪ B|

  Returns 0.0 when either list is empty or the union is empty.
  """
  @spec keyword_overlap([String.t()], [String.t()]) :: float()
  def keyword_overlap([], _), do: 0.0
  def keyword_overlap(_, []), do: 0.0

  def keyword_overlap(keywords_a, keywords_b)
      when is_list(keywords_a) and is_list(keywords_b) do
    set_a = MapSet.new(keywords_a)
    set_b = MapSet.new(keywords_b)

    intersection_size = set_a |> MapSet.intersection(set_b) |> MapSet.size()
    union_size = set_a |> MapSet.union(set_b) |> MapSet.size()

    if union_size == 0, do: 0.0, else: intersection_size / union_size
  end

  def keyword_overlap(_, _), do: 0.0

  @doc """
  The RELEVANCE-ONLY component of `score/3` — Jaccard overlap between the
  entry's stored keywords and `query_keywords`, with no category weight and no
  recency mixed in.

  `score/3` deliberately blends three signals, and two of them say nothing
  about whether an entry has anything to do with the request: a `:decision`
  entry saved moments ago scores `1.0*0.30 + 0.0 + 1.0*0.20 = 0.50` against a
  query it shares not one word with. Callers that need to ask "is this related
  AT ALL" — rather than "how should related things be ranked" — must ask it
  separately, which is what this exists for. See `Memory.recall_hybrid/2`.

  Returns a float in 0.0–1.0; `0.0` means no lexical evidence whatsoever.
  """
  @spec context_relevance(map(), [String.t()]) :: float()
  def context_relevance(entry, query_keywords) when is_map(entry),
    do: context_score(entry, query_keywords)

  def context_relevance(_entry, _query_keywords), do: 0.0

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Category-weight component (30%)
  defp base_score(entry) do
    category = entry[:category] || entry["category"] || ""
    Map.get(@category_weights, to_string(category), @default_category_weight)
  end

  # Keyword overlap component (50%)
  defp context_score(entry, query_keywords) when is_list(query_keywords) do
    entry_kws = parse_stored_keywords(entry[:keywords] || entry["keywords"])
    keyword_overlap(entry_kws, query_keywords)
  end

  defp context_score(_entry, _query_keywords), do: 0.0

  # Recency component (20%) — exponential decay, half-life 48 hours
  defp recency_score(entry) do
    accessed_at = entry[:accessed_at] || entry["accessed_at"]
    compute_recency(accessed_at)
  end

  defp compute_recency(nil), do: 0.5

  defp compute_recency(accessed_at) when is_binary(accessed_at) do
    case DateTime.from_iso8601(accessed_at) do
      {:ok, dt, _} ->
        age_hours = DateTime.diff(DateTime.utc_now(), dt, :second) / 3600.0
        :math.exp(-0.693 * age_hours / @recency_half_life_hours)

      _ ->
        Logger.debug("[Memory.Scoring] unparseable accessed_at: #{inspect(accessed_at)}")
        0.5
    end
  end

  defp compute_recency(_), do: 0.5

  # Parse comma-separated keyword string stored in the entry
  defp parse_stored_keywords(nil), do: []
  defp parse_stored_keywords(""), do: []

  defp parse_stored_keywords(kws) when is_binary(kws) do
    kws
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_stored_keywords(_), do: []
end
