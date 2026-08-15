defmodule OptimalSystemAgent.Agent.Loop.PermissionWireContractTest do
  @moduledoc """
  WS1 regression — pins the TUI→backend permission wire contract. The Rust
  dialog (app/handle_dialogs.rs) POSTs `%{\"decision\" => <string>, \"note\" =>
  ...}` to /permissions/respond; these exact strings must keep mapping to the
  canonical decision atoms, and unknown strings must fail closed to :deny.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.PermissionBroker

  defp roundtrip(payload) do
    id = PermissionBroker.new_request_id()
    :ok = PermissionBroker.respond(id, payload)
    # `attended: true`: `await/3` refuses to park a session nobody can answer
    # on (`Agent.Attendance`), and this synthetic id has no channel. What is
    # under test here is decision-string normalisation, not attendance.
    {:ok, decision} =
      PermissionBroker.await("wire-test", id, timeout: 1_000, attended: true)

    decision
  end

  test "TUI canonical decision strings map to the right atoms" do
    assert %{decision: :allow_once} = roundtrip(%{"decision" => "allow_once", "note" => nil})

    assert %{decision: :allow_session} =
             roundtrip(%{"decision" => "allow_session", "note" => nil})

    assert %{decision: :allow_always} = roundtrip(%{"decision" => "allow_always", "note" => nil})
    assert %{decision: :deny} = roundtrip(%{"decision" => "deny", "note" => nil})
  end

  test "clarify carries the steer note through" do
    assert %{decision: :clarify, note: "use --dry-run"} =
             roundtrip(%{"decision" => "clarify", "note" => "use --dry-run"})
  end

  test "aliases still normalize (mixed-version compatibility)" do
    assert %{decision: :allow_once} = roundtrip(%{"decision" => "yes", "note" => nil})
    assert %{decision: :deny} = roundtrip(%{"decision" => "no", "note" => nil})
    assert %{decision: :allow_session} = roundtrip(%{"decision" => "session", "note" => nil})
    assert %{decision: :deny_always} = roundtrip(%{"decision" => "never", "note" => nil})
  end

  test "unknown decision strings fail closed to deny" do
    assert %{decision: :deny} = roundtrip(%{"decision" => "banana", "note" => nil})
  end
end
