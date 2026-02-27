defmodule OptimalSystemAgent.Intelligence.CommCoach do
  @moduledoc """
  Observes outbound messages and scores communication quality.
  Compares drafts against profiles to suggest improvements.

  Scoring dimensions (each 0.0–1.0, averaged for final score):
  - Length appropriateness: matches expected length for signal mode / user profile
  - Formality alignment: matches the user's established formality level
  - Clarity: readable structure, no walls of text or excessively long sentences
  - Actionability: concrete next steps present when context demands action
  - Empathy alignment: acknowledges emotion in express-genre conversations

  Verdict thresholds:
  - >= 0.7  :good
  - >= 0.4  :needs_work
  - < 0.4   :poor

  Signal Theory — outbound message quality optimization.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Intelligence.CommProfiler

  defstruct [
    scores: [],
    total_scored: 0
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  @doc "Score an outbound message against the user's profile. Returns quality assessment."
  def score(message, user_id \\ nil) do
    GenServer.call(__MODULE__, {:score, message, user_id})
  end

  @doc "Get coaching statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:score, message, user_id}, _from, state) do
    profile = get_user_profile(user_id)

    scores = %{
      length:        score_length(message, profile),
      formality:     score_formality(message, profile),
      clarity:       score_clarity(message),
      actionability: score_actionability(message),
      empathy:       score_empathy(message)
    }

    avg = scores |> Map.values() |> Enum.sum() |> Kernel./(5)
    avg = Float.round(avg, 4)

    suggestions = generate_suggestions(scores, profile)

    verdict =
      cond do
        avg >= 0.7 -> :good
        avg >= 0.4 -> :needs_work
        true       -> :poor
      end

    result = %{
      score:       Float.round(avg, 2),
      suggestions: suggestions,
      verdict:     verdict,
      details:     scores
    }

    Logger.debug("[CommCoach] scored message length=#{String.length(message)} avg=#{avg} verdict=#{verdict}")

    new_state = %{state |
      total_scored: state.total_scored + 1,
      scores: [avg | Enum.take(state.scores, 99)]
    }

    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    avg_score =
      case state.scores do
        [] -> 0.0
        scores -> Float.round(Enum.sum(scores) / length(scores), 2)
      end

    result = %{
      total_scored: state.total_scored,
      avg_score:    avg_score,
      common_issues: common_issues(state.scores)
    }

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Profile lookup
  # ---------------------------------------------------------------------------

  defp get_user_profile(nil), do: nil
  defp get_user_profile(user_id) do
    case CommProfiler.get_profile(user_id) do
      {:ok, profile} -> profile
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring: Length Appropriateness
  # ---------------------------------------------------------------------------

  # Score is based on two signals:
  # 1. Signal mode hints embedded in the message (code block -> BUILD, numbered steps -> EXECUTE)
  # 2. The user's avg_length from their profile (if available)
  #
  # The two signals are blended. When no profile exists, only mode heuristics apply.

  @execute_max 200
  @analyze_min 500

  defp score_length(message, profile) do
    len = String.length(message)

    mode_score = infer_mode_length_score(message, len)

    case profile do
      %{avg_length: avg_len} when is_number(avg_len) and avg_len > 0 ->
        profile_score = length_similarity(len, avg_len)
        # Blend: 60% mode expectation, 40% profile similarity
        Float.round(mode_score * 0.6 + profile_score * 0.4, 4)

      _ ->
        mode_score
    end
  end

  # Infer expected length from message content signals (mode heuristics)
  defp infer_mode_length_score(message, len) do
    has_code_block? = String.contains?(message, "```")
    has_steps?      = Regex.match?(~r/^\d+\./m, message)
    has_analysis?   = Regex.match?(~r/\b(analysis|because|therefore|however|thus)\b/i, message)

    cond do
      # EXECUTE / BUILD mode — expect short, direct response
      has_steps? and len > @execute_max * 3 ->
        penalise_ratio(len, @execute_max)

      # ANALYZE mode — expect detailed response
      has_analysis? and len < @analyze_min ->
        penalise_ratio(@analyze_min, len)

      # Code responses — length is flexible, penalise only extreme brevity
      has_code_block? and len < 50 ->
        0.5

      # Neutral — score based on absolute length bands
      true ->
        cond do
          len < 10    -> 0.4
          len < 20    -> 0.6
          len < 2_000 -> 1.0
          len < 4_000 -> 0.8
          true        -> 0.5
        end
    end
  end

  # Returns a similarity score between actual length and expected length.
  # Score degrades if actual is more than 3x longer or 3x shorter than expected.
  defp length_similarity(actual, expected) when expected > 0 do
    ratio = actual / expected

    cond do
      ratio > 3.0 ->
        # Too long — penalise proportionally but floor at 0.2
        max(0.2, 1.0 - (ratio - 3.0) * 0.1)

      ratio < 1 / 3 ->
        # Too short
        max(0.2, ratio * 3.0)

      true ->
        1.0
    end
  end

  defp length_similarity(_actual, _expected), do: 1.0

  defp penalise_ratio(numerator, denominator) when denominator > 0 do
    ratio = numerator / denominator
    max(0.1, 1.0 - (ratio - 1.0) * 0.2)
  end

  defp penalise_ratio(_, _), do: 0.5

  # ---------------------------------------------------------------------------
  # Scoring: Formality Alignment
  # ---------------------------------------------------------------------------

  @formal_markers ~w(therefore regarding additionally consequently furthermore accordingly
                     henceforth aforementioned pursuant herewith kindly)
  @informal_markers ~w(yeah cool nah gonna lol haha wanna kinda sorta yo sup bruh
                       hey tbh tbf idk omg lmao wtf)

  defp score_formality(message, profile) do
    response_formality = estimate_response_formality(message)

    case profile do
      %{formality: user_formality} when is_float(user_formality) ->
        diff = abs(user_formality - response_formality)
        Float.round(1.0 - diff, 4)

      _ ->
        # No profile — neutral score; very extreme formality on either end penalised slightly
        mid_penalty = abs(response_formality - 0.5) * 0.2
        Float.round(1.0 - mid_penalty, 4)
    end
  end

  defp estimate_response_formality(message) do
    lower = String.downcase(message)
    words = max(1, length(String.split(lower, ~r/\W+/, trim: true)))

    formal_count   = Enum.count(@formal_markers, &String.contains?(lower, &1))
    informal_count = Enum.count(@informal_markers, &String.contains?(lower, &1))

    # Normalise by word count so short messages aren't overly penalised
    formal_density   = min(formal_count   / words * 10, 0.5)
    informal_density = min(informal_count / words * 10, 0.5)

    clamped = 0.5 + formal_density - informal_density
    max(0.0, min(1.0, clamped))
  end

  # ---------------------------------------------------------------------------
  # Scoring: Clarity
  # ---------------------------------------------------------------------------

  @jargon_words ~w(synergize leverage paradigm ecosystem holistic scalable
                   agile robust mission-critical best-of-breed bandwidth)

  defp score_clarity(message) do
    len = String.length(message)
    sentences = split_sentences(message)

    long_sentence_penalty =
      sentences
      |> Enum.count(fn s ->
        word_count = s |> String.split(~r/\s+/, trim: true) |> length()
        word_count > 40
      end)
      |> then(fn count -> count * 0.1 end)

    lower = String.downcase(message)
    words = max(1, length(String.split(lower, ~r/\W+/, trim: true)))
    jargon_count = Enum.count(@jargon_words, &String.contains?(lower, &1))
    jargon_penalty = min(jargon_count / words * 5, 0.3)

    # Wall of text — no paragraph break in a long message
    wall_penalty =
      if len > 500 and not String.contains?(message, "\n\n") do
        0.2
      else
        0.0
      end

    # Structured output bonus — bullets, headers (# prefix), or numbered list
    has_bullets?  = Regex.match?(~r/^\s*[-*]\s+/m, message)
    has_headers?  = Regex.match?(~r/^#+\s+\S/m, message)
    has_numbers?  = Regex.match?(~r/^\d+\.\s+/m, message)
    structure_bonus = if has_bullets? or has_headers? or has_numbers?, do: 0.1, else: 0.0

    score = 1.0 - long_sentence_penalty - jargon_penalty - wall_penalty + structure_bonus
    Float.round(max(0.0, min(1.0, score)), 4)
  end

  defp split_sentences(message) do
    # Simple sentence splitter — split on . ? ! followed by whitespace or end
    Regex.split(~r/(?<=[.?!])\s+/, message)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  # ---------------------------------------------------------------------------
  # Scoring: Actionability
  # ---------------------------------------------------------------------------

  @action_verbs ~w(run execute install configure update create delete open close
                   click navigate go start stop restart check verify test deploy
                   set enable disable add remove save export import)

  @vague_phrases [
    "you could maybe",
    "it might be possible",
    "you might want to",
    "it could be that",
    "perhaps you should",
    "you may want to",
    "it is possible that"
  ]

  defp score_actionability(message) do
    lower = String.downcase(message)

    has_action_verb? = Enum.any?(@action_verbs, fn verb ->
      Regex.match?(~r/\b#{Regex.escape(verb)}\b/, lower)
    end)

    has_numbered_steps? = Regex.match?(~r/^\d+\./m, message)
    has_code_block?     = String.contains?(message, "```")

    vague_count =
      Enum.count(@vague_phrases, fn phrase -> String.contains?(lower, phrase) end)

    base =
      cond do
        has_numbered_steps? -> 0.9
        has_code_block?     -> 0.85
        has_action_verb?    -> 0.75
        true                -> 0.5
      end

    vague_penalty = vague_count * 0.15

    Float.round(max(0.0, min(1.0, base - vague_penalty)), 4)
  end

  # ---------------------------------------------------------------------------
  # Scoring: Empathy Alignment
  # ---------------------------------------------------------------------------

  @empathy_phrases [
    "i understand",
    "that makes sense",
    "good point",
    "i can see",
    "i appreciate",
    "that's valid",
    "i hear you",
    "fair enough",
    "you're right"
  ]

  @empathy_marker_words ~w(understand appreciate acknowledge)

  @dismissive_words ~w(just simply obviously clearly merely trivially)

  defp score_empathy(message) do
    lower = String.downcase(message)

    empathy_phrase_count =
      Enum.count(@empathy_phrases, fn phrase -> String.contains?(lower, phrase) end)

    empathy_word_count =
      Enum.count(@empathy_marker_words, fn word ->
        Regex.match?(~r/\b#{Regex.escape(word)}\b/, lower)
      end)

    dismissive_count =
      Enum.count(@dismissive_words, fn word ->
        Regex.match?(~r/\b#{Regex.escape(word)}\b/, lower)
      end)

    base =
      cond do
        empathy_phrase_count > 0 -> 0.9
        empathy_word_count > 1   -> 0.75
        empathy_word_count == 1  -> 0.65
        true                     -> 0.6
      end

    dismissive_penalty = dismissive_count * 0.1

    Float.round(max(0.0, min(1.0, base - dismissive_penalty)), 4)
  end

  # ---------------------------------------------------------------------------
  # Suggestion Generation
  # ---------------------------------------------------------------------------

  # Threshold below which a dimension triggers a suggestion
  @suggestion_threshold 0.6

  defp generate_suggestions(scores, profile) do
    []
    |> maybe_add_length_suggestion(scores.length, profile)
    |> maybe_add_formality_suggestion(scores.formality, profile)
    |> maybe_add_clarity_suggestion(scores.clarity)
    |> maybe_add_actionability_suggestion(scores.actionability)
    |> maybe_add_empathy_suggestion(scores.empathy)
  end

  defp maybe_add_length_suggestion(suggestions, score, profile) do
    if score < @suggestion_threshold do
      hint =
        case profile do
          %{avg_length: avg} when is_number(avg) and avg > 0 ->
            "Consider adjusting your response length — the user typically sends messages around #{round(avg)} characters"
          _ ->
            "Consider shortening your response for clarity"
        end
      [hint | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_formality_suggestion(suggestions, score, profile) do
    if score < @suggestion_threshold do
      hint =
        case profile do
          %{formality: f} when is_float(f) and f < 0.4 ->
            "Your response is more formal than the user's style — consider a more casual tone"
          %{formality: f} when is_float(f) and f > 0.7 ->
            "Your response is more casual than the user's style — consider a more formal tone"
          _ ->
            "Consider adjusting the tone to better match the user's communication style"
        end
      [hint | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_clarity_suggestion(suggestions, score) do
    if score < @suggestion_threshold do
      ["Break up long paragraphs and use bullet points for readability" | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_actionability_suggestion(suggestions, score) do
    if score < @suggestion_threshold do
      ["Add specific next steps or concrete recommendations" | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_empathy_suggestion(suggestions, score) do
    if score < @suggestion_threshold do
      ["Acknowledge the user's perspective before providing information" | suggestions]
    else
      suggestions
    end
  end

  # ---------------------------------------------------------------------------
  # Analytics helpers
  # ---------------------------------------------------------------------------

  # Returns a summary of scoring issues based on aggregate score history.
  defp common_issues([]), do: []
  defp common_issues(scores) do
    poor_count       = Enum.count(scores, &(&1 < 0.4))
    needs_work_count = Enum.count(scores, &(&1 >= 0.4 and &1 < 0.7))

    []
    |> then(fn acc ->
      if poor_count > 0 do
        ["#{poor_count} message(s) scored :poor overall" | acc]
      else
        acc
      end
    end)
    |> then(fn acc ->
      if needs_work_count > 0 do
        ["#{needs_work_count} message(s) scored :needs_work overall" | acc]
      else
        acc
      end
    end)
  end
end
