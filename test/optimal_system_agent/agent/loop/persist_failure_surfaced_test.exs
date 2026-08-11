defmodule OptimalSystemAgent.Agent.Loop.PersistFailureSurfacedTest do
  @moduledoc """
  Defect 1 — a failed durable session save was DISCARDED.

  `handle_cast({:persist_session, _}, state)` used to read:

      _ = SessionPersistence.save_from_state(session_id, state)

  So a full disk / read-only config dir / encode failure produced exactly one
  `Logger.warning` from deep inside `SessionPersistence`, the assistant's reply
  was delivered as normal, and the turn was never written to disk. The user
  believes the conversation is saved; it evaporates at the next restart.

  The failure must be SURFACED on the same typed `:system_event` + session
  PubSub pair every other turn-level fault uses.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.SessionPersistence

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_persist_fail_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    # A REGULAR FILE standing where the config directory is expected.
    # `SessionPersistence.sessions_dir/0` is `<config_dir>/sessions`, so
    # `File.mkdir_p!` fails with :enotdir — the same observable shape as a full
    # or read-only disk, fully deterministic and requiring no privileges.
    blocked = Path.join(tmp, "not-a-directory")
    File.write!(blocked, "")

    prev_config_dir = Application.get_env(:optimal_system_agent, :config_dir)

    on_exit(fn ->
      case prev_config_dir do
        nil -> Application.delete_env(:optimal_system_agent, :config_dir)
        v -> Application.put_env(:optimal_system_agent, :config_dir, v)
      end

      File.rm_rf(tmp)
    end)

    {:ok,
     session: "persist-fail-#{System.unique_integer([:positive])}",
     blocked: blocked,
     prev_config_dir: prev_config_dir}
  end

  defp break_persistence(blocked) do
    Application.put_env(:optimal_system_agent, :config_dir, blocked)
  end

  defp restore_persistence(prev) do
    case prev do
      nil -> Application.delete_env(:optimal_system_agent, :config_dir)
      v -> Application.put_env(:optimal_system_agent, :config_dir, v)
    end
  end

  defp start_loop(session) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: session, channel: :test}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  test "precondition: the simulated disk failure really does fail the save", %{
    session: session,
    blocked: blocked,
    prev_config_dir: prev
  } do
    break_persistence(blocked)

    assert {:error, _reason} =
             SessionPersistence.save_from_state(session, %{
               messages: [%{role: "user", content: "hello"}],
               working_dir: nil
             })

    restore_persistence(prev)
  end

  test "a persistence failure is surfaced on the session event stream, not swallowed", %{
    session: session,
    blocked: blocked,
    prev_config_dir: prev
  } do
    pid = start_loop(session)

    :sys.replace_state(pid, fn state ->
      %{state | messages: [%{role: "user", content: "work i must not lose"}]}
    end)

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

    break_persistence(blocked)
    GenServer.cast(pid, {:persist_session, session})

    assert_receive {:osa_event,
                    %{
                      type: :system_event,
                      event: :session_persist_failed,
                      session_id: ^session,
                      message: message
                    }},
                   5_000

    assert message =~ "FAILED"

    restore_persistence(prev)

    # The loop must survive the failure — surfacing is not crashing.
    assert Process.alive?(pid)
  end

  test "a SUCCESSFUL save emits no failure event", %{session: session} do
    pid = start_loop(session)

    :sys.replace_state(pid, fn state ->
      %{state | messages: [%{role: "user", content: "this one saves fine"}]}
    end)

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

    GenServer.cast(pid, {:persist_session, session})

    refute_receive {:osa_event, %{event: :session_persist_failed}}, 1_000

    # And the transcript really is on disk.
    assert {:ok, loaded} = SessionPersistence.load(session)

    assert Enum.any?(loaded, fn m ->
             Map.get(m, :content) == "this one saves fine" or
               Map.get(m, "content") == "this one saves fine"
           end)
  end
end
