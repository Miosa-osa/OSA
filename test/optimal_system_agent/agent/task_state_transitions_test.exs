defmodule OptimalSystemAgent.Agent.TaskStateTransitionsTest do
  @moduledoc """
  Task state can only move forward.

  `TaskTracker` used to permit ANY status transition, so `complete_task` after
  `fail_task` flipped a failed task green, emitted `task_completed` to the TUI,
  persisted it, and unblocked its dependents via `dependencies_met?/2`.
  Duplicate completes are trivially reachable through model todo updates and
  tool retries.

  `Workflow.advance/2` took no expected-step token, so a duplicated advance
  (tool retry, redelivered event, two callers) advanced twice: step N got
  caller A's result and step N+1 was marked completed with caller B's result
  and NEVER RAN. The same held for `complete_step` and `skip_step`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TaskTracker
  alias OptimalSystemAgent.Agent.Workflow

  # TaskTracker persists per session id and `ensure_session/2` reloads it from
  # disk, so a session id that repeats across VM runs picks up the PREVIOUS
  # run's tasks. Randomize it.
  defp unique_session do
    "sess-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}-" <>
      Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end

  describe "TaskTracker settled tasks stay settled" do
    setup do
      server = :"tracker_#{System.unique_integer([:positive])}"
      {:ok, pid} = TaskTracker.start_link(name: server)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, server: server, session: unique_session()}
    end

    defp only_task(server, session) do
      [task] = TaskTracker.get_tasks(session, server)
      task
    end

    test "complete_task after fail_task does not flip the task green", ctx do
      {:ok, id} = TaskTracker.add_task(ctx.session, "do the thing", ctx.server)
      :ok = TaskTracker.fail_task(ctx.session, id, "blew up", ctx.server)
      assert only_task(ctx.server, ctx.session).status == :failed

      assert {:error, {:invalid_transition, :failed, :completed}} =
               TaskTracker.complete_task(ctx.session, id, ctx.server)

      assert only_task(ctx.server, ctx.session).status == :failed
    end

    test "fail_task after complete_task does not reopen a finished task", ctx do
      {:ok, id} = TaskTracker.add_task(ctx.session, "do the thing", ctx.server)
      :ok = TaskTracker.complete_task(ctx.session, id, ctx.server)

      assert {:error, {:invalid_transition, :completed, :failed}} =
               TaskTracker.fail_task(ctx.session, id, "late failure", ctx.server)

      assert only_task(ctx.server, ctx.session).status == :completed
    end

    test "a duplicate complete is a harmless no-op, not a second completion", ctx do
      {:ok, id} = TaskTracker.add_task(ctx.session, "do the thing", ctx.server)
      :ok = TaskTracker.complete_task(ctx.session, id, ctx.server)
      first = only_task(ctx.server, ctx.session).completed_at

      assert :ok = TaskTracker.complete_task(ctx.session, id, ctx.server)
      assert only_task(ctx.server, ctx.session).completed_at == first
    end

    test "start_task on a settled task is refused", ctx do
      {:ok, id} = TaskTracker.add_task(ctx.session, "do the thing", ctx.server)
      :ok = TaskTracker.complete_task(ctx.session, id, ctx.server)

      assert {:error, {:invalid_transition, :completed, :in_progress}} =
               TaskTracker.start_task(ctx.session, id, ctx.server)
    end
  end

  describe "Workflow step advance is conditional on the caller's step token" do
    setup do
      # Workflow is a named singleton; start it if the app has not.
      pid =
        case Process.whereis(Workflow) do
          nil ->
            {:ok, pid} = Workflow.start_link([])
            pid

          pid ->
            pid
        end

      tmpl =
        Path.join(
          System.tmp_dir!(),
          "osa_wf_#{System.unique_integer([:positive])}.json"
        )

      File.write!(
        tmpl,
        Jason.encode!(%{
          "steps" => [
            %{"name" => "one", "description" => "first"},
            %{"name" => "two", "description" => "second"},
            %{"name" => "three", "description" => "third"}
          ]
        })
      )

      on_exit(fn -> File.rm(tmpl) end)

      {:ok, wf} =
        Workflow.create("build it", unique_session(), template: tmpl)

      {:ok, wf_id: wf["id"], pid: pid}
    end

    test "a duplicated advance with a stale step token is refused", %{wf_id: id} do
      assert {:ok, after_first} = Workflow.advance(id, "result-A", expected_step: 0)
      assert after_first["current_step"] == 1

      # Caller B replays the same advance (tool retry / redelivered event).
      assert {:error, {:step_conflict, 0, 1}} = Workflow.advance(id, "result-B", expected_step: 0)

      # `status/1` reports the CURRENT step as a {name, status} map.
      assert {:ok, status} = Workflow.status(id)

      assert status.current_step.name == "two",
             "a replayed advance consumed step 2 without ever running it"

      # Step 2 is still in flight, NOT completed with B's result.
      refute status.current_step.status == :completed
      assert status.completed_steps == 1
    end

    test "a duplicated complete_step with a stale token is refused", %{wf_id: id} do
      assert {:ok, _} = Workflow.complete_step(id, "result-A", expected_step: 0)
      assert {:ok, _} = Workflow.advance(id, "result-A", expected_step: 0)

      assert {:error, {:step_conflict, 0, 1}} =
               Workflow.complete_step(id, "result-B", expected_step: 0)
    end

    test "a duplicated skip_step with a stale token is refused", %{wf_id: id} do
      assert {:ok, _} = Workflow.skip_step(id, "not needed", expected_step: 0)
      assert {:error, {:step_conflict, 0, 1}} = Workflow.skip_step(id, "again", expected_step: 0)
    end

    test "a matching token still advances normally", %{wf_id: id} do
      assert {:ok, _} = Workflow.advance(id, "a", expected_step: 0)
      assert {:ok, w} = Workflow.advance(id, "b", expected_step: 1)
      assert w["current_step"] == 2
    end
  end
end
