defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Agent do
  @moduledoc """
  Executor for `:dispatch_agent` — forwards a prompt + context to
  OSA's own agent loop via `OptimalSystemAgent.Agent.Loop.process_message/3`.

  The session lifecycle:
  1. A throwaway session ID is derived from the job ID so that checkpoint /
     memory isolation is automatic and consistent with how the HTTP channel
     works.
  2. `Channels.Session.ensure_loop/3` starts (or reuses) a Loop GenServer
     under `SessionSupervisor`.
  3. `Loop.process_message/3` is called synchronously with a generous timeout
     (default 5 min, overridable via `job[:timeout_ms]`).
  4. The reply callback is invoked with the result and the GenServer stops.

  Errors are caught at two levels:
  - Elixir exceptions and GenServer exits → `{:job_fail, …, :agent_error}`
  - Loop returning `{:error, reason}` → `{:job_fail, …, :agent_returned_error}`
  """

  use GenServer, restart: :temporary
  require Logger

  alias OptimalSystemAgent.Channels.Session
  alias OptimalSystemAgent.Agent.Loop

  @default_timeout_ms :timer.minutes(5)

  def start_link(job, reply) when is_map(job) and is_function(reply, 1) do
    GenServer.start_link(__MODULE__, {job, reply})
  end

  @impl true
  def init({job, reply}) do
    send(self(), :run)
    {:ok, %{job: job, reply: reply}}
  end

  @impl true
  def handle_info(:run, %{job: job, reply: reply} = state) do
    do_run(job, reply)
    {:stop, :normal, state}
  end

  # --- Internals ---

  defp do_run(job, reply) do
    job_id = Map.fetch!(job, :id)
    prompt = Map.get(job, :prompt, "")
    context = Map.get(job, :context, %{})
    timeout = Map.get(job, :timeout_ms, @default_timeout_ms)

    unless is_binary(prompt) and prompt != "" do
      reply.(
        {:job_fail, job_id,
         %{reason: :invalid_prompt, message: "job[:prompt] must be a non-empty string"}}
      )

      return()
    end

    session_id = "oc-agent-#{job_id}"

    opts =
      []
      |> maybe_put(
        :working_dir,
        Map.get(context, :working_dir) || Map.get(context, "working_dir")
      )
      |> maybe_put(:provider, Map.get(context, :provider) || Map.get(context, "provider"))
      |> maybe_put(:model, Map.get(context, :model) || Map.get(context, "model"))

    Logger.info("[Direct.Agent] job=#{job_id} session=#{session_id} starting agent loop")

    result =
      try do
        case Session.ensure_loop(session_id, "open-computers", :open_computers) do
          :ok ->
            Loop.process_message(session_id, prompt, Keyword.put(opts, :timeout, timeout))

          {:error, start_reason} ->
            {:error, {:session_start_failed, start_reason}}
        end
      rescue
        e ->
          Logger.error("[Direct.Agent] job=#{job_id} exception: #{Exception.message(e)}")
          {:error, {:exception, Exception.message(e)}}
      catch
        :exit, exit_reason ->
          Logger.error("[Direct.Agent] job=#{job_id} exit: #{inspect(exit_reason)}")
          {:error, {:exit, inspect(exit_reason)}}
      end

    case result do
      {:ok, response} ->
        Logger.info("[Direct.Agent] job=#{job_id} done")
        reply.({:job_done, job_id, %{result: response, tokens_used: 0}})

      {:plan, plan_text} ->
        # Plan mode returns a plan without executing — treat as a valid result
        Logger.info("[Direct.Agent] job=#{job_id} returned plan")
        reply.({:job_done, job_id, %{result: plan_text, tokens_used: 0}})

      {:error, reason} ->
        message = format_error(reason)
        Logger.warning("[Direct.Agent] job=#{job_id} failed: #{message}")
        reply.({:job_fail, job_id, %{reason: :agent_error, message: message}})
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error({:exception, msg}), do: msg
  defp format_error({:exit, msg}), do: "process exit: #{msg}"
  defp format_error({:session_start_failed, r}), do: "session start failed: #{inspect(r)}"
  defp format_error(other), do: inspect(other)

  # Dummy return/0 — used to early-exit the `unless` branch above without
  # raising (the GenServer continues to :stop after do_run returns).
  defp return(), do: :ok
end
