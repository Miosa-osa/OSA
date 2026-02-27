defmodule OptimalSystemAgent.Agent.Loop do
  @moduledoc """
  Bounded ReAct agent loop — the core reasoning engine.

  Signal Theory grounded: Every iteration processes one signal through
  the 5-tuple S=(M,G,T,F,W) classification before acting.

  Flow:
    1. Receive message from channel/bus
    2. Classify signal (Mode, Genre, Type, Format, Weight)
    3. Filter noise (two-tier: deterministic + LLM)
    4. Build context (identity + memory + skills + runtime)
    5. Call LLM with available tools
    6. If tool_calls: execute each, append results, re-prompt
    7. When no tool_calls: return final response
    8. Write to memory, notify channel
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Signal.Classifier
  alias OptimalSystemAgent.Signal.NoiseFilter
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Skills.Registry, as: Skills
  alias OptimalSystemAgent.Events.Bus

  defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)

  defstruct [
    :session_id,
    :user_id,
    :channel,
    :current_signal,
    messages: [],
    iteration: 0,
    status: :idle,
    tools: []
  ]

  # --- Client API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def process_message(session_id, message) do
    GenServer.call(via(session_id), {:process, message}, :infinity)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      user_id: Keyword.get(opts, :user_id),
      channel: Keyword.get(opts, :channel, :cli),
      tools: Skills.list_tools()
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:process, message}, _from, state) do
    # 1. Classify the signal — every user message is a signal, weight determines priority
    signal = Classifier.classify(message, state.channel)

    # 2. Check noise filter — but ALWAYS process, just log the classification
    #    Every message a user sends is a signal. The weight determines what kind.
    #    Noise filtering is informational, not a gate.
    case NoiseFilter.filter(message) do
      {:noise, reason} ->
        Logger.debug("Signal classified as low-weight (#{reason}), weight=#{signal.weight}")
        Bus.emit(:system_event, %{event: :signal_low_weight, signal: signal, reason: reason})

      {:signal, _weight} ->
        :ok
    end

    # 3. Persist user message to JSONL session storage
    Memory.append(state.session_id, %{role: "user", content: message})

    # 4. Compact message history if needed, then process through agent loop
    compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
    state = %{state | messages: compacted, current_signal: signal}

    state = %{state | messages: state.messages ++ [%{role: "user", content: message}], iteration: 0, status: :thinking}
    {response, state} = run_loop(state)
    state = %{state | messages: state.messages ++ [%{role: "assistant", content: response}], status: :idle}

    # 5. Persist assistant response to JSONL session storage
    Memory.append(state.session_id, %{role: "assistant", content: response})

    Bus.emit(:agent_response, %{session_id: state.session_id, response: response, signal: signal})

    {:reply, {:ok, response}, state}
  end

  # --- Agent Loop ---

  defp run_loop(%{iteration: iter} = state) do
    max_iter = max_iterations()
    if iter >= max_iter do
      Logger.warning("Agent loop hit max iterations (#{max_iter})")
      {"I've reached my reasoning limit for this request. Here's what I have so far.", state}
    else
      do_run_loop(state)
    end
  end

  defp do_run_loop(state) do
    # Build context (passes current signal for signal-aware system prompt)
    context = Context.build(state, state.current_signal)

    # Emit timing event before LLM call
    Bus.emit(:llm_request, %{session_id: state.session_id, iteration: state.iteration})
    start_time = System.monotonic_time(:millisecond)

    # Call LLM
    result = Providers.chat(context.messages, tools: state.tools, temperature: temperature())

    # Emit timing + usage event after LLM call
    duration_ms = System.monotonic_time(:millisecond) - start_time
    usage = case result do
      {:ok, resp} -> Map.get(resp, :usage, %{})
      _ -> %{}
    end
    Bus.emit(:llm_response, %{session_id: state.session_id, duration_ms: duration_ms, usage: usage})

    case result do
      {:ok, %{content: content, tool_calls: []}} ->
        # No tool calls — final response
        {content, state}

      {:ok, %{content: content, tool_calls: tool_calls}} when is_list(tool_calls) ->
        # Execute tool calls
        state = %{state | iteration: state.iteration + 1}

        # Append assistant message with tool calls
        state = %{state | messages: state.messages ++ [%{role: "assistant", content: content, tool_calls: tool_calls}]}

        # Execute each tool and append results (with timing feedback)
        state = Enum.reduce(tool_calls, state, fn tool_call, acc ->
          arg_hint = tool_call_hint(tool_call.arguments)
          Bus.emit(:tool_call, %{name: tool_call.name, phase: :start, args: arg_hint})
          start_time_tool = System.monotonic_time(:millisecond)

          result_str =
            case Skills.execute(tool_call.name, tool_call.arguments) do
              {:ok, content} -> content
              {:error, reason} -> "Error: #{reason}"
            end

          tool_duration_ms = System.monotonic_time(:millisecond) - start_time_tool
          Bus.emit(:tool_call, %{name: tool_call.name, phase: :end, duration_ms: tool_duration_ms, args: arg_hint})

          tool_msg = %{role: "tool", tool_call_id: tool_call.id, content: result_str}
          %{acc | messages: acc.messages ++ [tool_msg]}
        end)

        # Re-prompt
        run_loop(state)

      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        {"I encountered an error processing your request. Please try again.", state}
    end
  end

  defp tool_call_hint(%{"command" => cmd}), do: String.slice(cmd, 0, 60)
  defp tool_call_hint(%{"path" => p}), do: p
  defp tool_call_hint(%{"query" => q}), do: String.slice(q, 0, 60)
  defp tool_call_hint(args) when is_map(args) and map_size(args) > 0 do
    args |> Map.keys() |> Enum.take(2) |> Enum.join(", ")
  end
  defp tool_call_hint(_), do: ""

  # --- Helpers ---

  defp via(session_id), do: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}}

  defp temperature, do: Application.get_env(:optimal_system_agent, :temperature, 0.7)
end
