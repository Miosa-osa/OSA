defmodule OptimalSystemAgent.Agent.Loop.Telemetry do
  @moduledoc """
  Context pressure and token estimation telemetry for the agent loop.

  Emits `context_pressure` events to the Events.Bus and Phoenix.PubSub so the
  TUI status bar can display live context window utilization.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @doc """
  Emit context window pressure metrics for the current state.

  Uses actual LLM-reported input tokens when available; falls back to the
  word-count heuristic from `Compactor.estimate_tokens/1`.
  """
  @spec emit_context_pressure(map()) :: :ok
  def emit_context_pressure(state) do
    max_tok = OptimalSystemAgent.Providers.Registry.context_window(state.model)

    estimated =
      if state.last_input_tokens > 0,
        do: state.last_input_tokens,
        else: OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)

    utilization = if max_tok > 0, do: Float.round(estimated / max_tok * 100, 1), else: 0.0
    Logger.info("[ctx] estimated=#{estimated} max=#{max_tok} util=#{utilization}%")

    Bus.emit(:system_event, %{
      event: :context_pressure,
      session_id: state.session_id,
      estimated_tokens: estimated,
      max_tokens: max_tok,
      utilization: utilization
    })

    Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
      {:osa_event, %{
        type: :context_pressure,
        session_id: state.session_id,
        estimated_tokens: estimated,
        max_tokens: max_tok,
        utilization: utilization
      }})

    :ok
  rescue
    e -> Logger.debug("emit_context_pressure failed: #{inspect(e)}")
  end

  @doc """
  Estimate token count for session introspection (`:get_state` response).
  Returns 0 on any error.
  """
  @spec estimate_tokens(map()) :: non_neg_integer()
  def estimate_tokens(state) do
    try do
      OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
    rescue
      _ -> 0
    end
  end

  @doc """
  Extract unique tool names used in the message history.
  """
  @spec extract_tools_used(list(map())) :: list(String.t())
  def extract_tools_used(messages) do
    messages
    |> Enum.filter(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs) and tcs != [] -> true
      _ -> false
    end)
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end
end
