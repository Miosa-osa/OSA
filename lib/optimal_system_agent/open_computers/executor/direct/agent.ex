defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Agent do
  @moduledoc """
  Executor for `:dispatch_agent` — forwards a prompt + context to
  OSA's own agent loop.

  Since this extension lives inside OSA, `:dispatch_agent` just becomes
  a local call into `OptimalSystemAgent.Agent` / `.Loop` / the
  orchestrator — no HTTP hop, no external OSA process.

  Phase 1 stub. The integration point lands in Phase 2 once we pick
  the exact OSA entry point (likely `OptimalSystemAgent.Orchestrator` or
  the Loop module).
  """

  use GenServer, restart: :temporary
  require Logger

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
    reply.(
      {:job_fail, job.id,
       %{
         reason: :not_implemented,
         message:
           "Direct.Agent — integration with OSA's internal agent loop pending (Phase 2)"
       }}
    )

    {:stop, :normal, state}
  end
end
