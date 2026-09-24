defmodule OptimalSystemAgent.RepoMap.TestStatusTest do
  @moduledoc """
  Parses "did the last test run pass" out of a shell command + its raw
  output, WITHOUT running anything itself — `RepoMap.observe_tool_result/4`
  feeds it whatever `shell_execute` already produced.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.RepoMap.TestStatus

  describe "parse/2 — not a test run" do
    test "a command with no recognizable test runner is not a test run" do
      assert TestStatus.parse("ls -la", "some output") == :not_a_test_run
    end

    test "a nil command is not a test run" do
      assert TestStatus.parse(nil, "12 tests, 0 failures") == :not_a_test_run
    end
  end

  describe "parse/2 — ExUnit (mix test)" do
    test "all green is :passed" do
      output = "Running ExUnit with seed: 1\n\n....\n\n4 tests, 0 failures\n"
      assert {:ok, status} = TestStatus.parse("mix test", output)
      assert status.status == :passed
      assert status.summary =~ "4 tests, 0 failures"
      assert status.tool =~ "mix test"
    end

    test "any failure is :failed" do
      output = "..F.\n\n4 tests, 1 failure\n"
      assert {:ok, status} = TestStatus.parse("mix test test/foo_test.exs", output)
      assert status.status == :failed
      assert status.summary =~ "1 failure"
    end
  end

  describe "parse/2 — pytest" do
    test "all passed" do
      output = "===== 5 passed in 0.42s ====="
      assert {:ok, status} = TestStatus.parse("pytest", output)
      assert status.status == :passed
      assert status.summary =~ "5 passed"
    end

    test "some failed" do
      output = "===== 2 failed, 5 passed in 1.10s ====="
      assert {:ok, status} = TestStatus.parse("python -m pytest", output)
      assert status.status == :failed
      assert status.summary =~ "2 failed"
      assert status.summary =~ "5 passed"
    end
  end

  describe "parse/2 — cargo test" do
    test "ok result" do
      output = "test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured\n"
      assert {:ok, status} = TestStatus.parse("cargo test", output)
      assert status.status == :passed
    end

    test "FAILED result" do
      output = "test result: FAILED. 10 passed; 2 failed; 0 ignored; 0 measured\n"
      assert {:ok, status} = TestStatus.parse("cargo test", output)
      assert status.status == :failed
    end
  end

  describe "parse/2 — go test" do
    test "ok line with no FAIL is :passed" do
      output = "ok  \tgithub.com/foo/bar\t0.004s\n"
      assert {:ok, status} = TestStatus.parse("go test ./...", output)
      assert status.status == :passed
    end

    test "a FAIL line is :failed" do
      output = "--- FAIL: TestFoo (0.00s)\nFAIL\tgithub.com/foo/bar\t0.004s\n"
      assert {:ok, status} = TestStatus.parse("go test ./...", output)
      assert status.status == :failed
    end
  end

  describe "parse/2 — unrecognized output from a recognized runner" do
    test "still records something rather than nothing" do
      output = "some unusual output with no summary line we recognize"
      assert {:ok, status} = TestStatus.parse("mix test", output)
      assert status.status == :unknown
      assert status.summary =~ "unusual output"
    end
  end
end
