defmodule OptimalSystemAgent.Verification.UpstreamVerifierTest do
  @moduledoc """
  `UpstreamVerifier` gates dependent tasks, so every one of its failure modes
  releases work that was supposed to be held back — or holds it forever.

    * `build_checks/1` read STRING keys only and started from `[]`, so an
      atom-keyed or mistyped criteria map produced no checks at all and
      `failures == []` reported `:passed` VACUOUSLY.
    * The ETS row was keyed on `task_id` alone with no run token, so a slow
      first attempt landed its stale `{:failed, …}` on top of a retry's
      `:passed`.
    * Nothing monitored the verifying process, so a killed `Task` left the row
      `:pending` and every `block_until_passed/2` burned its full timeout.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Verification.UpstreamVerifier

  setup do
    UpstreamVerifier.init_table()
    task_id = "task-#{System.unique_integer([:positive])}"
    on_exit(fn -> UpstreamVerifier.clear(task_id) end)
    {:ok, task_id: task_id}
  end

  describe "check construction" do
    test "criteria that specify no runnable check do not pass vacuously", ctx do
      assert {:failed, %{failures: failures}} =
               UpstreamVerifier.verify(ctx.task_id, %{"tset_command" => "true"})

      assert [%{check: :criteria}] = failures
      assert match?({:failed, _}, UpstreamVerifier.status(ctx.task_id))
    end

    test "atom-keyed criteria are honoured", ctx do
      assert :passed = UpstreamVerifier.verify(ctx.task_id, %{test_command: "true"})
      assert UpstreamVerifier.status(ctx.task_id) == :passed
    end

    test "atom-keyed criteria can still fail", ctx do
      assert {:failed, _} = UpstreamVerifier.verify(ctx.task_id, %{test_command: "exit 3"})
    end

    test "a genuinely empty criteria map is an explicit no-op and passes", ctx do
      assert :passed = UpstreamVerifier.verify(ctx.task_id, %{})
    end
  end

  describe "concurrent attempts" do
    test "a slow earlier attempt does not overwrite a later attempt's verdict", ctx do
      slow =
        Task.async(fn ->
          UpstreamVerifier.verify(ctx.task_id, %{"test_command" => "sleep 1; exit 1"})
        end)

      # Let the slow attempt claim :pending first.
      Process.sleep(100)

      # A retry supersedes it and passes.
      assert :passed = UpstreamVerifier.verify(ctx.task_id, %{"test_command" => "true"})
      assert UpstreamVerifier.status(ctx.task_id) == :passed

      assert {:failed, _} = Task.await(slow, 5_000)

      assert UpstreamVerifier.status(ctx.task_id) == :passed,
             "a superseded attempt's stale verdict overwrote the current one"
    end
  end

  describe "verifier death" do
    test "a killed verifier resolves the row instead of leaving it :pending", ctx do
      # Deliberately unlinked: the point is that the verifier dies, and a linked
      # Task would take the test process with it.
      verifier =
        spawn(fn ->
          UpstreamVerifier.verify(ctx.task_id, %{"test_command" => "sleep 5"})
        end)

      Process.sleep(150)
      assert UpstreamVerifier.status(ctx.task_id) == :pending

      Process.exit(verifier, :kill)

      assert eventually(fn -> match?({:failed, _}, UpstreamVerifier.status(ctx.task_id)) end),
             "row stayed :pending after the verifier died — every dependent would poll to the deadline"

      # And a dependent blocking on it returns immediately rather than sleeping
      # out its timeout.
      started = System.monotonic_time(:millisecond)
      assert {:failed, _} = UpstreamVerifier.block_until_passed(ctx.task_id, 5_000)
      assert System.monotonic_time(:millisecond) - started < 1_000
    end
  end

  defp eventually(fun, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
