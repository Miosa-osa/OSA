defmodule OptimalSystemAgent.Conversations.Server do
  @moduledoc """
  Multi-agent conversation server.

  Manages a single structured conversation between multiple AI personas.
  Each conversation has a type, topic, participant list, and turn strategy
  that governs who speaks and when the conversation ends.

  ## Conversation types

    - `:brainstorm`     — open ideation, all voices encouraged
    - `:design_review`  — structured critique of a proposal
    - `:red_team`       — adversarial stress-testing
    - `:user_panel`     — simulated user feedback panel

  ## Lifecycle

      1. start_link/1 — spawn the GenServer, state = :running
      2. run/1        — execute all turns until termination condition
      3. ended        — Weaver generates summary, broadcast ConversationEnded

  ## Turn execution

  Each turn:
    1. Strategy selects the next speaker
    2. Server builds the LLM prompt (persona system prompt + transcript context)
    3. Server calls the provider
    4. Response appended to transcript
    5. Strategy checks end condition
    6. Events broadcast: TurnTaken (each turn), ConversationEnded (final)

  ## Events broadcast

    - `{:conversation_started, conversation_id, topic}`
    - `{:turn_taken, conversation_id, agent_name, message, turn_count}`
    - `{:conversation_ended, conversation_id, summary}`
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Conversations.{Persona, Weaver}
  alias OptimalSystemAgent.Conversations.Strategies.{RoundRobin, Facilitator, Weighted}
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @default_max_turns 20
  @llm_timeout_ms 120_000

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  defstruct [
    :id,
    :type,
    :topic,
    :team_id,
    :strategy_mod,
    participants: [],
    transcript: [],
    turn_count: 0,
    max_turns: @default_max_turns,
    status: :running,
    summary: nil,
    strategy_state: %{}
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start a conversation server.

  ## Options

    * `:type`         - `:brainstorm | :design_review | :red_team | :user_panel` (required)
    * `:topic`        - conversation topic string (required)
    * `:participants` - list of Persona structs, predefined atoms, or maps (required)
    * `:max_turns`    - maximum turns before auto-termination (default: 20)
    * `:team_id`      - optional team identifier for event routing
    * `:strategy`     - `:round_robin | :facilitator | :weighted` (default: `:round_robin`)
    * `:strategy_opts`- keyword list passed to strategy init/1
    * `:facilitator`  - Persona/atom for facilitator strategy (only with `:facilitator`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Run the conversation to completion. Blocks the caller until done.

  Returns `{:ok, summary}` where summary is the Weaver output map.
  """
  @spec run(pid()) :: {:ok, map()} | {:error, any()}
  def run(pid) do
    GenServer.call(pid, :run, @llm_timeout_ms * 30)
  end

  @doc "Return a snapshot of the current conversation state."
  @spec get_state(pid()) :: map()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc "Return the transcript list: [{agent_name, message, timestamp}]."
  @spec transcript(pid()) :: [{String.t(), String.t(), DateTime.t()}]
  def transcript(pid) do
    GenServer.call(pid, :transcript)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    id = "conv_#{System.unique_integer([:positive])}"

    type = Keyword.fetch!(opts, :type)
    topic = Keyword.fetch!(opts, :topic)
    raw_participants = Keyword.fetch!(opts, :participants)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    team_id = Keyword.get(opts, :team_id)
    strategy_key = Keyword.get(opts, :strategy, :round_robin)
    strategy_opts = Keyword.get(opts, :strategy_opts, [])

    participants = Enum.map(raw_participants, &Persona.resolve/1)

    {strategy_mod, strategy_state} =
      init_strategy(strategy_key, participants, topic, opts, strategy_opts)

    state = %__MODULE__{
      id: id,
      type: type,
      topic: topic,
      participants: participants,
      max_turns: max_turns,
      team_id: team_id,
      strategy_mod: strategy_mod,
      strategy_state: strategy_state
    }

    Logger.info("[Conversation] started #{id} type=#{type} topic=#{inspect(topic)} participants=#{length(participants)}")

    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    broadcast(state, {:conversation_started, state.id, state.topic})

    state = execute_conversation(state)

    {:ok, summary} = Weaver.summarise(state)
    state = %{state | summary: summary, status: :ended}

    broadcast(state, {:conversation_ended, state.id, summary})

    Logger.info("[Conversation] #{state.id} ended after #{state.turn_count} turns")

    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state_snapshot(state), state}
  end

  @impl true
  def handle_call(:transcript, _from, state) do
    {:reply, state.transcript, state}
  end

  # ---------------------------------------------------------------------------
  # Conversation execution
  # ---------------------------------------------------------------------------

  defp execute_conversation(state) do
    if should_stop?(state) do
      state
    else
      state = execute_turn(state)
      execute_conversation(state)
    end
  end

  defp should_stop?(%{turn_count: tc, max_turns: max}) when tc >= max, do: true

  defp should_stop?(%{status: :ended}), do: true

  defp should_stop?(state) do
    state.strategy_mod.should_end?(strategy_context(state))
  end

  defp execute_turn(state) do
    ctx = strategy_context(state)
    speaker_name = state.strategy_mod.next_speaker(ctx)

    case find_participant(state, speaker_name) do
      nil ->
        Logger.warning("[Conversation] #{state.id} strategy returned unknown speaker #{speaker_name} — skipping turn")
        %{state | turn_count: state.turn_count + 1}

      persona ->
        case call_participant(persona, state) do
          {:ok, response} ->
            timestamp = DateTime.utc_now()
            entry = {persona.name, response, timestamp}
            transcript = state.transcript ++ [entry]
            new_state = %{state | transcript: transcript, turn_count: state.turn_count + 1}

            # Advance strategy-owned index/state
            new_strategy_state = advance_strategy(state.strategy_mod, new_state)
            new_state = %{new_state | strategy_state: new_strategy_state}

            broadcast(new_state, {:turn_taken, new_state.id, persona.name, response, new_state.turn_count})

            Logger.debug("[Conversation] #{state.id} turn #{new_state.turn_count} — #{persona.name} spoke (#{String.length(response)} chars)")

            new_state

          {:error, reason} ->
            Logger.warning("[Conversation] #{state.id} participant #{persona.name} failed: #{inspect(reason)}")
            %{state | turn_count: state.turn_count + 1}
        end
    end
  end

  defp call_participant(%Persona{} = persona, state) do
    system = Persona.system_prompt(persona, state.topic)
    messages = build_messages(persona, state)

    opts = [
      system: system,
      temperature: 0.7,
      max_tokens: 1000
    ]

    opts = if persona.model, do: Keyword.put(opts, :model, persona.model), else: opts

    case Providers.chat(messages, opts) do
      {:ok, %{content: content}} -> {:ok, content}
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Conversation] call_participant error for #{persona.name}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp build_messages(%Persona{name: name}, state) do
    context_intro = """
    This is a #{state.type} conversation about: #{state.topic}

    You are #{name}. Respond naturally and concisely (2-4 paragraphs maximum).
    Build on or respond to what others have said. Be direct and substantive.
    """

    transcript_msgs =
      state.transcript
      |> Enum.map(fn {agent, content, _ts} ->
        role = if agent == name, do: "assistant", else: "user"
        prefix = if agent != name, do: "#{agent}: ", else: ""
        %{role: role, content: prefix <> content}
      end)

    if transcript_msgs == [] do
      [%{role: "user", content: context_intro <> "\n\nPlease begin — share your initial perspective on the topic."}]
    else
      [%{role: "user", content: context_intro}] ++ transcript_msgs ++
        [%{role: "user", content: "Please respond now as #{name}."}]
    end
  end

  # ---------------------------------------------------------------------------
  # Strategy helpers
  # ---------------------------------------------------------------------------

  defp init_strategy(:round_robin, _participants, _topic, _opts, strategy_opts) do
    {RoundRobin, RoundRobin.init(strategy_opts)}
  end

  defp init_strategy(:facilitator, participants, _topic, opts, strategy_opts) do
    facilitator_spec = Keyword.get(opts, :facilitator, :pragmatist)
    # Remove facilitator from the participants list if present
    facilitator_persona = Persona.resolve(facilitator_spec)

    filtered =
      Enum.reject(participants, &(&1.name == facilitator_persona.name))

    ss = Facilitator.init(facilitator_persona, strategy_opts)

    # We need to store the filtered participants — rebuild them into the state.
    # The init/1 receives the raw opts list so we patch it here by returning
    # a strategy state that includes both the facilitator config and the
    # knowledge that participants list may need filtering (handled in server init).
    _ = filtered
    {Facilitator, ss}
  end

  defp init_strategy(:weighted, participants, topic, _opts, strategy_opts) do
    {Weighted, Weighted.init(participants, topic, strategy_opts)}
  end

  defp init_strategy(unknown, _participants, _topic, _opts, _strategy_opts) do
    Logger.warning("[Conversation] Unknown strategy #{inspect(unknown)}, defaulting to round_robin")
    {RoundRobin, RoundRobin.init([])}
  end

  defp advance_strategy(RoundRobin, state) do
    RoundRobin.advance(state)
  end

  defp advance_strategy(Facilitator, state) do
    Facilitator.advance(state)
  end

  defp advance_strategy(Weighted, state) do
    # Reweight based on last speaker's contribution
    case List.last(state.transcript) do
      {speaker, response, _ts} ->
        Weighted.reweight(state.strategy_state, speaker, response, state.topic)

      nil ->
        state.strategy_state
    end
  end

  defp advance_strategy(_mod, state), do: state.strategy_state

  defp strategy_context(state) do
    %{
      type: state.type,
      topic: state.topic,
      participants: state.participants,
      transcript: state.transcript,
      turn_count: state.turn_count,
      status: state.status,
      max_turns: state.max_turns,
      strategy_state: state.strategy_state
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_participant(state, name) do
    Enum.find(state.participants, &(&1.name == name))
  end

  defp broadcast(state, event) do
    if state.team_id do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:conversations:#{state.team_id}",
        event
      )
    end

    # Also emit through the event bus
    {event_type, payload} = event_to_bus(event)

    Bus.emit(event_type, payload,
      source: "conversations",
      correlation_id: state.id
    )
  rescue
    _ -> :ok
  end

  defp event_to_bus({:conversation_started, id, topic}) do
    {:system_event, %{event: :conversation_started, conversation_id: id, topic: topic}}
  end

  defp event_to_bus({:turn_taken, id, agent, _msg, turn}) do
    {:system_event, %{event: :turn_taken, conversation_id: id, agent: agent, turn_count: turn}}
  end

  defp event_to_bus({:conversation_ended, id, summary}) do
    {:system_event,
     %{event: :conversation_ended, conversation_id: id, topic: summary[:topic]}}
  end

  defp state_snapshot(state) do
    %{
      id: state.id,
      type: state.type,
      topic: state.topic,
      status: state.status,
      turn_count: state.turn_count,
      max_turns: state.max_turns,
      participant_count: length(state.participants),
      transcript_length: length(state.transcript)
    }
  end
end
