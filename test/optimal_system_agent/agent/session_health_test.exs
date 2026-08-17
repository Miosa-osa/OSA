defmodule OptimalSystemAgent.Agent.SessionHealthTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.{ActiveSkills, SessionHealth, SessionPersistence}

  setup do
    session_id = "session-health-#{System.unique_integer([:positive])}"
    on_exit(fn -> SessionPersistence.delete(session_id) end)
    %{session_id: session_id}
  end

  test "distinguishes a missing session from a durable recoverable session", %{session_id: sid} do
    assert %{status: :missing, recovery_action: "start_new_session"} =
             SessionHealth.snapshot(sid)

    assert :ok =
             SessionPersistence.save(sid, [%{role: "user", content: "recover me"}], File.cwd!())

    assert :ok = ActiveSkills.select(sid, "diagnosing-bugs")

    assert %{
             status: :recoverable,
             live: false,
             recovery_action: "resume_session",
             persistence: %{status: :ok, restorable: true, message_count: 1},
             active_skills: %{status: :ok, count: 1, names: ["diagnosing-bugs"], versioned: 1}
           } = SessionHealth.snapshot(sid)
  end
end
