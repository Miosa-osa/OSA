defmodule OptimalSystemAgent.Channels.CLI.MessageQueue do
  @moduledoc """
  Message queue with debounce batching for the CLI REPL.

  Rapid-fire user messages within a short window are batched into a single
  API turn. Slash commands bypass the queue entirely. Messages arriving
  while the agent is busy are held until it finishes.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Channels.CLI.{Commands, Session}

  @debounce_ms 300

  defstruct [
    session_id: nil,
    pending: [],
    queued: [],
    agent_busy: false,
    timer_ref: nil
  ]

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
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_cast({:enqueue, message, opts}, state) do
    if state.agent_busy do
      # Agent is working — queue for later
      {:noreply, %{state | queued: state.queued ++ [{message, opts}]}}
    else
      # Cancel existing debounce timer
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

      # Add to pending batch
      pending = state.pending ++ [{message, opts}]

      # Start new debounce timer
      ref = Process.send_after(self(), :flush, @debounce_ms)
      {:noreply, %{state | pending: pending, timer_ref: ref}}
    end
  end

  @impl true
  def handle_cast(:agent_finished, state) do
    state = %{state | agent_busy: false}

    case state.queued do
      [] ->
        {:noreply, state}

      [{message, opts} | rest] ->
        # Dispatch next queued message
        dispatch_to_agent(message, opts, state.session_id)
        {:noreply, %{state | queued: rest, agent_busy: true}}
    end
  end

  @impl true
  def handle_call(:has_queued?, _from, state) do
    {:reply, state.queued != [] or state.pending != [], state}
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

  defp dispatch_to_agent(message, opts, session_id) do
    Session.send_to_agent(message, session_id, opts)
  end

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.SessionRegistry, {:mq, session_id}}}
  end
end
