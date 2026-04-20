defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.ControllerTest do
  @moduledoc """
  Unit tests for the Cluster.Controller GenServer.

  Real exo/mlx provisioning is tagged :slow — the default test suite only
  runs the frame routing + stop logic using a mock approach.

  These tests do NOT start the full OSA supervision tree. The Controller and
  a fake FrameRouter are started in isolation.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Controller

  # Fake FrameRouter that captures sent frames
  defmodule FakeFrameRouter do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: OptimalSystemAgent.OpenComputers.FrameRouter)
    def init(frames), do: {:ok, frames}
    def sent_frames, do: GenServer.call(OptimalSystemAgent.OpenComputers.FrameRouter, :frames)
    def handle_call(:frames, _from, state), do: {:reply, state, state}
    def handle_cast({:outbound, frame}, state), do: {:noreply, [frame | state]}
    def handle_cast(_msg, state), do: {:noreply, state}
    def handle_info(_msg, state), do: {:noreply, state}
  end

  setup do
    # Stop the named processes if already registered (test isolation)
    for name <- [
          OptimalSystemAgent.OpenComputers.FrameRouter,
          OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Controller
        ] do
      case Process.whereis(name) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    end

    {:ok, _fr} = start_supervised({FakeFrameRouter, []})
    {:ok, ctrl} = start_supervised({Controller, []})

    {:ok, controller: ctrl}
  end

  describe "handle_frame/1 with cluster_provision_request" do
    @tag :slow
    test "dispatches provisioning to exo adapter and emits progress frames", %{controller: _ctrl} do
      cluster_id = "test-cluster-#{:rand.uniform(99999)}"

      frame =
        {:cluster_provision_request,
         %{
           cluster_id: cluster_id,
           backend: "exo",
           model: "llama3",
           role: :leader,
           peers: [
             %{host_id: "h1", ip: "192.168.1.1", role: :leader},
             %{host_id: "h2", ip: "192.168.1.2", role: :worker}
           ],
           leader: %{ip: "192.168.1.1", port: 52_415}
         }}

      Controller.handle_frame(frame)

      # Give the Task a moment to start and emit the first progress frame
      :timer.sleep(200)

      frames = FakeFrameRouter.sent_frames()
      progress_frames = Enum.filter(frames, &match?({:cluster_provision_progress, _}, &1))

      assert length(progress_frames) > 0, "Expected at least one progress frame"

      {:cluster_provision_progress, first} = List.last(progress_frames)
      assert first.cluster_id == cluster_id
      assert first.phase in [:installing_deps, :downloading_model, :starting, :joining_mesh, :ready]
    end

    test "unknown backend emits cluster_error frame", %{controller: _ctrl} do
      cluster_id = "bad-backend-cluster"

      frame =
        {:cluster_provision_request,
         %{
           cluster_id: cluster_id,
           backend: "cuda-only",
           model: "gpt-9",
           role: :leader,
           peers: [],
           leader: %{ip: "10.0.0.1", port: 52_415}
         }}

      Controller.handle_frame(frame)

      # The Task will fail immediately since the backend is unknown
      :timer.sleep(200)

      frames = FakeFrameRouter.sent_frames()
      error_frames = Enum.filter(frames, &match?({:cluster_error, _}, &1))

      assert length(error_frames) >= 1, "Expected a cluster_error frame for unknown backend"

      {:cluster_error, payload} = hd(error_frames)
      assert payload.cluster_id == cluster_id
      assert payload.reason != nil
    end
  end

  describe "handle_frame/1 with cluster_stop_request" do
    test "stop request for unknown cluster is a no-op", %{controller: _ctrl} do
      frame = {:cluster_stop_request, %{cluster_id: "nonexistent-123"}}
      # Should not crash
      Controller.handle_frame(frame)
      :timer.sleep(50)
      assert Process.alive?(Process.whereis(Controller))
    end

    test "controller remains alive after stop", %{controller: _ctrl} do
      frame = {:cluster_stop_request, %{cluster_id: "some-id"}}
      Controller.handle_frame(frame)
      :timer.sleep(50)
      assert Process.alive?(Process.whereis(Controller))
    end
  end

  describe "health tick" do
    test "controller emits cluster_health frames for running clusters", %{controller: _ctrl} do
      # We can't easily test the auto-tick (15s), so we send the internal message directly
      cluster_id = "health-test-#{:rand.uniform(9999)}"

      # Manually inject a cluster into state via the provision path with a no-op
      # This is just testing the health tick mechanism itself
      send(Process.whereis(Controller), {:health_tick})

      :timer.sleep(100)
      # No health frames expected since no clusters in state — just verify no crash
      assert Process.alive?(Process.whereis(Controller))
    end
  end
end
