defmodule OptimalSystemAgent.Verification.LoopNoopGateTest do
  @moduledoc """
  The verification loop used to re-run a failing `test_command` even when the
  "fix" between two iterations changed nothing on disk — which is every
  iteration where the model answered in prose, or where the permission gate
  refused each command it emitted. The result of the re-run is known in
  advance, and OSA has burned whole benchmark budgets proving it.

  Ported from Prime Agent's autonomous no-op detector (MIT), see
  `docs/research/prime-agent.md` §6.3.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Verification.Loop
  alias OptimalSystemAgent.Verification.WorkspaceFingerprint

  defp await_terminal(loop_id, deadline_ms \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await(loop_id, deadline)
  end

  defp do_await(loop_id, deadline) do
    case Loop.get_state(loop_id) do
      {:ok, %{status: status} = snap} when status != :running ->
        {:ok, snap}

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, other}
        else
          Process.sleep(25)
          do_await(loop_id, deadline)
        end
    end
  end

  test "a failing command in an unchanged workspace escalates instead of re-running" do
    OptimalSystemAgent.Test.VerificationGateHelper.allow_commands(["false"])

    loop_id = "noop_gate_#{System.unique_integer([:positive])}"

    # `false` always fails. There is no provider configured in test, so
    # `diagnose_and_fix/2` takes its `{:error, _}` branch: no fix is applied,
    # the workspace is therefore byte-identical, and iteration 2 must not run.
    {:ok, _pid} =
      Loop.start_link(
        loop_id: loop_id,
        test_command: "false",
        max_iterations: 5,
        timeout_ms: 30_000
      )

    assert {:ok, snap} = await_terminal(loop_id)
    assert snap.status == :escalated

    # The whole point of the gate, and the assertion that fails without it: the
    # loop stopped after ONE failure rather than spending all five iterations
    # re-proving it against a workspace no fix had touched.
    assert snap.iteration == 1
  end

  test "the gate cannot fire where the workspace cannot be fingerprinted" do
    # `unchanged?/2` is the only thing that can hold a re-run back, and it is
    # false whenever either side is `:unknown`. This is the false-positive
    # direction: a loop running outside a git repo must behave exactly as it
    # did before the gate existed.
    assert WorkspaceFingerprint.capture("/nonexistent/osa/path") == :unknown
    refute WorkspaceFingerprint.unchanged?(:unknown, :unknown)
  end
end
