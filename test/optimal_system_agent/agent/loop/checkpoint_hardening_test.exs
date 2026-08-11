defmodule OptimalSystemAgent.Agent.Loop.CheckpointHardeningTest do
  @moduledoc """
  Regression tests for defensive hardening of Loop.Checkpoint:

    * restore_checkpoint/1 must tolerate malformed on-disk data (non-map message
      elements, a non-list "messages" value) instead of raising into the blanket
      rescue and silently dropping the ENTIRE conversation. (findings 16, 20)
    * checkpoint_state/1 must write atomically (write temp + rename) so a crash
      never leaves a torn file. (finding 17)
    * prune_rewind/2 must retain the NEWEST checkpoints by parsed numeric
      timestamp, not by lexical filename sort. (finding 23)
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_ckpt_hard_#{System.unique_integer([:positive])}")
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

    {:ok, crash: crash, rewind: rewind, session: "sess_#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp crash_path(crash, session), do: Path.join(crash, "#{session}.json")

  describe "restore_checkpoint/1 tolerance (findings 16, 20)" do
    test "a non-map message element does not nuke the whole history", %{
      crash: crash,
      session: session
    } do
      # One good turn, one corrupt (bare string) element.
      json =
        Jason.encode!(%{
          "messages" => [%{"role" => "user", "content" => "hi"}, "corrupt-non-map"],
          "iteration" => 3
        })

      File.write!(crash_path(crash, session), json)

      restored = Checkpoint.restore_checkpoint(session)

      # Pre-fix this returned %{} (FunctionClauseError swallowed by rescue).
      assert restored != %{}
      assert restored.iteration == 3
      assert Enum.any?(restored.messages, &(is_map(&1) and &1[:role] == "user"))
      assert Enum.any?(restored.messages, &(&1 == "corrupt-non-map"))
    end

    test "a non-list messages value degrades to empty instead of crashing", %{
      crash: crash,
      session: session
    } do
      File.write!(
        crash_path(crash, session),
        Jason.encode!(%{"messages" => %{"not" => "a list"}})
      )

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.messages == []
    end

    test "an unknown key is kept as a string rather than exhausting the atom table", %{
      crash: crash,
      session: session
    } do
      novel = "totally_novel_key_#{System.unique_integer([:positive])}"

      File.write!(
        crash_path(crash, session),
        Jason.encode!(%{"messages" => [%{"role" => "user", novel => "x"}]})
      )

      restored = Checkpoint.restore_checkpoint(session)
      [msg] = restored.messages
      # Known keys atomize; the novel one stays a string key (to_existing_atom fallback).
      assert msg[:role] == "user"
      assert Map.get(msg, novel) == "x"
    end
  end

  describe "checkpoint_state/1 atomic write (finding 17)" do
    test "writes a valid file and leaves no .tmp behind", %{crash: crash, session: session} do
      state = %{
        session_id: session,
        messages: [%{role: "user", content: "hello"}],
        iteration: 1,
        plan_mode: false,
        turn_count: 1
      }

      Checkpoint.checkpoint_state(state)

      path = crash_path(crash, session)
      assert File.exists?(path)
      refute File.exists?(path <> ".tmp")

      # Round-trips cleanly.
      restored = Checkpoint.restore_checkpoint(session)
      assert restored.iteration == 1
    end
  end

  describe "prune_rewind/2 numeric ordering (finding 23)" do
    test "retains the newest by numeric timestamp across digit widths", %{
      session: session
    } do
      dir = Checkpoint.rewind_session_dir(session)
      File.mkdir_p!(dir)

      # Mixed digit widths: 999 (older) vs 1000000000000 (newer). Lexically "999"
      # sorts AFTER "1000000000000" (desc), so a lexical prune would wrongly keep
      # the older 999 and drop a newer one.
      names = ["999_aaa.json", "1000000000000_bbb.json", "1000000000001_ccc.json"]

      Enum.each(names, fn n ->
        File.write!(Path.join(dir, n), Jason.encode!(%{"messages" => []}))
      end)

      Checkpoint.prune_rewind(session, 2)

      remaining = File.ls!(dir) |> Enum.sort()
      # The two newest (by numeric millis) survive; the oldest (999) is pruned.
      assert "1000000000000_bbb.json" in remaining
      assert "1000000000001_ccc.json" in remaining
      refute "999_aaa.json" in remaining
    end
  end
end
