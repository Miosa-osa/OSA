defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `send_message`.

  Behaviour split:
    * `validate/2`           — checks input shape
    * `check_permissions/2`  — always allowed (PubSub is process-local)
    * `execute/2`            — resolves target, broadcasts via PubSub, stores in ETS
  """

  alias OptimalSystemAgent.Tools.Builtins.SendMessage.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"to" => to, "message" => msg} = input, _ctx)
      when is_binary(to) and is_binary(msg),
      do: {:ok, input}

  def validate(%{"to" => _, "message" => _}, _ctx),
    do: {:error, "to and message must be strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: to, message", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"to" => to, "message" => message} = _args, ctx) do
    sender_id = ctx.session_id || "unknown"
    target_id = resolve_target(to)

    if target_id do
      # Keep the existing per-agent topic + ETS pending row (drained into the
      # RECIPIENT agent's LLM context by react_loop) — other code depends on it.
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:agent:#{target_id}",
        {:agent_message,
         %{
           from: sender_id,
           to: target_id,
           content: message,
           timestamp: DateTime.utc_now()
         }}
      )

      store_pending_message(target_id, sender_id, message)

      # ALSO surface it to the human on the recipient's SESSION topic (the one
      # the TUI streams). Shared contract: %{type: :agent_message, from, text}.
      # Without this the message only ever reached the recipient's LLM context.
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{target_id}",
        {:osa_event,
         %{
           type: :agent_message,
           session_id: target_id,
           from: pretty_name(sender_id),
           text: message,
           timestamp: DateTime.utc_now()
         }}
      )

      {:ok, "Message sent to #{to} (#{target_id})"}
    else
      {:ok, "Error: could not find agent '#{to}'. Use /agents to see running agents."}
    end
  end

  @doc """
  Retrieve and clear pending messages for an agent. Called by react_loop
  at the start of each iteration.
  """
  @spec drain_pending_messages(String.t()) :: [map()]
  def drain_pending_messages(agent_id) do
    try do
      messages = :ets.lookup(Constants.pending_table(), agent_id)
      :ets.delete(Constants.pending_table(), agent_id)
      Enum.map(messages, fn {_key, msg} -> msg end)
    rescue
      _ -> []
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  # Render a compact @handle from a session id: "agent:parent:smoke-e2e" -> "smoke-e2e".
  defp pretty_name(id) when is_binary(id) do
    id |> String.split(":") |> List.last() |> to_string()
  end

  defp pretty_name(id), do: to_string(id)

  defp resolve_target(id_or_name) do
    # Support "@name" addressing by stripping a leading @ before matching.
    id_or_name = id_or_name |> to_string() |> String.trim_leading("@")

    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id_or_name) do
      [{_pid, _}] ->
        id_or_name

      [] ->
        sessions =
          try do
            Registry.select(OptimalSystemAgent.SessionRegistry, [
              {
                {:"$1", :"$2", :"$3"},
                [],
                [{{:"$1", :"$2", :"$3"}}]
              }
            ])
          rescue
            _ -> []
          end

        case Enum.find(sessions, fn {sid, _pid, _meta} ->
               String.contains?(sid, id_or_name)
             end) do
          {sid, _, _} -> sid
          nil -> nil
        end
    end
  end

  defp store_pending_message(target_id, sender_id, message) do
    try do
      try do
        :ets.new(Constants.pending_table(), [:bag, :public, :named_table])
      rescue
        ArgumentError -> Constants.pending_table()
      end

      :ets.insert(Constants.pending_table(), {
        target_id,
        %{
          from: sender_id,
          content: message,
          timestamp: System.system_time(:millisecond)
        }
      })
    rescue
      _ -> :ok
    end
  end
end
