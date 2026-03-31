defmodule OptimalSystemAgent.Agent.Loop.MessageHandler do
  @moduledoc """
  Pre-LLM message processing for the agent loop.

  Handles the preprocessing phase of `handle_call({:process, ...})`:
  - Memory nudge injection (every N turns)
  - Pre-directive injection (explore-first, delegation enforcement)
  - Plan mode execution (single LLM call with no tools)

  These concerns were extracted from the main loop to keep `Loop` focused on
  GenServer callbacks and the ReAct iteration, not message decoration.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Events.Bus

  @doc """
  Build the final message list to append for this turn.

  Injects a memory nudge every `auto_insights_interval` turns, then prepends
  any system directives required by the message content (explore-first,
  delegation enforcement).

  Returns a list of message maps ready to append to `state.messages`.
  """
  @spec build_messages(String.t(), map()) :: list(map())
  def build_messages(message, state) do
    message_with_nudge = maybe_inject_memory_nudge(message, state)
    pre_directives = build_pre_directives(message_with_nudge, state)
    pre_directives ++ [%{role: "user", content: message_with_nudge}]
  end

  @doc """
  Execute the plan mode branch: single LLM call with no tools.

  Returns `{:reply_tuple, state}` where `:reply_tuple` is either
  `{:plan, plan_text}` (success) or delegates to the caller on failure.
  """
  @spec run_plan_mode(map()) ::
          {:ok, String.t(), map()}
          | {:error, term(), map()}
  def run_plan_mode(state) do
    context = Context.build(state)

    Bus.emit(:llm_request, %{session_id: state.session_id, iteration: 0, agent: state.session_id})
    start_time = System.monotonic_time(:millisecond)

    result = LLMClient.llm_chat(state, context.messages, tools: [], temperature: 0.3)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    usage =
      case result do
        {:ok, resp} -> Map.get(resp, :usage, %{})
        _ -> %{}
      end

    Bus.emit(:llm_response, %{
      session_id: state.session_id,
      provider: state.provider,
      duration_ms: duration_ms,
      usage: usage,
      agent: state.session_id
    })

    case result do
      {:ok, %{content: plan_text}} ->
        plan_input_tokens = Map.get(usage, :input_tokens, 0)
        state = %{state | plan_mode: false}
        state = if plan_input_tokens > 0, do: %{state | last_input_tokens: plan_input_tokens}, else: state

        Bus.emit(:agent_response, %{
          session_id: state.session_id,
          response: plan_text,
          response_type: "plan",
          agent: state.session_id
        })

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{state.session_id}",
          {:osa_event, %{
            type: :agent_response,
            session_id: state.session_id,
            response: plan_text,
            response_type: "plan"
          }}
        )

        {:ok, plan_text, state}

      {:error, reason} ->
        Logger.warning("Plan mode LLM call failed (#{inspect(reason)}), falling back to normal execution")
        state = %{state | plan_mode: false}
        {:error, reason, state}
    end
  end

  # --- Private ---

  defp maybe_inject_memory_nudge(message, state) do
    interval = Application.get_env(:optimal_system_agent, :auto_insights_interval, 10)

    if rem(state.turn_count, interval) == 0 and state.turn_count > 0 do
      message <>
        "\n\n[System: You've had #{state.turn_count} exchanges. " <>
        "Consider saving important context with memory_save if you haven't recently.]"
    else
      message
    end
  end

  defp build_pre_directives(message, state) do
    []
    |> maybe_add_explore_directive(message)
    |> maybe_add_delegation_directive(message, state)
    |> Enum.reverse()
  end

  defp maybe_add_explore_directive(acc, message) do
    cond do
      # Large/unfamiliar codebase exploration — dispatch explorer agent
      Guardrails.needs_exploration?(message) ->
        directive = %{
          role: "system",
          content:
            "[System: This task requires codebase understanding. DISPATCH an explorer agent first: " <>
              "delegate(task: \"Scan the project — report structure, key files, patterns, and tech stack\", role: \"explorer\") " <>
              "Wait for the explorer's report before writing any code. " <>
              "For quick lookups, use thoroughness: \"quick\". For deep analysis, use \"very thorough\".]"
        }
        [directive | acc]

      # Complex coding task — at minimum read before write
      Guardrails.complex_coding_task?(message) ->
        directive = %{
          role: "system",
          content:
            "[System: This task involves code changes. Read relevant files BEFORE modifying them. " <>
              "If the task spans 5+ files or multiple domains, consider dispatching an explorer agent first: " <>
              "delegate(task: \"<specific question about the codebase>\", role: \"explorer\") " <>
              "For simpler tasks, use file_read and dir_list directly.]"
        }
        [directive | acc]

      true ->
        acc
    end
  end

  defp maybe_add_delegation_directive(acc, message, state) do
    if state.permission_tier == :full and Guardrails.delegation_task?(message) do
      directive = %{
        role: "system",
        content:
          "[System: TEAM DISPATCH recommended. This task has multiple independent " <>
            "deliverables. Consider assembling a team using `delegate`: " <>
            "1. Dispatch `explorer` first if you need codebase context " <>
            "2. Dispatch `planner` if the architecture is complex " <>
            "3. Then dispatch implementation agents in parallel " <>
            "Roles: explorer, planner, architect, backend, frontend, tester, debugger, " <>
            "security-auditor, code-reviewer, researcher, devops, doc-writer, refactorer, performance. " <>
            "Use background: true for research while you implement. " <>
            "Use fork: true when agents need your conversation context.]"
      }

      [directive | acc]
    else
      acc
    end
  end
end
