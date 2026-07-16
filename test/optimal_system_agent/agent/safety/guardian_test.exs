defmodule OptimalSystemAgent.Agent.Safety.GuardianTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Safety.Guardian

  @table :osa_auto_mode

  setup do
    # Ensure the ETS table exists even if the full app didn't boot.
    unless :ets.whereis(@table) != :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    session_id = "test_session_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> Guardian.reset(session_id) end)
    {:ok, session_id: session_id}
  end

  defp state(session_id, allowlist \\ []) do
    %{
      session_id: session_id,
      permission_tier: :auto,
      untrusted_host_allowlist: allowlist
    }
  end

  defp tool(cmd, name \\ "shell_execute") do
    %{name: name, arguments: %{"command" => cmd}}
  end

  describe "review/2 verdict → enforcement mapping" do
    test "allows a safe tool call", %{session_id: sid} do
      assert Guardian.review(tool("ls -la"), state(sid)) == {:allow}
      assert Guardian.block_count(sid) == 0
    end

    test "allows a caution (untrusted network) tool call without blocking", %{session_id: sid} do
      result = Guardian.review(tool("curl https://evil.example.com/x"), state(sid, []))
      assert result == {:allow}
      assert Guardian.block_count(sid) == 0
    end

    test "blocks a dangerous tool call and increments the counter", %{session_id: sid} do
      assert {:block, reason} = Guardian.review(tool("rm -rf /"), state(sid))
      assert reason =~ "mass-deletion" or reason =~ "destructive"
      assert Guardian.block_count(sid) == 1
      refute Guardian.paused?(sid)
    end
  end

  describe "pause-after-N threshold" do
    test "pauses once the block counter reaches the configured threshold", %{session_id: sid} do
      threshold = Guardian.pause_after_blocks()
      assert threshold >= 1

      # First threshold-1 dangerous calls are blocked, not paused.
      for _ <- 1..(threshold - 1) do
        assert {:block, _} = Guardian.review(tool("rm -rf /"), state(sid))
      end

      refute Guardian.paused?(sid)

      # The threshold-th dangerous call pauses the session.
      assert {:pause, reason} = Guardian.review(tool("sudo rm -rf /etc"), state(sid))
      assert reason =~ "paused"
      assert Guardian.paused?(sid)
      assert Guardian.block_count(sid) == threshold
    end

    test "once paused, every subsequent review returns :pause (even for safe calls)",
         %{session_id: sid} do
      threshold = Guardian.pause_after_blocks()
      for _ <- 1..threshold, do: Guardian.review(tool("rm -rf /"), state(sid))
      assert Guardian.paused?(sid)

      assert {:pause, _} = Guardian.review(tool("ls -la"), state(sid))
    end
  end

  describe "resume/reset" do
    test "resume clears the pause and the block counter", %{session_id: sid} do
      threshold = Guardian.pause_after_blocks()
      for _ <- 1..threshold, do: Guardian.review(tool("rm -rf /"), state(sid))
      assert Guardian.paused?(sid)

      assert Guardian.resume(sid) == :ok
      refute Guardian.paused?(sid)
      assert Guardian.block_count(sid) == 0

      # After resume the loop can continue: a safe call is allowed again.
      assert Guardian.review(tool("ls"), state(sid)) == {:allow}
    end
  end

  describe "session isolation" do
    test "block counters are scoped per session", %{session_id: sid} do
      other = "other_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> Guardian.reset(other) end)

      Guardian.review(tool("rm -rf /"), state(sid))
      assert Guardian.block_count(sid) == 1
      assert Guardian.block_count(other) == 0
    end
  end
end
