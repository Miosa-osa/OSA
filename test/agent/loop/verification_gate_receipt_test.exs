defmodule OptimalSystemAgent.Agent.Loop.VerificationGateReceiptTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Agent.Loop.VerificationGate

  defp sid, do: "vg-receipt-#{System.unique_integer([:positive])}"

  test "blocked_finish? is false when the gate can still re-prompt" do
    state = %{session_id: sid(), verification_gate_prompts: 0}
    refute VerificationGate.blocked_finish?(state, "done")
  end

  test "blocked_finish? is true after the cap with an unchecked write" do
    session = sid()
    path = Path.expand("/tmp/osa-vg-receipt-#{System.unique_integer([:positive])}.ex")
    VerificationEvidence.reset(session)

    VerificationEvidence.record(session, %{
      tool: "file_write",
      args: %{"path" => path},
      success: true
    })

    state = %{session_id: session, verification_gate_prompts: 1}

    assert VerificationGate.blocked_finish?(state, "All done.")
    receipt = VerificationGate.finish_receipt(state, "All done.")
    assert receipt =~ "did not run a check"
    assert receipt =~ Path.basename(path)
    assert receipt =~ "All done."
  after
    # best-effort; unique session ids do not collide
    :ok
  end

  test "blocked_finish? is false with no session" do
    refute VerificationGate.blocked_finish?(%{}, "done")
  end

  test "failing_check receipt does not claim no check ran" do
    session = sid()
    path = Path.expand("/tmp/osa-vg-fail-#{System.unique_integer([:positive])}.ex")
    VerificationEvidence.reset(session)

    VerificationEvidence.record(session, %{
      tool: "file_write",
      args: %{"path" => path},
      success: true
    })

    VerificationEvidence.record(session, %{
      tool: "shell_execute",
      args: %{"command" => "mix test"},
      success: false
    })

    state = %{session_id: session, verification_gate_prompts: 1}
    assert VerificationGate.blocked_finish?(state, "All done.")
    receipt = VerificationGate.finish_receipt(state, "All done.")
    assert receipt =~ "Checks are still failing"
    refute receipt =~ "did not run a check"
  end
end
