defmodule OptimalSystemAgent.Conversations.Strategies.Facilitator do
  @moduledoc """
  Facilitator-driven turn strategy.

  A designated facilitator agent reviews the transcript after every turn and
  decides who should speak next. The facilitator can also declare consensus,
  ending the conversation early.

  ## How it works

  1. After each participant turn the Server calls `next_speaker/1`.
  2. This module calls the facilitator LLM with the current transcript.
  3. The LLM response must be a JSON object:
       `{"next": "<participant_name>", "end": false}`
     or
       `{"next": null, "end": true, "reason": "..."}`
  4. If the JSON cannot be parsed, falls back to round-robin ordering.

  ## Strategy state

      %{
        facilitator: Persona.t(),
        fallback_index: non_neg_integer()
      }
  """

  @behaviour OptimalSystemAgent.Conversations.TurnStrategy

  require Logger

  alias OptimalSystemAgent.Conversations.Persona
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @impl true
  def next_speaker(%{participants: participants, strategy_state: ss} = state) do
    facilitator = Map.get(ss, :facilitator)

    case ask_facilitator(facilitator, state, :next_speaker) do
      {:ok, name} when is_binary(name) ->
        # Validate the name is actually a participant
        if Enum.any?(participants, &(&1.name == name)) do
          name
        else
          fallback_speaker(participants, ss)
        end

      _ ->
        fallback_speaker(participants, ss)
    end
  end

  @impl true
  def should_end?(%{strategy_state: ss, turn_count: turn_count, max_turns: max_turns} = state) do
    if turn_count >= max_turns do
      true
    else
      facilitator = Map.get(ss, :facilitator)

      case ask_facilitator(facilitator, state, :should_end) do
        {:ok, :end} -> true
        _ -> false
      end
    end
  end

  @doc "Build initial strategy state."
  @spec init(Persona.t() | map() | atom(), keyword()) :: map()
  def init(facilitator_spec, _opts \\ []) do
    %{
      facilitator: Persona.resolve(facilitator_spec),
      fallback_index: 0
    }
  end

  @doc """
  Advance fallback index after a turn.

  Returns updated strategy_state. Used when the LLM is unavailable.
  """
  @spec advance(map()) :: map()
  def advance(%{participants: participants, strategy_state: ss}) do
    idx = Map.get(ss, :fallback_index, 0)
    next_idx = rem(idx + 1, max(length(participants), 1))
    Map.put(ss, :fallback_index, next_idx)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp ask_facilitator(nil, _state, _intent), do: {:error, :no_facilitator}

  defp ask_facilitator(%Persona{} = facilitator, state, intent) do
    prompt = build_facilitator_prompt(facilitator, state, intent)
    messages = [%{role: "user", content: prompt}]
    system = Persona.system_prompt(facilitator, state.topic)

    opts = [
      system: system,
      temperature: 0.2,
      max_tokens: 200
    ]

    opts = if facilitator.model, do: Keyword.put(opts, :model, facilitator.model), else: opts

    case Providers.chat(messages, opts) do
      {:ok, %{content: raw}} ->
        parse_facilitator_response(raw, intent)

      {:ok, raw} when is_binary(raw) ->
        parse_facilitator_response(raw, intent)

      {:error, reason} ->
        Logger.warning("[Facilitator] LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Facilitator] ask_facilitator error: #{Exception.message(e)}")
      {:error, :exception}
  end

  defp build_facilitator_prompt(%Persona{name: fname}, state, intent) do
    participant_names = Enum.map_join(state.participants, ", ", & &1.name)
    turns = format_transcript(state.transcript)

    case intent do
      :next_speaker ->
        """
        You are facilitating a #{state.type} conversation about: #{state.topic}

        Participants: #{participant_names}
        (You are #{fname} — do not select yourself)

        Recent transcript:
        #{turns}

        Decide who should speak next. Respond ONLY with valid JSON:
        {"next": "<participant_name>", "end": false}

        If the conversation has reached a natural conclusion, respond:
        {"next": null, "end": true, "reason": "<one sentence>"}
        """

      :should_end ->
        """
        You are facilitating a #{state.type} conversation about: #{state.topic}

        Turn #{state.turn_count} of #{state.max_turns} maximum.

        Recent transcript:
        #{turns}

        Has this conversation reached a conclusion or consensus?
        Respond ONLY with valid JSON:
        {"end": false}
        or
        {"end": true, "reason": "<one sentence>"}
        """
    end
  end

  defp format_transcript(transcript) do
    transcript
    |> Enum.take(-6)
    |> Enum.map_join("\n", fn {agent, msg, _ts} ->
      short = if String.length(msg) > 300, do: String.slice(msg, 0, 300) <> "...", else: msg
      "#{agent}: #{short}"
    end)
  end

  defp parse_facilitator_response(raw, intent) do
    cleaned =
      raw
      |> String.trim()
      |> strip_code_fences()

    case Jason.decode(cleaned) do
      {:ok, %{"end" => true}} when intent == :should_end ->
        {:ok, :end}

      {:ok, %{"end" => false}} when intent == :should_end ->
        {:ok, :continue}

      {:ok, %{"next" => name}} when is_binary(name) and intent == :next_speaker ->
        {:ok, name}

      {:ok, %{"end" => true}} when intent == :next_speaker ->
        {:ok, :end}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp strip_code_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim()
  end

  defp fallback_speaker(participants, ss) do
    idx = Map.get(ss, :fallback_index, 0)
    participant = Enum.at(participants, rem(idx, max(length(participants), 1)))
    participant.name
  end
end
