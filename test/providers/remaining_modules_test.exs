defmodule OptimalSystemAgent.Tools.FailureReporterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.FailureReporter

  describe "report/2" do
    test "does not raise on valid input" do
      assert FailureReporter.report("shell_execute", %{error: "timeout"}) == :ok
    end

    test "does not raise on empty metadata" do
      assert FailureReporter.report("file_read", %{}) == :ok
    end

    test "does not raise on nil metadata" do
      assert FailureReporter.report("file_write", nil) == :ok
    end
  end

  describe "report/3" do
    test "accepts tool name, error string, and opts" do
      assert FailureReporter.report("shell_execute", "command failed", session_id: "test") == :ok
    end
  end
end

defmodule OptimalSystemAgent.Sandbox.CostTrackerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Sandbox.CostTracker

  setup do
    # Start the GenServer if not already running
    case GenServer.whereis(CostTracker) do
      nil -> {:ok, _pid} = CostTracker.start_link()
      _ -> :ok
    end

    session_id = "test-cost-#{System.unique_integer([:positive])}"
    CostTracker.start_session(session_id, :e2b)
    on_exit(fn -> CostTracker.clear_session(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "cost_per_ms/1" do
    test "returns positive rate for e2b" do
      assert CostTracker.cost_per_ms(:e2b) > 0
    end

    test "returns 0 for docker" do
      assert CostTracker.cost_per_ms(:docker) == 0.0
    end

    test "returns 0 for host" do
      assert CostTracker.cost_per_ms(:host) == 0.0
    end

    test "returns 0 for unknown" do
      assert CostTracker.cost_per_ms(:unknown) == 0.0
    end
  end

  describe "record_runtime/3" do
    test "accumulates runtime", %{session_id: sid} do
      CostTracker.record_runtime(sid, :e2b, 10_000)
      CostTracker.record_runtime(sid, :e2b, 5_000)
      summary = CostTracker.summary(sid)
      assert summary[:e2b].runtime_ms == 15_000
    end

    test "calculates cost from runtime", %{session_id: sid} do
      CostTracker.record_runtime(sid, :e2b, 10_000)
      summary = CostTracker.summary(sid)
      assert summary[:e2b].cost_usd > 0
      # 10000ms * 0.0000139 = 0.139
      assert_in_delta summary[:e2b].cost_usd, 0.139, 0.01
    end
  end

  describe "switch_provider/3" do
    test "adds new provider to session", %{session_id: sid} do
      CostTracker.switch_provider(sid, :e2b, :miosa)
      summary = CostTracker.summary(sid)
      assert Map.has_key?(summary, :miosa)
      assert Map.has_key?(summary, :e2b)
    end
  end

  describe "total_cost/1" do
    test "sums costs across providers", %{session_id: sid} do
      CostTracker.record_runtime(sid, :e2b, 10_000)
      CostTracker.switch_provider(sid, :e2b, :miosa)
      CostTracker.record_runtime(sid, :miosa, 5_000)
      total = CostTracker.total_cost(sid)
      assert total > 0
    end
  end
end

defmodule OptimalSystemAgent.Sandbox.FallbackTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Sandbox.Fallback

  describe "fallback_notification/2" do
    test "returns nil when same provider" do
      assert is_nil(Fallback.fallback_notification(:e2b, :e2b))
    end

    test "returns notification when switching providers" do
      msg = Fallback.fallback_notification(:e2b, :miosa)
      assert is_binary(msg)
      assert String.contains?(msg, "sandbox_fallback")
      assert String.contains?(msg, "E2B")
      assert String.contains?(msg, "MIOSA")
    end

    test "includes cloud access warning for cloud providers" do
      msg = Fallback.fallback_notification(:docker, :e2b)
      assert String.contains?(msg, "cannot access")
    end

    test "includes state loss warning for non-cloud" do
      msg = Fallback.fallback_notification(:e2b, :docker)
      assert String.contains?(msg, "NOT available")
    end
  end

  describe "provider_available?/1" do
    test "host is always available" do
      assert Fallback.provider_available?(:host)
    end
  end
end

defmodule OptimalSystemAgent.Agent.SubagentRecoveryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.SubagentRecovery

  describe "fallback_model/1" do
    test "returns sonnet for opus" do
      assert SubagentRecovery.fallback_model("claude-opus-4") == "sonnet"
    end

    test "returns haiku for sonnet" do
      assert SubagentRecovery.fallback_model("claude-sonnet-4") == "haiku"
    end

    test "returns nil for haiku (bottom of ladder)" do
      assert is_nil(SubagentRecovery.fallback_model("claude-haiku-3"))
    end

    test "returns specialist for elite" do
      assert SubagentRecovery.fallback_model("elite") == "specialist"
    end

    test "returns nil for nil input" do
      assert is_nil(SubagentRecovery.fallback_model(nil))
    end
  end

  describe "recover/3" do
    test "retries with fallback model on timeout" do
      result = SubagentRecovery.recover("agent-1", "request timed out", model: "opus")
      assert match?({:retry, _}, result)
      {:retry, opts} = result
      assert Keyword.get(opts, :model) == "sonnet"
    end

    test "retries with fresh sandbox on sandbox failure" do
      result = SubagentRecovery.recover("agent-2", "e2b sandbox crashed", model: "sonnet")
      assert match?({:retry, _}, result)
      {:retry, opts} = result
      assert Keyword.get(opts, :fresh_sandbox) == true
    end

    test "retries with backoff on rate limit" do
      result = SubagentRecovery.recover("agent-3", "rate limit exceeded (429)", model: "sonnet")
      assert match?({:retry, _}, result)
      {:retry, opts} = result
      assert Keyword.get(opts, :backoff_ms) == 5_000
    end

    test "returns fatal for auth failure" do
      result =
        SubagentRecovery.recover("agent-4", "Authentication failed: invalid key", model: "sonnet")

      assert match?({:fatal, _}, result)
    end

    test "returns fatal for content_filter" do
      result =
        SubagentRecovery.recover("agent-5", "content_filter finish reason", model: "sonnet")

      assert match?({:fatal, _}, result)
    end

    test "returns fatal after max attempts" do
      result = SubagentRecovery.recover("agent-6", "timeout", model: "haiku", recovery_attempt: 2)
      assert match?({:fatal, _}, result)
    end

    test "retries once for unknown failure" do
      result = SubagentRecovery.recover("agent-7", "something weird happened", model: "sonnet")
      assert match?({:retry, _}, result)
    end

    test "returns fatal for unknown failure on second attempt" do
      result =
        SubagentRecovery.recover("agent-8", "something weird happened",
          model: "sonnet",
          recovery_attempt: 1
        )

      assert match?({:fatal, _}, result)
    end
  end
end

defmodule OptimalSystemAgent.Agent.PersistedResultTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.PersistedResult

  describe "save/3 and load/2" do
    test "saves and loads a result" do
      session_id = "test-persist-#{System.unique_integer([:positive])}"
      agent_id = "agent-#{System.unique_integer([:positive])}"

      result = %{
        task: "Validate SQLi",
        status: "completed",
        verdict: "confirmed",
        evidence: ["screenshot.png"]
      }

      assert {:ok, _path} = PersistedResult.save(session_id, agent_id, result)
      assert {:ok, loaded} = PersistedResult.load(session_id, agent_id)
      assert loaded["task"] == "Validate SQLi"
      assert loaded["verdict"] == "confirmed"
      assert loaded["agent_id"] == agent_id
      assert loaded["session_id"] == session_id

      PersistedResult.clear_session(session_id)
    end

    test "returns error for nonexistent result" do
      assert {:error, _} = PersistedResult.load("nonexistent-session", "nonexistent-agent")
    end
  end

  describe "exists?/2" do
    test "returns true for saved result" do
      session_id = "test-exists-#{System.unique_integer([:positive])}"
      agent_id = "agent-#{System.unique_integer([:positive])}"

      PersistedResult.save(session_id, agent_id, %{task: "test"})
      assert PersistedResult.exists?(session_id, agent_id)

      PersistedResult.clear_session(session_id)
    end

    test "returns false for nonexistent" do
      refute PersistedResult.exists?("nonexistent", "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all results for a session" do
      session_id = "test-list-#{System.unique_integer([:positive])}"

      PersistedResult.save(session_id, "agent-a", %{task: "task a"})
      PersistedResult.save(session_id, "agent-b", %{task: "task b"})

      results = PersistedResult.list(session_id)
      assert length(results) == 2

      PersistedResult.clear_session(session_id)
    end

    test "returns empty list for nonexistent session" do
      assert PersistedResult.list("nonexistent-session") == []
    end
  end

  describe "clear_session/1" do
    test "deletes all results for a session" do
      session_id = "test-clear-#{System.unique_integer([:positive])}"

      PersistedResult.save(session_id, "agent-x", %{task: "test"})
      assert length(PersistedResult.list(session_id)) == 1

      PersistedResult.clear_session(session_id)
      assert PersistedResult.list(session_id) == []
    end
  end
end
