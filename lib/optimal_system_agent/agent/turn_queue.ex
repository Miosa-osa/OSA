defmodule OptimalSystemAgent.Agent.TurnQueue do
  @moduledoc """
  Per-session turn queue for user prompts.

  Agent loops are GenServers, so concurrent `process_message/3` calls would be
  serialized eventually, but callers had no first-class queue state. This module
  makes that lifecycle explicit: one active turn per session, FIFO queued turns,
  and session-scoped events for the TUI.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Runtime.SessionManager

  defstruct active: %{}, queues: %{}

  @type enqueue_status :: :processing | :queued

  @doc false
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @doc """
  Enqueue a user turn.

  Options:
    * `:queue` - queue process/name, defaults to this module
    * `:task_supervisor` - task supervisor used to run turns
    * `:process_fun` - test seam; defaults to `SessionManager.process_message/3`
    * `:process_opts` - options passed to `process_fun`
  """
  @spec enqueue(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def enqueue(session_id, message, opts \\ [])
      when is_binary(session_id) and is_binary(message) do
    queue = Keyword.get(opts, :queue, __MODULE__)
    GenServer.call(queue, {:enqueue, session_id, message, opts})
  end

  @doc "Return queue state for a session."
  @spec status(String.t(), keyword()) :: map()
  def status(session_id, opts \\ []) do
    queue = Keyword.get(opts, :queue, __MODULE__)
    GenServer.call(queue, {:status, session_id})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:enqueue, session_id, message, opts}, _from, state) do
    item = %{
      turn_id: turn_id(),
      session_id: session_id,
      message: message,
      opts: opts,
      queued_at: DateTime.utc_now()
    }

    if Map.has_key?(state.active, session_id) do
      queue = Map.get(state.queues, session_id, []) ++ [item]
      queue_depth = length(queue)
      state = put_in(state.queues[session_id], queue)

      emit_turn_event(:turn_queued, item, %{
        status: "queued",
        queue_depth: queue_depth,
        position: queue_depth
      })

      {:reply, {:ok, reply(:queued, item, queue_depth)}, state}
    else
      case start_turn(item, state) do
        {:ok, state} ->
          {:reply, {:ok, reply(:processing, item, 0)}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:status, session_id}, _from, state) do
    queued = Map.get(state.queues, session_id, [])

    {:reply,
     %{
       session_id: session_id,
       active: Map.has_key?(state.active, session_id),
       active_turn_id: get_in(state.active, [session_id, :turn_id]),
       queue_depth: length(queued),
       queued_turn_ids: Enum.map(queued, & &1.turn_id)
     }, state}
  end

  @impl true
  def handle_cast({:turn_finished, session_id, turn_id, result}, state) do
    active = Map.get(state.active, session_id)

    state =
      if active && active.turn_id == turn_id do
        emit_turn_event(:turn_completed, active, %{
          status: "completed",
          queue_depth: length(Map.get(state.queues, session_id, [])),
          result_status: result_status(result)
        })

        %{state | active: Map.delete(state.active, session_id)}
      else
        state
      end

    dispatch_next(session_id, state)
  end

  defp dispatch_next(session_id, state) do
    case Map.get(state.queues, session_id, []) do
      [] ->
        {:noreply, %{state | queues: Map.delete(state.queues, session_id)}}

      [next | rest] ->
        state = put_in(state.queues[session_id], rest)

        case start_turn(next, state) do
          {:ok, state} ->
            {:noreply, state}

          {:error, reason} ->
            Logger.error("[TurnQueue] failed to start queued turn: #{inspect(reason)}")

            emit_turn_event(:turn_completed, next, %{
              status: "failed",
              queue_depth: length(rest),
              error: inspect(reason)
            })

            dispatch_next(session_id, state)
        end
    end
  end

  defp start_turn(item, state) do
    opts = item.opts
    supervisor = Keyword.get(opts, :task_supervisor, OptimalSystemAgent.TaskSupervisor)
    process_fun = Keyword.get(opts, :process_fun, &SessionManager.process_message/3)
    process_opts = Keyword.get(opts, :process_opts, [])
    queue = Keyword.get(opts, :queue, __MODULE__)

    case Task.Supervisor.start_child(supervisor, fn ->
           result =
             try do
               process_fun.(item.session_id, item.message, process_opts)
             rescue
               e -> {:error, e}
             catch
               kind, reason -> {:error, {kind, reason}}
             end

           GenServer.cast(queue, {:turn_finished, item.session_id, item.turn_id, result})
         end) do
      {:ok, pid} ->
        item = Map.put(item, :pid, pid)

        emit_turn_event(:turn_started, item, %{
          status: "processing",
          queue_depth: length(Map.get(state.queues, item.session_id, []))
        })

        {:ok, put_in(state.active[item.session_id], item)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reply(status, item, queue_depth) do
    %{
      status: status_name(status),
      session_id: item.session_id,
      turn_id: item.turn_id,
      queue_depth: queue_depth
    }
  end

  defp status_name(:processing), do: "processing"
  defp status_name(:queued), do: "queued"

  defp result_status({:ok, _}), do: "ok"
  defp result_status({:error, _}), do: "error"
  defp result_status(_), do: "ok"

  defp turn_id do
    "turn_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_turn_event(type, item, extra) do
    payload =
      Map.merge(
        %{
          type: type,
          event: type,
          session_id: item.session_id,
          turn_id: item.turn_id
        },
        extra
      )

    try do
      Bus.emit(:system_event, payload)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    try do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{item.session_id}",
        {:osa_event, payload}
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
