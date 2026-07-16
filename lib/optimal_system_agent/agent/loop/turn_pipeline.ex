defmodule OptimalSystemAgent.Agent.Loop.TurnPipeline do
  @moduledoc """
  Ordered pre-LLM gate pipeline for a single agent turn.

  Extracted from the `Loop` GenServer's `{:process, message, opts}` callback so
  the per-turn gates live in one place with named steps instead of one
  ~115-line god-callback. Runs, in order:

    1. `clear_cancel_flag`     — drop any stale cancel flag for this session
    2. `apply_overrides`       — per-call provider/model/working_dir overrides
    3. increment turn_count
    4. `Limits.check`          — budget / turn-limit guard (hard stop)
    5. `clear_message_caches`  — reset per-message process-dictionary caches
    6. `run_user_prompt_submit_hook` — UserPromptSubmit hook (may rewrite/block)
    7. prompt-injection guard  — `Guardrails` hard block (no memory write)
    8. `prepare_turn`          — signal weight, compaction, message build, reset
    9. `route_genre`           — `GenreRouter`; canned response or tool execution

  Returns either `{:reply, reply, state}` for a terminal gate outcome, or
  `{:dispatch, state, skip_plan}` to hand control back to `Loop` for plan-mode /
  ReactLoop execution. Behaviour is identical to the original inline callback.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Observability
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.GenreRouter
  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.Loop.Limits

  @cancel_table :osa_cancel_flags

  @doc """
  Run the pre-LLM gate pipeline for one turn.

  Returns `{:reply, reply, state}` for a terminal outcome (limit breach, hook
  block, prompt-injection refusal, or genre canned response) or
  `{:dispatch, state, skip_plan}` when the turn should proceed to tool
  execution in `Loop`.
  """
  @spec run(term(), keyword(), map()) ::
          {:reply, term(), map()} | {:dispatch, map(), boolean()}
  def run(message, opts, state) do
    skip_plan = Keyword.get(opts, :skip_plan, false)

    clear_cancel_flag(state)

    state = apply_overrides(state, opts)
    state = %{state | turn_count: state.turn_count + 1}

    # Budget and turn limit guards — check before any processing
    limit_error = Limits.check(state)

    if limit_error do
      {:reply, {:error, limit_error}, state}
    else
      # Clear per-message process caches
      clear_message_caches()

      # -1. UserPromptSubmit hook — can modify or block the message
      {message, state} = run_user_prompt_submit_hook(message, state)

      if is_nil(message) do
        {:reply, {:error, "Message blocked by hook"}, state}
      else
        # 0. Prompt injection guard
        if Guardrails.prompt_injection?(message) do
          refusal = Guardrails.prompt_extraction_refusal()
          {:reply, {:ok, refusal}, %{state | status: :idle}}
        else
          state = prepare_turn(message, opts, state)
          route_genre(message, opts, state, skip_plan)
        end
      end
    end
  end

  # --- Steps ---

  defp clear_cancel_flag(state) do
    try do
      :ets.delete(@cancel_table, state.session_id)
    rescue
      ArgumentError -> :ok
    end
  end

  defp apply_overrides(state, opts) do
    state
    |> maybe_override(:provider, Keyword.get(opts, :provider))
    |> maybe_override(:model, Keyword.get(opts, :model))
    |> maybe_override(:working_dir, Keyword.get(opts, :working_dir))
  end

  defp maybe_override(state, _key, nil), do: state
  defp maybe_override(state, key, value), do: Map.put(state, key, value)

  defp clear_message_caches do
    Process.delete(:osa_git_info_cache)
    Process.delete(:osa_workspace_overview_cache)
    Process.delete(:osa_system_msg_cache)
    Process.put(:osa_memory_version, 0)
  end

  defp run_user_prompt_submit_hook(message, state) do
    try do
      case Hooks.run(:user_prompt_submit, %{
             message: message,
             session_id: state.session_id,
             turn_count: state.turn_count
           }) do
        {:ok, %{message: modified}} when is_binary(modified) -> {modified, state}
        {:blocked, _reason} -> {nil, %{state | status: :idle}}
        _ -> {message, state}
      end
    rescue
      _ -> {message, state}
    catch
      :exit, _ -> {message, state}
    end
  end

  # signal weight, compaction, decorated message build, and per-turn state reset
  defp prepare_turn(message, opts, state) do
    signal_weight = Keyword.get(opts, :signal_weight, nil)

    # Mint a per-turn correlation id (prompt.id-style) and emit turn_start so the
    # per-session event stream is correlated + replayable (primitive #30).
    state = %{state | signal_weight: signal_weight, turn_id: Observability.new_turn_id()}
    Observability.turn_start(state)

    # Compact message history if needed. Feed the last response's REAL provider-
    # reported input-token count (recorded by the budget/accounting stage) into
    # the compaction decision instead of the char-heuristic estimate; falls back
    # to the estimate on the first turn when no real count exists yet.
    compacted =
      Compactor.maybe_compact(state.messages, Map.get(state, :last_input_tokens, 0)) ||
        state.messages

    state = %{state | messages: compacted}

    # Build decorated message list (nudges + pre-directives + user message)
    messages_to_append = MessageHandler.build_messages(message, state)

    %{
      state
      | messages: state.messages ++ messages_to_append,
        iteration: 0,
        overflow_retries: 0,
        auto_continues: 0,
        status: :thinking,
        exploration_done: false,
        # Reset doom loop signatures on each new user turn —
        # the user explicitly wants to try again, don't carry over old failures
        recent_failure_signatures: [],
        # Reset repeated-failure recovery attempts each new user turn (formerly
        # a per-message process-dict delete in clear_message_caches).
        doom_recovery_count: 0
    }
  end

  defp route_genre(message, opts, state, skip_plan) do
    # Genre routing
    signal_genre = Keyword.get(opts, :signal_genre, :direct)
    genre_route = GenreRouter.route_by_genre(signal_genre, message, state)

    case genre_route do
      {:respond, genre_response} ->
        state = %{state | status: :idle}

        Bus.emit(:agent_response, %{
          session_id: state.session_id,
          response: genre_response,
          agent: state.session_id
        })

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{state.session_id}",
          {:osa_event,
           %{
             type: :agent_response,
             session_id: state.session_id,
             response: genre_response,
             response_type: "genre"
           }}
        )

        {:reply, {:ok, genre_response}, state}

      :execute_tools ->
        {:dispatch, state, skip_plan}
    end
  end
end
