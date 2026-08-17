defmodule OptimalSystemAgent.Agent.LoopControl do
  @moduledoc """
  Persistent operator loops that periodically enqueue a prompt into one session.

  A loop is explicit, visible, and cancellable. It never runs an agent directly:
  each tick crosses the normal CLI message queue seam, so busy-session ordering,
  reconnect persistence, permissions, and goal controls continue to apply.
  """

  use GenServer

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Channels.CLI.MessageQueue

  @lane :operator_loop
  @minimum_interval_ms 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec start(String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def start(session_id, interval_ms, prompt)
      when is_binary(session_id) and is_integer(interval_ms) and is_binary(prompt) do
    GenServer.call(__MODULE__, {:start, session_id, interval_ms, prompt})
  end

  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(session_id), do: GenServer.call(__MODULE__, {:stop, session_id})

  @spec status(String.t()) :: map() | nil
  def status(session_id), do: GenServer.call(__MODULE__, {:status, session_id})

  @doc "Parse a duration such as 30s, 5m, or 2h."
  @spec parse_interval(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_interval}
  def parse_interval(text) when is_binary(text) do
    case Regex.run(~r/^(\d+)(s|m|h)$/i, String.trim(text)) do
      [_, number, unit] ->
        multiplier = %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000}[String.downcase(unit)]
        milliseconds = String.to_integer(number) * multiplier

        if milliseconds >= @minimum_interval_ms,
          do: {:ok, milliseconds},
          else: {:error, :invalid_interval}

      _ ->
        {:error, :invalid_interval}
    end
  end

  @impl true
  def init(_) do
    {:ok, restore_all()}
  end

  @impl true
  def handle_call({:start, session_id, interval_ms, prompt}, _from, state) do
    if interval_ms < @minimum_interval_ms or String.trim(prompt) == "" do
      {:reply, {:error, :invalid_loop}, state}
    else
      entry = new_entry(interval_ms, prompt)

      case persist(session_id, entry) do
        :ok ->
          state = cancel_timer(state, session_id)
          {:reply, {:ok, public(entry)}, Map.put(state, session_id, arm(session_id, entry))}

        {:error, reason} ->
          {:reply, {:error, {:persistence_failed, reason}}, state}
      end
    end
  end

  def handle_call({:stop, session_id}, _from, state) do
    case persist(session_id, nil) do
      :ok ->
        state = cancel_timer(state, session_id)
        {:reply, :ok, Map.delete(state, session_id)}

      {:error, reason} ->
        {:reply, {:error, {:persistence_failed, reason}}, state}
    end
  end

  def handle_call({:status, session_id}, _from, state) do
    {:reply, state |> Map.get(session_id) |> public(), state}
  end

  @impl true
  def handle_info({:tick, session_id}, state) do
    case Map.get(state, session_id) do
      nil ->
        {:noreply, state}

      entry ->
        if queue_available?(session_id) do
          attempted =
            Map.merge(entry, %{
              tick_count: entry.tick_count + 1,
              last_tick_at: now_iso(),
              last_tick_status: "dispatching"
            })

          case persist(session_id, attempted) do
            :ok ->
              status =
                if dispatch(session_id, entry.prompt) == :ok, do: "accepted", else: "failed"

              completed = %{attempted | last_tick_status: status}
              _ = persist(session_id, completed)
              {:noreply, Map.put(state, session_id, arm(session_id, completed))}

            {:error, _reason} ->
              {:noreply, Map.put(state, session_id, arm(session_id, entry))}
          end
        else
          {:noreply, Map.put(state, session_id, arm(session_id, entry))}
        end
    end
  end

  defp queue_available?(session_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, {:mq, session_id}) != []
  end

  defp dispatch(session_id, prompt) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, {:mq, session_id}) do
      [{_pid, _}] ->
        try do
          _ = MessageQueue.submit(session_id, prompt, source: :operator_loop)
          :ok
        catch
          :exit, reason -> {:error, {:queue_exit, reason}}
        end

      _ ->
        {:error, :session_queue_unavailable}
    end
  end

  defp restore_all do
    SessionPersistence.list(limit: 1_000, include_cleared: true)
    |> Enum.reduce(%{}, fn %{session_id: session_id}, acc ->
      case SessionPersistence.load_inbox(session_id, @lane) do
        [stored | _] ->
          case restore_entry(stored) do
            nil -> acc
            entry -> Map.put(acc, session_id, maybe_arm_restored(session_id, entry))
          end

        _ ->
          acc
      end
    end)
  end

  defp restore_entry(stored) do
    interval_ms = stored["interval_ms"]
    prompt = stored["prompt"]

    if is_integer(interval_ms) and interval_ms >= @minimum_interval_ms and is_binary(prompt) do
      %{
        interval_ms: interval_ms,
        prompt: prompt,
        tick_count: stored["tick_count"] || 0,
        started_at: stored["started_at"] || now_iso(),
        last_tick_at: stored["last_tick_at"],
        last_tick_status: stored["last_tick_status"],
        timer_ref: nil
      }
    end
  end

  defp new_entry(interval_ms, prompt) do
    %{
      interval_ms: interval_ms,
      prompt: String.trim(prompt),
      tick_count: 0,
      started_at: now_iso(),
      last_tick_at: nil,
      last_tick_status: nil,
      timer_ref: nil
    }
  end

  defp arm(session_id, entry) do
    %{entry | timer_ref: Process.send_after(self(), {:tick, session_id}, entry.interval_ms)}
  end

  # A crash while a tick is marked dispatching is ambiguous: the queue may
  # already have accepted it. At-most-once recovery stops that loop and leaves
  # it visible for an explicit operator restart instead of risking a duplicate.
  defp maybe_arm_restored(_session_id, %{last_tick_status: "dispatching"} = entry), do: entry
  defp maybe_arm_restored(session_id, entry), do: arm(session_id, entry)

  defp cancel_timer(state, session_id) do
    case Map.get(state, session_id) do
      %{timer_ref: ref} when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    state
  end

  defp persist(session_id, nil), do: SessionPersistence.save_inbox(session_id, @lane, [])

  defp persist(session_id, entry) do
    SessionPersistence.save_inbox(session_id, @lane, [public(entry)])
  end

  defp public(nil), do: nil

  defp public(entry) do
    entry
    |> Map.drop([:timer_ref])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
