defmodule OptimalSystemAgent.Healing.OrchestratorTest do
  @moduledoc """
  Regressions for the four data-losing defects in the self-healing orchestrator.

  All four share a shape: the orchestrator is a singleton that owns
  `:osa_healing_sessions`, the ONLY record of every in-flight healing session,
  and the suspended agent loops it is supposed to wake are blocked on a message
  only it will ever send. Anything that kills it, or makes it forget a session,
  strands those loops permanently.

    1. It links to its ephemeral agents but did not trap exits — an ephemeral
       crash killed it, dropped the table, and skipped `terminate/2`.
    2. It looked for the suspended agent's pid at
       `session.classification[:agent_pid]`, a key `handle_call/3` never puts
       there, so the wake message was never sent to anyone.
    3. Retry fed `Session.transition/2` an illegal `:diagnosing -> :diagnosing`
       move against a `{:ok, _} =` match — a MatchError inside the orchestrator.
    4. The 500-row history cap evicted by insertion recency with no terminal
       check, so a session still `:diagnosing` could be deleted mid-flight.

  The ephemeral agent is stubbed throughout: the real one issues a live provider
  request, which would make these tests slow, non-deterministic and billable.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Healing.Orchestrator
  alias OptimalSystemAgent.Healing.Session
  alias OptimalSystemAgent.Infra.BoundedTable

  @table :osa_healing_sessions

  # ── Stub ephemerals ──────────────────────────────────────────────────
  #
  # Same contract as Healing.EphemeralAgent: started with `start_link/1`, sends
  # one message back to `:parent_pid`, includes `self()` so the orchestrator can
  # route it. Behaviour is chosen by `context[:stub_behaviour]`.

  defmodule StubEphemeral do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      state = %{
        role: Keyword.fetch!(opts, :role),
        parent_pid: Keyword.fetch!(opts, :parent_pid),
        behaviour: opts |> Keyword.fetch!(:context) |> Map.get(:stub_behaviour, :error),
        observer: opts |> Keyword.fetch!(:context) |> Map.get(:stub_observer)
      }

      if is_pid(state.observer),
        do: send(state.observer, {:ephemeral_started, state.role, self()})

      {:ok, state, {:continue, :run}}
    end

    @impl true
    def handle_continue(:run, %{behaviour: :never_answers} = state) do
      # Stays alive until something stops it — stands in for a fixer still
      # writing into the working tree.
      {:noreply, state}
    end

    def handle_continue(:run, %{behaviour: :crash}) do
      exit(:stub_crash)
    end

    def handle_continue(:run, state) do
      send(state.parent_pid, {:ephemeral_error, self(), state.role, :stub_failure})
      {:stop, :normal, state}
    end

    @impl true
    def terminate(_reason, state) do
      if is_pid(state.observer), do: send(state.observer, {:ephemeral_stopped, state.role})
      :ok
    end
  end

  setup do
    assert is_pid(Process.whereis(Orchestrator)), "Healing.Orchestrator is not running"

    previous = Application.get_env(:optimal_system_agent, :healing_ephemeral_module)
    Application.put_env(:optimal_system_agent, :healing_ephemeral_module, StubEphemeral)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :healing_ephemeral_module, previous)
      else
        Application.delete_env(:optimal_system_agent, :healing_ephemeral_module)
      end
    end)

    :ok
  end

  defp agent_id, do: "agent-#{System.unique_integer([:positive])}"

  describe "crash isolation" do
    test "an abnormal exit from a LINKED process does not kill the orchestrator" do
      pid = Process.whereis(Orchestrator)
      ref = Process.monitor(pid)

      # Exactly the signal path an ephemeral takes: the orchestrator starts them
      # with `start_link/1`, so they are linked and an abnormal exit propagates
      # over that link.
      spawn(fn ->
        Process.link(pid)
        exit(:ephemeral_boom)
      end)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 300
      assert Process.alive?(pid)
      assert :ets.info(@table, :size) != :undefined
    end

    test "an ephemeral that crashes outright leaves the orchestrator and its table intact" do
      pid = Process.whereis(Orchestrator)
      ref = Process.monitor(pid)

      {:ok, session_id} =
        Orchestrator.request_healing(agent_id(), {:error, :boom}, %{
          agent_pid: self(),
          max_attempts: 1,
          stub_behaviour: :crash
        })

      assert_receive {:healing_failed, _reason}, 2_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Process.alive?(pid)
      assert {:ok, _session} = Orchestrator.get_session(session_id)
    end
  end

  describe "waking the suspended agent" do
    test "the requesting process is notified when healing cannot complete" do
      {:ok, session_id} =
        Orchestrator.request_healing(agent_id(), {:error, :boom}, %{
          agent_pid: self(),
          max_attempts: 1
        })

      assert_receive {:healing_failed, _reason}, 2_000

      assert {:ok, session} = Orchestrator.get_session(session_id)
      assert session.agent_pid == self()
    end

    test "retrying does not crash the orchestrator and still notifies the agent" do
      pid = Process.whereis(Orchestrator)
      ref = Process.monitor(pid)

      {:ok, _session_id} =
        Orchestrator.request_healing(agent_id(), {:error, :boom}, %{
          agent_pid: self(),
          max_attempts: 3
        })

      # Every attempt fails, so this walks the retry path twice before escalating.
      assert_receive {:healing_failed, _reason}, 5_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Process.alive?(pid)
    end
  end

  describe "ephemeral cleanup" do
    test "a stalled ephemeral is stopped before the next attempt starts" do
      {:ok, _session_id} =
        Orchestrator.request_healing(agent_id(), {:error, :boom}, %{
          agent_pid: self(),
          max_attempts: 2,
          stub_behaviour: :never_answers,
          stub_observer: self()
        })

      assert_receive {:ephemeral_started, :diagnostician, first_pid}, 2_000

      # Force the phase to fail while the ephemeral is still running.
      send(Process.whereis(Orchestrator), {:ephemeral_error, first_pid, :diagnostician, :stalled})

      assert_receive {:ephemeral_started, :diagnostician, second_pid}, 2_000
      assert second_pid != first_pid

      # The first one must not still be running alongside the second: a fixer
      # writes into the user's working tree.
      refute Process.alive?(first_pid)

      Process.exit(second_pid, :kill)
    end
  end

  describe "history cap" do
    test "the row cap never evicts a session that is still in flight" do
      max_rows = 500

      live = %{
        Session.new("live-agent", %{category: :unknown, severity: :high, retryable: true},
          agent_pid: self()
        )
        | status: :diagnosing
      }

      # Oldest row in the table, and still working.
      BoundedTable.insert(@table, live.id, live, max: 0)

      # Fill past the cap with finished history.
      for _ <- 1..(max_rows + 2) do
        done = %{
          Session.new("done-agent", %{category: :unknown, severity: :low, retryable: false})
          | status: :completed,
            completed_at: DateTime.utc_now()
        }

        BoundedTable.insert(@table, done.id, done, max: 0)
      end

      # Any real write goes through the orchestrator's own store/1, which is
      # what enforces the cap.
      {:ok, _} =
        Orchestrator.request_healing(agent_id(), {:error, :boom}, %{
          agent_pid: self(),
          max_attempts: 1
        })

      assert :ets.info(@table, :size) <= max_rows
      assert {:ok, still_there} = Orchestrator.get_session(live.id)
      assert still_there.status == :diagnosing

      BoundedTable.delete(@table, live.id)
      assert_receive {:healing_failed, _}, 2_000
    end
  end
end
