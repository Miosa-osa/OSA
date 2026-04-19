defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop do
  @moduledoc """
  Executor for `:stream_native_desktop` — opens a desktop stream session
  to the host OS.

  Phase 2 work. Will start a platform-appropriate desktop source:

    * Linux   — x11vnc attached to the existing X session
    * macOS   — ScreenCaptureKit → RFB frames via a helper bundle
    * Windows — Windows Desktop Duplication API → RFB

  Then open a secondary WSS to `/opencomputers/hosts/ws-proxy` with the
  `relay_token` from the job payload and pipe frames through it.
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
           "Direct.Desktop — x11vnc / ScreenCaptureKit / Desktop Duplication pending (Phase 2)"
       }}
    )

    {:stop, :normal, state}
  end
end
