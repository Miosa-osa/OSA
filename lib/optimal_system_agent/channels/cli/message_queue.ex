defmodule OptimalSystemAgent.Channels.CLI.MessageQueue do
  @moduledoc """
  Message queue with debounce batching for the CLI REPL.

  Rapid-fire user messages within a short window are batched into a single
  API turn. Slash commands bypass the queue entirely. Messages arriving
  while the agent is busy are held until it finishes.

  ## Durability (task #32)

  The `queued` list (messages accepted while the agent is busy) is mirrored to
  the session store on every mutation via `SessionPersistence.save_queue/2`, and
  restored on `init/1`. The in-memory queue stays authoritative and fast — the
  persisted copy is a durable mirror so queued-but-unsent messages survive a
  backend restart instead of being silently lost. The `pending` debounce batch
  is intentionally *not* persisted: it flushes within the debounce window and
  only exists while the agent is idle.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Channels.CLI.{Commands, Session}

  @debounce_ms 300

  defstruct session_id: nil,
            pending: [],
            queued: [],
            agent_busy: false,
            timer_ref: nil

  @typedoc "Observable result of submitting user input to the session state machine."
  @type submission :: %{
          required(:status) => :accepted | :queued | :command,
          required(:session_id) => String.t(),
          optional(:position) => pos_integer()
        }

  # ── Client API ───────────────────────────────────────────────────────

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @doc "Enqueue a message. Slash commands dispatch immediately."
  def enqueue(session_id, message, opts \\ []) do
    if String.starts_with?(message, "/") do
      # Slash commands bypass the queue
      cmd = String.trim_leading(message, "/")
      Commands.dispatch(cmd, session_id)
    else
      GenServer.cast(via(session_id), {:enqueue, message, opts})
      session_id
    end
  end

  @doc "Submit input and synchronously report whether it was accepted or queued."
  @spec submit(String.t(), String.t(), keyword()) :: submission()
  def submit(session_id, message, opts \\ []) do
    if String.starts_with?(message, "/") do
      Commands.dispatch(String.trim_leading(message, "/"), session_id)
      %{status: :command, session_id: session_id}
    else
      GenServer.call(via(session_id), {:submit, message, opts})
    end
  end

  @doc "Signal that the agent finished processing — dispatch next queued message."
  def agent_finished(session_id) do
    GenServer.cast(via(session_id), :agent_finished)
  rescue
    _ -> :ok
  end

  @doc "Check if there are queued messages waiting."
  def has_queued?(session_id) do
    GenServer.call(via(session_id), :has_queued?)
  rescue
    _ -> false
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(session_id) do
    # Restore any queued-but-unsent messages persisted before a restart. They
    # come back as {text, []} tuples (opts are transient debounce metadata and
    # are not mirrored). The agent is assumed idle at startup, so they sit in
    # `queued` and dispatch on the first `agent_finished`.
    restored =
      case restore_queue(session_id) do
        [] ->
          []

        msgs ->
          Logger.info(
            "[message_queue] restored #{length(msgs)} queued message(s) for #{session_id}"
          )

          Enum.map(msgs, fn m -> {m, []} end)
      end

    {:ok, %__MODULE__{session_id: session_id, queued: restored}}
  end

  @impl true
  def handle_cast({:enqueue, message, opts}, state) do
    {_outcome, state} = accept(message, opts, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:agent_finished, state) do
    state = %{state | agent_busy: false}

    case state.queued do
      [] ->
        {:noreply, state}

      [{message, opts} | rest] ->
        # Dispatch next queued message; shrink the durable mirror to match.
        persist_queue(state.session_id, rest)
        dispatch_to_agent(message, opts, state.session_id)
        {:noreply, %{state | queued: rest, agent_busy: true}}
    end
  end

  @impl true
  def handle_call(:has_queued?, _from, state) do
    {:reply, state.queued != [] or state.pending != [], state}
  end

  def handle_call({:submit, message, opts}, _from, state) do
    {outcome, state} = accept(message, opts, state)
    {:reply, outcome, state}
  end

  @impl true
  def handle_info(:flush, state) do
    case state.pending do
      [] ->
        {:noreply, %{state | timer_ref: nil}}

      pending ->
        # Batch all pending messages into one
        batched = pending |> Enum.map(fn {msg, _opts} -> msg end) |> Enum.join("\n\n")
        opts = pending |> List.last() |> elem(1)

        dispatch_to_agent(batched, opts, state.session_id)
        {:noreply, %{state | pending: [], timer_ref: nil, agent_busy: true}}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp accept(message, opts, state) do
    if state.agent_busy do
      queued = state.queued ++ [{message, opts}]
      persist_queue(state.session_id, queued)

      {%{status: :queued, session_id: state.session_id, position: length(queued)},
       %{state | queued: queued}}
    else
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      pending = state.pending ++ [{message, opts}]
      ref = Process.send_after(self(), :flush, @debounce_ms)

      {%{status: :accepted, session_id: state.session_id},
       %{state | pending: pending, timer_ref: ref}}
    end
  end

  defp dispatch_to_agent(message, opts, session_id) do
    Session.send_to_agent(message, session_id, opts)
  end

  # Mirror the queued message texts to the durable session store. Best-effort:
  # a persistence failure must never crash the live queue.
  defp persist_queue(session_id, queued) do
    texts = for {msg, _opts} <- queued, is_binary(msg), do: msg
    SessionPersistence.save_queue(session_id, texts)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Read back any persisted queue on startup (best-effort → []).
  defp restore_queue(session_id) do
    SessionPersistence.load_queue(session_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.SessionRegistry, {:mq, session_id}}}
  end
end
