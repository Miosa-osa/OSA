defmodule OptimalSystemAgent.Channels.Delivery do
  @moduledoc """
  Shared outbound-delivery plumbing for channel adapters.

  Two defects live here, both of the same shape — a failure that nobody was
  told about:

    * `send_chunks/3` replaces the `Enum.each(chunks, &post/1); :ok` pattern
      that every adapter used. `Enum.each/2` throws its element results away, so
      an adapter reported `:ok` to its caller after a chunk had been rejected
      with a 400 or the connection had dropped. A partial send must not look
      like a successful one.

    * `start_task/2` replaces the bare `Task.Supervisor.start_child/2` call
      whose `{:error, :max_children}` return every adapter discarded. When the
      shared pool is saturated the child is never started, so the agent turn
      simply never happens and the user waits forever on a reply that was never
      queued. The result is now logged and returned.
  """

  require Logger

  # Channels get their own pool, separate from the event bus. Delivery to a
  # wedged chat can then only exhaust the delivery pool — not the bus and SSE
  # dispatch the rest of the node depends on. Callers may pass a different
  # supervisor, so per-channel isolation is a change to the supervisor's child
  # list alone.
  @task_supervisor OptimalSystemAgent.Channels.TaskSupervisor

  @typedoc "Whatever a channel's per-chunk post function returns."
  @type post_result :: :ok | {:ok, term()} | {:error, term()} | term()

  @doc """
  Post `chunks` in order via `post_fun`, stopping at the first failure.

  Returns `:ok` only when every chunk was accepted. On failure it returns
  `{:error, {:chunk_failed, index, total, reason}}` (1-based `index`) so the
  caller can see how much of the reply actually landed.

  Delivery halts rather than pressing on because continuing past a rejected
  chunk is what produced the original symptom: chunk 3 vanishes, chunks 4-7
  arrive, and the reply reads as if the agent lost the thread. Stopping at the
  break leaves a reply that is merely short, and returns an error the caller can
  act on.

  `post_fun` may return `:ok`, `{:ok, _}`, or `{:error, reason}`. Anything else
  is treated as success, since several adapters post via `Req` wrappers that
  return richer shapes on success.
  """
  @spec send_chunks(atom() | String.t(), [String.t()], (String.t() -> post_result())) ::
          :ok | {:error, {:chunk_failed, pos_integer(), pos_integer(), term()}}
  def send_chunks(channel, chunks, post_fun) when is_list(chunks) and is_function(post_fun, 1) do
    total = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case post_fun.(chunk) do
        {:error, reason} ->
          Logger.warning(
            "[#{label(channel)}] send aborted at chunk #{index}/#{total}: #{inspect(reason)} — " <>
              "#{index - 1} of #{total} chunk(s) delivered"
          )

          {:halt, {:error, {:chunk_failed, index, total, reason}}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  @doc """
  Start supervised async work for a channel, surfacing pool exhaustion.

  All channel adapters share one `Task.Supervisor` with a `max_children` cap, so
  a channel that wedges enough tasks can stop every other channel — and the
  event bus — from starting new ones. This does not fix that (the pool is
  configured outside this tree) but it stops the failure from being silent:
  `{:error, :max_children}` is logged at `:error` and returned, instead of being
  dropped on the floor as an unused return value.
  """
  @spec start_task(atom() | String.t(), (-> any()), Supervisor.supervisor()) ::
          {:ok, pid()} | {:error, :max_children} | {:error, term()}
  def start_task(channel, fun, supervisor \\ @task_supervisor) when is_function(fun, 0) do
    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :max_children} = error ->
        Logger.error(
          "[#{label(channel)}] task pool exhausted (max_children) — this turn was dropped " <>
            "before it started. The pool is shared by every channel and the event bus, so " <>
            "another channel may be starving this one."
        )

        error

      {:error, reason} = error ->
        Logger.error("[#{label(channel)}] failed to start task: #{inspect(reason)}")
        error
    end
  end

  defp label(channel) when is_atom(channel) do
    channel |> Atom.to_string() |> String.capitalize()
  end

  defp label(channel), do: channel
end
