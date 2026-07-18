defmodule OptimalSystemAgent.Agent.Loop.ToolRetryTest do
  @moduledoc """
  P0-2: bounded retry-with-backoff for TRANSIENT tool failures, with fail-fast
  on SEMANTIC failures.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.ToolRetry

  # base_ms: 0 disables real sleeping so the suite stays fast.
  @fast [base_ms: 0]

  defp counting_fun(results) do
    {:ok, agent} = Agent.start_link(fn -> {0, results} end)

    fun = fn ->
      Agent.get_and_update(agent, fn {n, [head | tail]} -> {head, {n + 1, tail}} end)
    end

    count = fn -> Agent.get(agent, fn {n, _} -> n end) end
    {fun, count}
  end

  describe "transient errors" do
    test "retries a transient failure and then succeeds" do
      # First attempt flakes with a timeout, second attempt succeeds.
      {fun, count} =
        counting_fun([
          {:error, "Command timed out after 30s"},
          {:ok, "build passed"}
        ])

      assert {:ok, "build passed"} = ToolRetry.run(fun, @fast)
      assert count.() == 2
    end

    test "retries up to max_attempts then surfaces the last transient error" do
      {fun, count} =
        counting_fun([
          {:error, :timeout},
          {:error, "connection reset by peer"},
          {:error, "503 Service Unavailable"}
        ])

      assert {:error, "503 Service Unavailable"} = ToolRetry.run(fun, @fast)
      # 3 total attempts (initial + 2 retries).
      assert count.() == 3
    end

    test "respects a lowered max_attempts" do
      {fun, count} =
        counting_fun([
          {:error, "EAGAIN resource temporarily unavailable"},
          {:ok, "ok"}
        ])

      # max_attempts: 1 => no retry, first error surfaces.
      assert {:error, _} = ToolRetry.run(fun, Keyword.put(@fast, :max_attempts, 1))
      assert count.() == 1
    end

    test "classifies a representative transient allowlist" do
      for reason <- [
            :timeout,
            :eagain,
            :econnreset,
            "Command timed out after 5s",
            "connection refused",
            "429 Too Many Requests",
            "502 Bad Gateway",
            "temporarily unavailable",
            "text file busy",
            "network is unreachable"
          ] do
        assert ToolRetry.transient_tool_error?(reason), "expected transient: #{inspect(reason)}"
      end
    end
  end

  describe "semantic errors (must NOT retry)" do
    test "does NOT retry a semantic old_string-not-found error" do
      {fun, count} =
        counting_fun([
          {:error, "old_string not found in file"},
          {:ok, "should never be reached"}
        ])

      assert {:error, "old_string not found in file"} = ToolRetry.run(fun, @fast)
      # Exactly one attempt — no retry.
      assert count.() == 1
    end

    test "does NOT retry validation / permission / deterministic errors" do
      for reason <- [
            "old_string not found",
            "match is ambiguous (3 matches)",
            "not unique",
            "identical content, no changes",
            "File has not been read yet",
            "modified since read",
            "Blocked: permission denied",
            "denied by a saved permission rule",
            "Missing required parameter: command",
            "Exit 1:\ncompilation failed"
          ] do
        refute ToolRetry.transient_tool_error?(reason),
               "expected fail-fast (non-transient): #{inspect(reason)}"
      end
    end

    test "a deterministic non-zero exit is not retried" do
      {fun, count} = counting_fun([{:error, "Exit 2:\nsyntax error"}, {:ok, "unreached"}])
      assert {:error, "Exit 2:\nsyntax error"} = ToolRetry.run(fun, @fast)
      assert count.() == 1
    end
  end

  describe "success passthrough" do
    test "a first-try success is returned unchanged with no retry" do
      {fun, count} = counting_fun([{:ok, "done"}])
      assert {:ok, "done"} = ToolRetry.run(fun, @fast)
      assert count.() == 1
    end
  end
end
