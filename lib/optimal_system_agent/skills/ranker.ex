defmodule OptimalSystemAgent.Skills.Ranker do
  @moduledoc """
  Relevance ranking for the learned skill library - the RANK stage of the
  Skills subsystem (see `OptimalSystemAgent.Skills`).

  A stored skill map (from `OptimalSystemAgent.Store.SkillLibrary`) is scored
  against the CURRENT task/query, then boosted by recency and accumulated
  usage, so the small set surfaced to the model is the most useful set - not
  merely the most-recently-written or the nearest on disk.

  Score model:

      combined = relevance * (1 + w_recency * recency_norm
                                + w_usage   * usage_norm)

  Relevance is the GATE: a skill that does not match the query at all scores
  `0.0` for relevance, so `combined` is `0.0` and it never surfaces regardless
  of how recent or how heavily used it is. Recency and usage only reorder among
  skills that are already relevant. This is the deliberate difference from the
  reference harnesses (Claude Code, grok, opencode) which list ALL author-curated
  SKILL.md files within a token budget with no query ranking: OSA's learned
  library grows unbounded at runtime, so it MUST rank by relevance to the task.

  Relevance is fuzzy, not raw substring: each query token matches on exact word,
  word-prefix, or substring, taking the best-weighted field it hits. Fields are
  weighted title > tags > when_to_use > description > body.
  """

  # Field weights: where a match lands matters more than how many times it lands.
  @w_title 3.0
  @w_tags 2.5
  @w_when 2.0
  @w_desc 1.5
  @w_body 0.5

  # A whole-query phrase hit is a strong signal but is added at reduced weight
  # so it complements (rather than doubles) the per-token score.
  @phrase_weight 0.5

  # Boost weights. Kept small so relevance always dominates ordering.
  @w_recency 0.25
  @w_usage 0.35

  # Recency half-life in days: a skill updated `@recency_half_life_days` ago
  # contributes half the recency boost of one updated just now.
  @recency_half_life_days 30.0

  # Usage saturation: `@usage_saturation` uses reaches ~full usage boost; more
  # than that adds almost nothing (log curve), so a runaway counter can't swamp
  # relevance.
  @usage_saturation 20.0

  @min_token_len 2
  @prefix_min_len 3

  @doc """
  Rank `skills` against `query`, returning the most relevant first.

  Options:
    * `:limit`         - max results (default 5)
    * `:min_relevance` - drop skills scoring at/below this relevance (default 0.0)
    * `:now`           - reference `DateTime` for recency (default `DateTime.utc_now/0`)
  """
  @spec rank([map()], String.t(), keyword()) :: [map()]
  def rank(skills, query, opts \\ [])

  def rank(skills, query, opts) when is_list(skills) and is_binary(query) do
    limit = Keyword.get(opts, :limit, 5)
    min_rel = Keyword.get(opts, :min_relevance, 0.0)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    q = normalize(query)
    tokens = tokenize(q)

    skills
    |> Enum.map(fn skill ->
      rel = relevance_skill(skill, q, tokens)
      {skill, rel, combined(skill, rel, now)}
    end)
    |> Enum.filter(fn {_skill, rel, _combined} -> rel > min_rel end)
    |> Enum.sort_by(fn {_skill, _rel, combined} -> combined end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {skill, _rel, _combined} -> skill end)
  end

  def rank(_skills, _query, _opts), do: []

  @doc """
  Score a raw text blob against `query`. Used to relevance-order lightweight
  candidates (e.g. discovered `SKILL.md` descriptions in the reminder pipeline)
  that are not full skill-library maps. Returns `0.0` when either side is blank.
  """
  @spec relevance(String.t(), String.t()) :: float()
  def relevance(text, query) when is_binary(text) and is_binary(query) do
    q = normalize(query)
    tokens = tokenize(q)

    if q == "" or tokens == [] do
      0.0
    else
      haystacks = [{normalize(text), @w_title}]
      phrase_score(haystacks, q) + token_score(haystacks, tokens)
    end
  end

  def relevance(_text, _query), do: 0.0

  # ── Relevance ────────────────────────────────────────────────────────────

  defp relevance_skill(_skill, "", _tokens), do: 0.0

  defp relevance_skill(skill, q, tokens) do
    haystacks = [
      {normalize(skill["title"]), @w_title},
      {normalize(tags_text(skill["tags"])), @w_tags},
      {normalize(skill["when_to_use"]), @w_when},
      {normalize(skill["description"]), @w_desc},
      {normalize(skill["body"]), @w_body}
    ]

    phrase_score(haystacks, q) + token_score(haystacks, tokens)
  end

  # Whole-query substring bonus, summed across fields at reduced weight.
  defp phrase_score(haystacks, q) do
    Enum.reduce(haystacks, 0.0, fn {text, weight}, acc ->
      if q != "" and String.contains?(text, q), do: acc + weight * @phrase_weight, else: acc
    end)
  end

  # Per query-token: add the best-weighted field the token matches (fuzzy:
  # exact word, word-prefix, or substring).
  defp token_score(haystacks, tokens) do
    Enum.reduce(tokens, 0.0, fn tok, acc ->
      best =
        Enum.reduce(haystacks, 0.0, fn {text, weight}, inner ->
          if field_matches?(text, tok), do: max(inner, weight), else: inner
        end)

      acc + best
    end)
  end

  defp field_matches?("", _tok), do: false

  # Short tokens (< @prefix_min_len) match only as a whole word: substring
  # matching on 2-char tokens is noise ("it" inside "iterate", "is" inside
  # "list"). Longer tokens may match by substring or word-prefix (fuzzy).
  defp field_matches?(text, tok) when byte_size(tok) < @prefix_min_len do
    word_match?(text, tok)
  end

  defp field_matches?(text, tok) do
    String.contains?(text, tok) or prefix_word_match?(text, tok)
  end

  defp word_match?(text, tok) do
    text |> String.split(~r/\s+/, trim: true) |> Enum.member?(tok)
  end

  # True if any word in `text` starts with `tok` (fuzzy prefix), for tokens long
  # enough that a prefix is meaningful. Substring already covers the rest.
  defp prefix_word_match?(text, tok) when byte_size(tok) >= @prefix_min_len do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.any?(&String.starts_with?(&1, tok))
  end

  defp prefix_word_match?(_text, _tok), do: false

  # ── Boosts ───────────────────────────────────────────────────────────────

  defp combined(skill, relevance, now) do
    relevance * (1.0 + @w_recency * recency_norm(skill, now) + @w_usage * usage_norm(skill))
  end

  # Exponential decay on the newest of updated_at / created_at.
  defp recency_norm(skill, now) do
    ts = skill["updated_at"] || skill["created_at"]

    case parse_dt(ts) do
      nil ->
        0.0

      dt ->
        days = max(DateTime.diff(now, dt, :second), 0) / 86_400.0
        :math.pow(0.5, days / @recency_half_life_days)
    end
  end

  defp usage_norm(skill) do
    uses = skill["uses"]
    uses = if is_integer(uses) and uses > 0, do: uses, else: 0
    :math.log(1 + uses) / :math.log(1 + @usage_saturation)
  end

  defp parse_dt(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _off} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  # ── Text helpers ─────────────────────────────────────────────────────────

  defp normalize(nil), do: ""
  defp normalize(v), do: v |> to_string() |> String.downcase() |> String.trim()

  defp tokenize(text) do
    text
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < @min_token_len))
    |> Enum.uniq()
  end

  defp tags_text(tags), do: tags |> List.wrap() |> Enum.join(" ")
end
