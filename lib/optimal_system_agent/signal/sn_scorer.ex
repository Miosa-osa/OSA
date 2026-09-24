defmodule OptimalSystemAgent.Signal.SnScorer do
  @moduledoc """
  Cheap heuristic signal-to-noise scoring for OSA's OWN final answers —
  Signal Theory's noise-elimination checklist (filler, hedging, restated
  questions, repetition, length-versus-content) applied to the model's
  OUTPUT before it reaches the user, not just to the user's input.

  Every check here is a regex/word-overlap heuristic over the finished text.
  **No LLM calls, no network calls, nothing that can add latency on the hot
  path** — this is meant to sit inline right before display, alongside the
  other output guardrails in `OptimalSystemAgent.Agent.Loop.Guardrails`
  (`strip_dead_phrases/1`, `response_contains_prompt_leak?/1`).

  ## Noise categories scored

    * `:filler`             — stock phrases that carry no information
      ("let me think about this", "i hope this helps", ...)
    * `:hedging`             — unnecessary qualifiers ("perhaps we could",
      "it might be worth", ...)
    * `:restated_question`   — the answer's opening sentence mostly echoes
      the question back (pass the original question via `opts[:question]`)
    * `:repetition`          — an immediately repeated sentence
    * `:low_density`         — long output with very little lexical variety
      (length without content)

  ## Score

  `score/2` returns a float in `[0.0, 1.0]`; `1.0` is clean, `0.0` is empty
  input. Each category is an independent, capped penalty subtracted from
  `1.0` — this is a cheap heuristic sum, not a calibrated probability.

  ## Trim vs. flag

  `trim/1` only ever removes sentences that are ENTIRELY filler (safe: a
  pure-filler sentence carries zero information by construction) and
  collapses an immediately-repeated sentence to one occurrence. It never
  strips hedging or a restated question — rewriting those risks mangling
  real content, so `enforce/2` reports them via `reasons` instead so the
  caller can log/flag without silently rewriting the model's answer.

  Both of those removal paths are additionally gated by
  `protected_sentence?/1`: a sentence is NEVER removed or collapsed — no
  matter how it matches the filler list or how many times it repeats — if it
  contains a backtick, a `/`, a digit, or a common shell/VCS command word
  (`run`, `git`, `mix`, `curl`, ...). This is intentionally broad and
  over-protective (a false "protected" costs nothing; a false "safe to
  remove" could delete a path, a number, or a command) — see
  `SnScorerSafetyTest` for the exhaustive proof. A pure filler phrase never
  contains any of those by construction, so this changes nothing about
  normal filler removal; it only refuses to touch a sentence that could
  plausibly be load-bearing.

  `enforce/2` is the one call site meant for production use: it trims, then
  scores the TRIMMED text (what will actually be displayed), and returns
  both.
  """

  @filler_phrases [
    "let me think about this",
    "that's a great question",
    "i hope this helps",
    "thank you for your patience",
    "i understand your concern",
    "to summarize what you said",
    "sure, let's dive in",
    "without further ado",
    "i'd be happy to help",
    "is there anything else",
    "as an ai"
  ]

  @hedge_patterns [
    ~r/\bperhaps we could\b/i,
    ~r/\bit might be worth\b/i,
    ~r/\bmight possibly\b/i,
    ~r/\bpossibly\b/i,
    ~r/\bi think(?: that)? maybe\b/i,
    ~r/\bit seems like it (?:might|could)\b/i,
    ~r/\bnot (?:entirely |100% )?sure but\b/i
  ]

  @stopwords ~w(a an the is are was were to of in on at for and or but this that it its be do does did)

  # Broad on purpose — see the moduledoc's "Trim vs. flag" section. A false
  # positive here just means one more sentence trim leaves alone; a false
  # negative would mean deleting a path, a number, or a command.
  @command_words ~r/\b(run|execute|mix|git|npm|yarn|pip|cd|ls|rm|cp|mv|curl|wget|cat|grep|sed|awk|python|elixir|iex|docker|kubectl|npx|make|sudo|chmod|chown|export|source)\b/i

  @type reason :: :filler | :hedging | :restated_question | :repetition | :low_density

  @filler_penalty 0.15
  @filler_penalty_cap 0.45
  @hedge_penalty 0.10
  @hedge_penalty_cap 0.40
  @restated_penalty 0.25
  @repetition_penalty 0.15
  @repetition_penalty_cap 0.45
  @density_penalty 0.15
  @restated_overlap_threshold 0.6
  @density_min_words 6
  @density_ratio_threshold 0.5

  @doc """
  Score `text` in `[0.0, 1.0]`. `1.0` is clean; empty/nil/non-binary input
  scores `0.0`.

  Options:
    * `:question` — the user's original message, to penalise an answer that
      opens by echoing it back instead of answering.
  """
  @spec score(term(), keyword()) :: float()
  def score(text, opts \\ [])
  def score(nil, _opts), do: 0.0
  def score("", _opts), do: 0.0

  def score(text, opts) when is_binary(text) do
    question = Keyword.get(opts, :question)

    filler_p = min(filler_count(text) * @filler_penalty, @filler_penalty_cap)
    hedge_p = min(hedge_count(text) * @hedge_penalty, @hedge_penalty_cap)
    restated_p = if restates_question?(text, question), do: @restated_penalty, else: 0.0
    repetition_p = min(repetition_count(text) * @repetition_penalty, @repetition_penalty_cap)
    density_p = if low_density?(text), do: @density_penalty, else: 0.0

    total = filler_p + hedge_p + restated_p + repetition_p + density_p

    (1.0 - total)
    |> max(0.0)
    |> min(1.0)
    |> Float.round(4)
  end

  def score(_other, _opts), do: 0.0

  @doc "The list of noise reasons detected in `text`. See `score/2` for options."
  @spec reasons(term(), keyword()) :: [reason()]
  def reasons(text, opts \\ [])
  def reasons(text, _opts) when text in [nil, ""], do: []

  def reasons(text, opts) when is_binary(text) do
    question = Keyword.get(opts, :question)

    []
    |> maybe_add(:filler, filler_count(text) > 0)
    |> maybe_add(:hedging, hedge_count(text) > 0)
    |> maybe_add(:restated_question, restates_question?(text, question))
    |> maybe_add(:repetition, has_repetition?(text))
    |> maybe_add(:low_density, low_density?(text))
  end

  def reasons(_other, _opts), do: []

  @doc """
  Remove sentences that are entirely a known filler phrase, and collapse an
  immediately-repeated sentence to one occurrence. Never returns an empty
  string for non-empty input — if removing filler would leave nothing, the
  original text is returned unchanged instead (better a filler-padded answer
  than a blank one).
  """
  @spec trim(term()) :: term()
  def trim(text) when is_binary(text) do
    sentences = split_sentences(text)

    candidate =
      sentences
      |> Enum.reject(&filler_sentence?/1)
      |> dedupe_consecutive()
      |> Enum.join(" ")
      |> String.trim()

    if candidate == "", do: String.trim(text), else: candidate
  end

  def trim(other), do: other

  @doc """
  Trim, then score the TRIMMED text (what will actually be displayed).
  Returns `{trimmed_text, meta}` where `meta` is
  `%{score: float(), reasons: [reason()], trimmed?: boolean()}`.

  Never raises: non-binary input passes through unchanged with a `0.0`
  score and an empty reason list.
  """
  @spec enforce(term(), keyword()) :: {term(), map()}
  def enforce(text, opts \\ []) do
    trimmed_text = trim(text)

    meta = %{
      score: score(trimmed_text, opts),
      reasons: reasons(trimmed_text, opts),
      trimmed?: trimmed_text != text
    }

    {trimmed_text, meta}
  end

  # ---------------------------------------------------------------------------
  # Filler
  # ---------------------------------------------------------------------------

  defp filler_count(text) do
    downcased = String.downcase(text)
    Enum.count(@filler_phrases, &String.contains?(downcased, &1))
  end

  defp filler_sentence?(sentence) do
    not protected_sentence?(sentence) and
      Enum.any?(@filler_phrases, &(&1 == normalize_sentence(sentence)))
  end

  # ---------------------------------------------------------------------------
  # Safety guard — sentences `trim/1` may never remove or collapse
  # ---------------------------------------------------------------------------

  @doc false
  @spec protected_sentence?(String.t()) :: boolean()
  def protected_sentence?(sentence) do
    String.contains?(sentence, "`") or
      String.contains?(sentence, "/") or
      Regex.match?(~r/\d/, sentence) or
      Regex.match?(@command_words, sentence)
  end

  # ---------------------------------------------------------------------------
  # Hedging
  # ---------------------------------------------------------------------------

  defp hedge_count(text) do
    Enum.count(@hedge_patterns, &Regex.match?(&1, text))
  end

  # ---------------------------------------------------------------------------
  # Restated question
  # ---------------------------------------------------------------------------

  defp restates_question?(_text, question) when question in [nil, ""], do: false

  defp restates_question?(text, question) when is_binary(question) do
    case split_sentences(text) do
      [first | _] ->
        question_words = normalize_words(question)

        if MapSet.size(question_words) == 0 do
          false
        else
          first_words = normalize_words(first)
          overlap = MapSet.intersection(first_words, question_words) |> MapSet.size()
          overlap / MapSet.size(question_words) >= @restated_overlap_threshold
        end

      [] ->
        false
    end
  end

  defp restates_question?(_text, _question), do: false

  # ---------------------------------------------------------------------------
  # Repetition
  # ---------------------------------------------------------------------------

  defp repetition_count(text) do
    text
    |> split_sentences()
    |> Enum.map(&normalize_sentence/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != "" and a == b end)
  end

  defp has_repetition?(text), do: repetition_count(text) > 0

  # ---------------------------------------------------------------------------
  # Density (length versus content)
  # ---------------------------------------------------------------------------

  defp low_density?(text) do
    words = plain_words(text)
    total = length(words)

    total >= @density_min_words and length(Enum.uniq(words)) / total < @density_ratio_threshold
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  # Collapses an immediately-repeated sentence to one occurrence — UNLESS it
  # is `protected_sentence?/1` (contains a backtick, a `/`, a digit, or a
  # command word), in which case both copies are kept. `repetition_count/1`
  # above (used only for `score/2`/`reasons/2`) is NOT similarly guarded —
  # flagging a repeated command as noisy is fine; deleting one copy of it is
  # not.
  defp dedupe_consecutive(sentences) do
    sentences
    |> Enum.reduce([], fn sentence, acc ->
      case acc do
        [last | _] ->
          if not protected_sentence?(sentence) and
               normalize_sentence(last) == normalize_sentence(sentence) do
            acc
          else
            [sentence | acc]
          end

        [] ->
          [sentence]
      end
    end)
    |> Enum.reverse()
  end

  defp split_sentences(text) do
    text
    |> String.trim()
    |> then(&Regex.split(~r/(?<=[.!?])\s+/, &1, trim: true))
  end

  defp normalize_sentence(sentence) do
    sentence
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim_trailing("!")
    |> String.trim_trailing("?")
    |> String.downcase()
    |> String.trim()
  end

  defp plain_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
  end

  defp normalize_words(text) do
    text
    |> plain_words()
    |> Enum.reject(&(&1 in @stopwords))
    |> MapSet.new()
  end

  defp maybe_add(list, reason, true), do: [reason | list]
  defp maybe_add(list, _reason, false), do: list
end
