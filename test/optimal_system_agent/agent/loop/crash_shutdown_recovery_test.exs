defmodule OptimalSystemAgent.Agent.Loop.CrashShutdownRecoveryTest do
  @moduledoc """
  Defect 3 — history is lost when a Loop goes down mid-turn.

  Three compounding faults:

    1. Auto-save is registered on `:post_response` ONLY. A turn that never
       reached a response was never persisted.
    2. The `:normal` / `:shutdown` / `{:shutdown, _}` `terminate/2` clauses
       cleared `Checkpoint` and `DurableLog` unconditionally — deleting exactly
       the markers `init/1` reads back to restore an interrupted turn. A
       shutdown that landed MID-TURN threw the work away.
    3. Nothing set `trap_exit`, so on a supervisor shutdown `terminate/2` did
       not run at all: the session-end hook, the background-command reaping and
       the save were all dead code on the ordinary application-stop path.

  `trap_exit` changes shutdown semantics, so promptness is asserted here too:
  the fix must not turn a fast shutdown into a hanging one.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.SessionPersistence

  # Comfortably under the 5_000ms default worker shutdown budget — a terminate
  # that started blocking would blow this long before the supervisor's own
  # brutal-kill timer papered over it.
  @prompt_shutdown_ms 3_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_crash_rec_#{System.unique_integer([:positive])}")
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

    {:ok, crash: crash, session: "crash-rec-#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp checkpoint_path(crash, session), do: Path.join(crash, "#{session}.json")

  defp write_inflight_checkpoint(crash, session) do
    File.write!(
      checkpoint_path(crash, session),
      Jason.encode!(%{
        "messages" => [%{"role" => "user", "content" => "mid-turn work"}],
        "iteration" => 3
      })
    )
  end

  # An isolated supervisor so an abnormal child exit cannot trip the real
  # SessionSupervisor's restart intensity, and so `terminate_child/2` drives a
  # genuine OTP shutdown rather than a `GenServer.stop/2` system message (which
  # runs `terminate/2` even WITHOUT trap_exit, and would hide the defect).
  defp start_supervised_loop(session) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, pid} = DynamicSupervisor.start_child(sup, {Loop, session_id: session, channel: :test})
    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :normal) end)
    {sup, pid}
  end

  defp mark_in_flight(pid, content) do
    :sys.replace_state(pid, fn state ->
      %{state | status: :processing, messages: [%{role: "user", content: content}]}
    end)
  end

  defp await_down(pid, timeout) do
    ref = Process.monitor(pid)
    start = System.monotonic_time(:millisecond)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        System.monotonic_time(:millisecond) - start
    after
      timeout -> flunk("loop did not terminate within #{timeout}ms")
    end
  end

  describe "trap_exit — terminate/2 must run on a supervisor shutdown" do
    test "an IDLE loop shut down by its supervisor clears its recovery markers", %{
      crash: crash,
      session: session
    } do
      {sup, pid} = start_supervised_loop(session)

      # The loop is idle (never processed a turn). A stale checkpoint from an
      # earlier run is exactly what a clean shutdown is supposed to reap.
      write_inflight_checkpoint(crash, session)
      assert File.exists?(checkpoint_path(crash, session))

      :ok = DynamicSupervisor.terminate_child(sup, pid)
      await_down(pid, @prompt_shutdown_ms)

      refute File.exists?(checkpoint_path(crash, session)),
             "terminate/2 never ran — an untrapped :shutdown signal kills the process outright"
    end

    test "shutdown still completes promptly (trap_exit did not make it hang)", %{
      crash: crash,
      session: session
    } do
      {sup, pid} = start_supervised_loop(session)
      mark_in_flight(pid, "a turn that was still running at shutdown")
      write_inflight_checkpoint(crash, session)

      :ok = DynamicSupervisor.terminate_child(sup, pid)
      elapsed = await_down(pid, @prompt_shutdown_ms)

      assert elapsed < @prompt_shutdown_ms,
             "mid-turn shutdown took #{elapsed}ms — the save path must stay bounded"
    end
  end

  describe "recovery markers must not be cleared while a turn is in flight" do
    test "a shutdown landing MID-TURN preserves the checkpoint and saves the turn", %{
      crash: crash,
      session: session
    } do
      {sup, pid} = start_supervised_loop(session)
      mark_in_flight(pid, "work that must survive the shutdown")
      write_inflight_checkpoint(crash, session)

      :ok = DynamicSupervisor.terminate_child(sup, pid)
      await_down(pid, @prompt_shutdown_ms)

      assert File.exists?(checkpoint_path(crash, session)),
             "the crash-recovery marker init/1 restores from was deleted mid-turn"

      assert {:ok, saved} = SessionPersistence.load(session)

      assert Enum.any?(saved, &(text_of(&1) == "work that must survive the shutdown")),
             "the unfinished turn was never persisted: #{inspect(saved)}"
    end
  end

  describe "abnormal termination" do
    test "state is recoverable after an abnormal exit mid-turn", %{
      crash: crash,
      session: session
    } do
      {_sup, pid} = start_supervised_loop(session)
      mark_in_flight(pid, "the turn the crash interrupted")

      # No pre-written checkpoint: the point is that the DYING loop must record
      # its own state, not that an earlier marker happened to survive.
      refute File.exists?(checkpoint_path(crash, session))

      :ok = GenServer.stop(pid, :boom)
      await_down(pid, @prompt_shutdown_ms)

      restored = Checkpoint.restore_checkpoint(session)

      assert Enum.any?(Map.get(restored, :messages, []), fn m ->
               text_of(m) == "the turn the crash interrupted"
             end),
             "nothing was checkpointed on the abnormal exit: #{inspect(restored)}"

      # End-to-end: the supervisor's own (:transient) restart brings the session
      # back — and it must come back holding the interrupted turn, not amnesiac.
      pid2 = await_restart(session, pid, @prompt_shutdown_ms)
      messages = Loop.get_messages(session)

      assert Enum.any?(messages, &(text_of(&1) == "the turn the crash interrupted")),
             "a restarted loop did not recover the interrupted turn: #{inspect(messages)}"

      assert Process.alive?(pid2)
    end
  end

  # Poll until the supervisor has replaced the dead child under the same
  # session id (restart: :transient re-runs init/1, which is the restore path).
  defp await_restart(session, old_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_restart(session, old_pid, deadline)
  end

  defp do_await_restart(session, old_pid, deadline) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session) do
      [{pid, _}] when pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("supervisor never restarted the loop for #{session}")
        else
          Process.sleep(25)
          do_await_restart(session, old_pid, deadline)
        end
    end
  end

  defp text_of(msg) when is_map(msg), do: Map.get(msg, :content) || Map.get(msg, "content")
  defp text_of(_), do: nil
end
