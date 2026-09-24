defmodule OptimalSystemAgent.Signal.OutputContract do
  @moduledoc """
  Per-genre output contract for OSA's OWN answers — Signal Theory applied
  OUTBOUND, mirroring `OptimalSystemAgent.Agent.Loop.GenreRouter`'s existing
  INBOUND genre routing (which classifies what the USER's message needs).
  This classifies what the OUTGOING answer needs to look like and hands the
  model a tiny, genre-specific shape contract instead of one generic
  "be helpful" instruction.

  ## Genres (same fixed vocabulary as `Signal.MessageClassifier`)

    * `:direct`  — numbered actions, no preamble
    * `:inform`  — the answer first, short
    * `:decide`  — a recommendation plus tradeoffs
    * `:commit`  — the plan, stated once, briefly
    * `:express` — a brief, direct response to the sentiment

  ## Cost

  Classification is the existing FAST, deterministic, no-LLM-call path
  (`Signal.Classifier.classify_fast/2`, <1ms, ETS-cached) — this module adds
  no round-trip. Every contract string is one short sentence, so wiring this
  in as a per-turn directive (see
  `OptimalSystemAgent.Agent.Loop.MessageHandler`) never meaningfully changes
  token cost, and — because it is a per-turn DYNAMIC directive, not part of
  any `Soul` static-base template — it has zero effect on the static prompt
  size `StaticBaseSizeTest` pins.
  """

  alias OptimalSystemAgent.Signal.Classifier

  @type genre :: :direct | :inform | :commit | :decide | :express

  @contracts %{
    direct: "Lead with the action: numbered steps in the order to run them. No preamble.",
    inform:
      "Lead with the answer in the first sentence. Keep it short — skip the walkthrough unless asked.",
    decide:
      "State your recommendation first, then 2-4 short tradeoffs. Only ask a clarifying question if truly blocking.",
    commit:
      "State the plan in one or two sentences and stop — do not restate what was already agreed.",
    express: "Respond briefly and directly to the sentiment. Do not pad with process narration."
  }

  @doc "The compact directive text for a genre. Unknown genres fall back to `:direct`."
  @spec contract_for(genre() | atom()) :: String.t()
  def contract_for(genre) when is_map_key(@contracts, genre), do: Map.fetch!(@contracts, genre)
  def contract_for(_genre), do: Map.fetch!(@contracts, :direct)

  @doc """
  Classify a message's genre via the fast, deterministic (no-LLM) path.
  Falls back to `:direct` on any classification failure or non-binary input.
  """
  @spec genre_for(term()) :: genre()
  def genre_for(message) when is_binary(message) do
    case Classifier.classify_fast(message) do
      {:ok, %{genre: genre}} when is_map_key(@contracts, genre) -> genre
      _ -> :direct
    end
  rescue
    _ -> :direct
  end

  def genre_for(_message), do: :direct

  @doc """
  Build the tiny pre-directive text for a message's classified genre — ready
  to append as a `role: "system"` pre-directive for this turn only.
  """
  @spec directive_for(term()) :: String.t()
  def directive_for(message) do
    genre = genre_for(message)
    "[Output contract — #{genre}] #{contract_for(genre)}"
  end
end
