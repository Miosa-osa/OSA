defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `send_message`.

  Behaviour split:
    * `validate/2`           — checks input shape
    * `check_permissions/2`  — always allowed (PubSub is process-local)
    * `execute/2`            — resolves target, broadcasts via PubSub, stores in ETS
  """

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.SendMessage.{Constants, Discipline}
  alias OptimalSystemAgent.Tools.UseContext

  # Addresses that mean "the session that delegated me". A subagent knows its
  # own id and its teammates' names, but had NO way to name the one participant
  # it most often needs — the conversation it was spawned from. Without this the
  # interruption channel exists and is unreachable from the side that needs it.
  @parent_aliases ~w(user parent)

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

    case Discipline.check(sender_id) do
      :ok -> deliver(to, message, sender_id)
      {:refused, reason} -> {:ok, reason}
    end
  end

  # The send itself, once the sender has been cleared to speak.
  defp deliver(to, message, sender_id) do
    target_id = resolve_target(to, sender_id)
    message = Discipline.truncate(message, sender_id)

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
      {:ok, not_found(to)}
    end
  end

  defp not_found(to) do
    if String.downcase(String.trim_leading(to_string(to), "@")) in @parent_aliases do
      "Error: `to: \"#{to}\"` addresses the session that delegated you, and this " <>
        "session has no parent — you are not running as a subagent. Address a " <>
        "teammate by name instead."
    else
      "Error: could not find agent '#{to}'. Use /agents to see running agents."
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

      cutoff = System.system_time(:millisecond) - Constants.pending_ttl_ms()

      messages
      |> Enum.map(fn {_key, msg} -> msg end)
      |> Enum.reject(&expired?(&1, cutoff))
    rescue
      _ -> []
    end
  end

  @doc """
  Drop parked messages older than `Constants.pending_ttl_ms/0`.

  The bag is written by the SENDER and drained by the RECIPIENT's loop, so a
  message addressed to an agent that crashed, or that finished before its next
  iteration, was never drained — it sat in ETS for the lifetime of the node.
  Nothing bounded the table. This sweeps it; it runs on every send, which is
  rare (a subagent gets two), so the scan cost is irrelevant.
  """
  @spec sweep_pending(integer() | nil) :: non_neg_integer()
  def sweep_pending(now_ms \\ nil) do
    now_ms = now_ms || System.system_time(:millisecond)
    cutoff = now_ms - Constants.pending_ttl_ms()

    :ets.select_delete(Constants.pending_table(), [
      {{:_, %{timestamp: :"$1"}}, [{:<, :"$1", cutoff}], [true]}
    ])
  rescue
    _ -> 0
  end

  # A row with no usable timestamp is treated as live: dropping messages we
  # cannot date would lose real ones to guard against a leak we cannot prove.
  defp expired?(%{timestamp: ts}, cutoff) when is_integer(ts), do: ts < cutoff
  defp expired?(_msg, _cutoff), do: false

  # ── Private ───────────────────────────────────────────────────────────

  # The @handle the human sees on an inbound message.
  #
  # The last `:`-segment of a session id is an ORDINAL, not a name: a subagent
  # spawned as `agent:sess-123:7` rendered as `@7`, which tells the reader
  # nothing about who is speaking or why they should care. The run's role is the
  # name the user chose when delegating, so prefer it and fall back to the
  # segment only when there is no run row (a plain session, a test double).
  defp pretty_name(id) when is_binary(id) do
    case RunStore.get(id) do
      %{role: role} when is_binary(role) and role != "" -> role
      _ -> id |> String.split(":") |> List.last() |> to_string()
    end
  rescue
    _ -> id |> String.split(":") |> List.last() |> to_string()
  catch
    :exit, _ -> id |> String.split(":") |> List.last() |> to_string()
  end

  defp pretty_name(id), do: to_string(id)

  defp resolve_target(id_or_name, sender_id) do
    # Support "@name" addressing by stripping a leading @ before matching.
    id_or_name = id_or_name |> to_string() |> String.trim_leading("@")

    if String.downcase(id_or_name) in @parent_aliases do
      parent_of(sender_id)
    else
      resolve_named(id_or_name)
    end
  end

  # The parent session id recorded for this run at spawn time. `nil` for a
  # top-level session, which has no parent to address.
  defp parent_of(sender_id) when is_binary(sender_id) do
    case RunStore.get(sender_id) do
      %{parent_session_id: parent} when is_binary(parent) and parent not in ["", "unknown"] ->
        parent

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp parent_of(_), do: nil

  defp resolve_named(id_or_name) do
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

      # Bound the bag before adding to it. Undelivered rows are the ones that
      # accumulate, and nothing else ever removes them.
      sweep_pending()

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
