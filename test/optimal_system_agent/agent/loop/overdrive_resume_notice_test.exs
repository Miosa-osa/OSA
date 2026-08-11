defmodule OptimalSystemAgent.Agent.Loop.OverdriveResumeNoticeTest do
  @moduledoc """
  Regression coverage for the crash/new-process overdrive-resume finding
  (bug hunt finding #5 / M4): `PermissionMode` is disk-persisted so a fresh
  process rehydrates a sticky `:overdrive`/`:bypass` mode with no
  re-confirmation. That durability is intentional (see the `PermissionMode`
  moduledoc), but a session RESUMED (prior checkpoint/history exists) into
  overdrive on a brand-new process must surface a clear notice instead of
  silently auto-approving every mutating tool with the operator unaware.

  A genuinely NEW session that simply happens to start in overdrive (no
  prior history — the operator just toggled it for this session) is not a
  "resume" and must NOT get the notice on every turn-1 start.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.PermissionMode

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_od_resume_#{System.unique_integer([:positive])}")
    crash = Path.join(tmp, "crash")
    rewind = Path.join(tmp, "rewind")
    File.mkdir_p!(crash)
    File.mkdir_p!(rewind)

    prev_crash = Application.get_env(:optimal_system_agent, :checkpoint_dir)
    prev_rewind = Application.get_env(:optimal_system_agent, :rewind_checkpoint_dir)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, crash)
    Application.put_env(:optimal_system_agent, :rewind_checkpoint_dir, rewind)

    on_exit(fn ->
      restore_env(:checkpoint_dir, prev_crash)
      restore_env(:rewind_checkpoint_dir, prev_rewind)
      File.rm_rf(tmp)
    end)

    {:ok, crash: crash, session: "od-resume-#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp write_crash_checkpoint(crash, session) do
    json =
      Jason.encode!(%{
        "messages" => [
          %{"role" => "user", "content" => "before the crash"},
          %{"role" => "assistant", "content" => "working on it"}
        ],
        "iteration" => 2
      })

    File.write!(Path.join(crash, "#{session}.json"), json)
  end

  defp start_loop(session) do
    DynamicSupervisor.start_child(
      OptimalSystemAgent.SessionSupervisor,
      {Loop, session_id: session, channel: :test}
    )
  end

  test "a fresh process resuming a session left in sticky overdrive gets a clear notice", %{
    crash: crash,
    session: session
  } do
    # Simulate the pre-crash state: overdrive was toggled on (disk-persisted,
    # sticky per the PermissionMode moduledoc) and a checkpoint exists from
    # an in-flight turn.
    PermissionMode.put(session, :overdrive)
    write_crash_checkpoint(crash, session)

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

    {:ok, pid} = start_loop(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert_receive {:osa_event,
                    %{
                      type: :system_event,
                      event: :overdrive_resumed,
                      session_id: ^session,
                      message: msg
                    }},
                   2_000

    assert msg =~ "overdrive"

    # The mode itself must still be honored (durability is not broken by the
    # notice) — this is a notification, not a re-confirmation gate.
    assert {:ok, :overdrive} = Loop.get_permission_mode(session)
  end

  test "a brand-new session starting in overdrive (no prior history) gets no resume notice", %{
    session: session
  } do
    PermissionMode.put(session, :overdrive)
    # No checkpoint written — nothing to resume.

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

    {:ok, pid} = start_loop(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    refute_receive {:osa_event, %{type: :system_event, event: :overdrive_resumed}}, 500
    assert {:ok, :overdrive} = Loop.get_permission_mode(session)
  end

  test "a resumed session in :ask mode (not overdrive) gets no overdrive notice", %{
    crash: crash,
    session: session
  } do
    write_crash_checkpoint(crash, session)
    # No PermissionMode.put — defaults to :ask.

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

    {:ok, pid} = start_loop(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    refute_receive {:osa_event, %{type: :system_event, event: :overdrive_resumed}}, 500
  end
end
