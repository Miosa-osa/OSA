defmodule OptimalSystemAgent.Intelligence.ProactiveMonitor do
  @moduledoc """
  Scans for actionable patterns every N minutes:
  - Silence: contact hasn't responded in X days
  - Drift: conversation moving away from objective
  - Engagement drops: reduced message frequency
  - Follow-up needed: commitments made but not fulfilled

  This is the L3+ proactive behavior that differentiates
  premium from free agents.

  Signal Theory — autonomous pattern detection and intervention.
  """
  use GenServer

  @interval Application.compile_env(:optimal_system_agent, :proactive_interval, 30 * 60 * 1000)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_scan()
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    # TODO: Implement proactive scanning
    schedule_scan()
    {:noreply, state}
  end

  defp schedule_scan, do: Process.send_after(self(), :scan, @interval)
end
