defmodule OptimalSystemAgent.Agent.Loop.DoomLoopProgressTest do
  @moduledoc """
  Regression: the doom-loop detector must distinguish PROGRESS from a LOOP.

  A loop is *the same action producing the same result with no state change*.
  Repeated SUCCESSFUL edits to one file, each with different content, are
  progress and must never trip the detector.

  The live failure this guards: an agent adding five `@impl` annotations to five
  different functions in `compactor.ex` — five small, DIFFERENT, SUCCESSFUL
  edits — tripped `FailureSignature` and abandoned the task mid-way. Two causes:

    1. failure classification scanned the WHOLE result body (which for a
       `file_edit` embeds a diff of the edited source) for the substrings
       "error"/"cannot"/"failed", so a successful edit to any file that merely
       mentions an error read as a failure; and
    2. the signature was the first 100 characters of the result, which for
       `file_edit` is `"Replaced in <path>\\n--- <path…"` — identical for every
       edit to the same file regardless of content.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature

  @path "lib/optimal_system_agent/agent/compactor.ex"

  defp state(overrides \\ []) do
    Enum.into(overrides, %{
      session_id: "doom-progress-#{System.unique_integer([:positive, :monotonic])}",
      messages: [],
      recent_failure_signatures: []
    })
  end

  defp call(name, args),
    do: %{id: "tc-#{System.unique_integer([:positive, :monotonic])}", name: name, arguments: args}

  # What `FileEdit.Handler` actually returns on success: a "Replaced in <path>"
  # line followed by a diff of the edited region. The diff below deliberately
  # carries context lines mentioning "error" / "cannot" — exactly the content
  # that used to make a successful edit look like a failure.
  defp successful_edit_result(fn_name) do
    """
    Replaced in #{@path}
    --- #{@path}
    +++ #{@path}
    @@ -120,6 @@
      # returns {:error, reason} when the window cannot be built
    + @impl OptimalSystemAgent.Agent.ContextEngine
      def #{fn_name}(state) do
    """
  end

  describe "progress is not a loop" do
    test "five successful, DIFFERENT edits to the same file never trip the detector" do
      fns = ~w(compact estimate_tokens summarize window_for prune)

      final =
        Enum.reduce(fns, state(), fn fn_name, acc ->
          tc = call("file_edit", %{"path" => @path, "old_string" => "def #{fn_name}"})
          body = successful_edit_result(fn_name)
          results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]

          assert {:ok, next} = FailureSignature.check(results, [tc], acc)

          # No halt AND no injected steering message: a false trip that only
          # nudges is still a failure — the live agent read the nudge and
          # abandoned correct work.
          assert next.messages == [],
                 "a successful edit must not inject any doom-loop directive"

          next
        end)

      assert final.recent_failure_signatures == []
    end

    test "a successful edit whose body contains error words is not a failure" do
      refute FailureSignature.failure?(successful_edit_result("compact"))
      refute FailureSignature.failure?("Replaced 3 occurrences in #{@path}")
    end

    test "identical FAILING calls with different arguments do not accumulate one signature" do
      # Same tool, same file, same error text — but different args each time.
      # Under the strict (args-keyed) signature this stays below the threshold.
      final =
        Enum.reduce(1..3, state(), fn i, acc ->
          tc = call("file_edit", %{"path" => @path, "old_string" => "target #{i}"})
          body = "Error: old_string not found in #{@path}"
          results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]

          assert {:ok, next} = FailureSignature.check(results, [tc], acc)
          next
        end)

      # They DO accumulate (each is a real failure) but as three distinct
      # strict signatures, so no recovery directive fired at 3.
      assert length(final.recent_failure_signatures) == 3
      assert final.messages == []
    end
  end

  describe "genuine loops still trip" do
    test "three IDENTICAL failing calls inject the recovery directive" do
      tc = call("file_edit", %{"path" => @path, "old_string" => "no such text"})
      body = "Error: old_string not found in #{@path}"
      results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]

      s0 = state()
      assert {:ok, s1} = FailureSignature.check(results, [tc], s0)
      assert {:ok, s2} = FailureSignature.check(results, [tc], s1)
      assert {:ok, s3} = FailureSignature.check(results, [tc], s2)

      assert s3.doom_recovery_count == 1
      directive = List.last(s3.messages)
      assert directive.content =~ "DOOM LOOP RECOVERY"

      # The directive must not read as "stop doing this task".
      assert directive.content =~ "must NOT abandon"
    end

    test "identical failing calls eventually hard-halt after recovery is exhausted" do
      tc = call("shell_execute", %{"command" => "nope"})
      body = "Error: Exit 127:\ncommand not found: nope"
      results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]

      # Three failures per recovery round; two rounds of recovery, then halt.
      outcome =
        Enum.reduce_while(1..12, state(), fn _i, acc ->
          case FailureSignature.check(results, [tc], acc) do
            {:ok, next} -> {:cont, next}
            {:halt, msg, _s} -> {:halt, msg}
          end
        end)

      assert is_binary(outcome)
      assert outcome =~ "shell_execute"
    end

    test "same failure with jittered arguments still trips via the broad signature" do
      body = "Error: old_string not found in #{@path}"

      outcome =
        Enum.reduce_while(1..8, state(), fn i, acc ->
          tc = call("file_edit", %{"path" => @path, "old_string" => "attempt #{i}"})
          results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]

          case FailureSignature.check(results, [tc], acc) do
            {:ok, next} ->
              if next.messages != [], do: {:halt, :nudged}, else: {:cont, next}

            {:halt, _msg, _s} ->
              {:halt, :halted}
          end
        end)

      assert outcome in [:nudged, :halted]
    end
  end

  describe "operator decisions are still excluded" do
    test "repeated permission declines never accumulate" do
      tc = call("shell_execute", %{"command" => "rm -rf /tmp/x"})
      body = "Blocked: you declined to run shell_execute"
      results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]

      final =
        Enum.reduce(1..5, state(), fn _, acc ->
          assert {:ok, next} = FailureSignature.check(results, [tc], acc)
          next
        end)

      assert final.recent_failure_signatures == []
      assert final.messages == []
    end
  end
end
