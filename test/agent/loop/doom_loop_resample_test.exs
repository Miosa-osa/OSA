defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.ResampleTest do
  # async: false — these tests mutate the :doom_loop_resample application env.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DoomLoop
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Resample

  @key :doom_loop_resample

  setup do
    original = Application.get_env(:optimal_system_agent, @key)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:optimal_system_agent, @key)
      else
        Application.put_env(:optimal_system_agent, @key, original)
      end
    end)

    :ok
  end

  defp put_config(kw), do: Application.put_env(:optimal_system_agent, @key, kw)

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "test-resample",
        messages: [%{role: "user", content: "do the thing"}],
        doom_resamples: 0
      },
      overrides
    )
  end

  describe "handle/4 — resamples on a detected loop" do
    test "re-invokes the loop (discards offending response) when budget remains" do
      put_config(enabled: true, max_retries: 2, backoff_ms: 0)
      test_pid = self()

      run_fun = fn retry_state ->
        send(test_pid, {:resampled, retry_state})
        {"recovered", retry_state}
      end

      halted_state = snapshot(%{messages: [:user, :assistant_loop, :tool_result]})

      assert {"recovered", final} =
               Resample.handle("looped!", halted_state, snapshot(), run_fun)

      # run_fun was invoked (the turn was resampled, not surfaced)
      assert_received {:resampled, retry_state}

      # Attempt counter advanced 0 -> 1
      assert retry_state.doom_resamples == 1
      assert final.doom_resamples == 1

      # The offending response was DISCARDED: retry rewinds to the snapshot's
      # messages (which predate the looping assistant+tool messages), plus a
      # single break-the-loop directive.
      assert length(retry_state.messages) == length(snapshot().messages) + 1
      [directive | _] = Enum.reverse(retry_state.messages)
      assert directive.role == "system"
      assert directive.content =~ "discarded"
    end
  end

  describe "handle/4 — succeeds after a resample" do
    test "returns the re-rolled turn's successful result, not the halt message" do
      put_config(enabled: true, max_retries: 2)

      run_fun = fn state -> {"the real answer", state} end

      assert {"the real answer", _state} =
               Resample.handle("looped!", snapshot(), snapshot(), run_fun)
    end
  end

  describe "handle/4 — exhausts to fallback" do
    test "falls back to the halt message once the resample budget is spent" do
      put_config(enabled: true, max_retries: 2)
      test_pid = self()
      run_fun = fn _ -> send(test_pid, :should_not_run) end

      # snapshot already shows max_retries resamples used
      exhausted = snapshot(%{doom_resamples: 2})
      halted = snapshot(%{doom_resamples: 2, extra: :halt_state})

      assert {"looped!", out} = Resample.handle("looped!", halted, exhausted, run_fun)
      refute_received :should_not_run

      # The halt STATE now carries one added field: who authored the text.
      #
      # This test used to assert the state came back byte-identical (`^halted`),
      # which is what allowed the guard's advice to be delivered as the model's
      # answer — nothing downstream could tell it apart from one. Everything
      # else must still be untouched.
      assert Map.delete(out, :terminal_source) == halted
      assert OptimalSystemAgent.Agent.Loop.TerminalSource.of(out) == :guard
      assert OptimalSystemAgent.Agent.Loop.TerminalSource.response_type(out) == "system"
    end

    test "resamples exactly max_retries times then falls back (walk the budget)" do
      put_config(enabled: true, max_retries: 2)
      test_pid = self()

      # A run_fun whose re-rolled turn *also* loops: it re-enters Resample.handle
      # with the retry_state as the new snapshot, exactly like ReactLoop when the
      # re-sampled turn loops once more. Terminates naturally when the budget is
      # spent and Resample falls back to the halt.
      recur = fn recur, state ->
        send(test_pid, {:attempt, Map.get(state, :doom_resamples)})

        Resample.handle("still looping", Map.put(state, :halted, true), state, fn s ->
          recur.(recur, s)
        end)
      end

      run_fun = fn state -> recur.(recur, state) end

      assert {"still looping", final} =
               Resample.handle("still looping", snapshot(), snapshot(), run_fun)

      # Budget of 2 => two resample re-entries (doom_resamples 1 then 2), then
      # the third check exhausts and falls back to the halt.
      assert final.doom_resamples == 2
      assert final.halted == true
      assert_received {:attempt, 1}
      assert_received {:attempt, 2}
    end
  end

  describe "handle/4 — disabled restores old behavior" do
    test "returns the halt unchanged and never resamples when disabled" do
      put_config(enabled: false, max_retries: 2)
      test_pid = self()
      run_fun = fn _ -> send(test_pid, :should_not_run) end

      halted = snapshot(%{marker: :old_behavior})

      assert {"looped!", out} = Resample.handle("looped!", halted, snapshot(), run_fun)
      refute_received :should_not_run

      # "Unchanged" now means "unchanged apart from provenance". Even with the
      # resample remedy disabled, a doom halt is still the GUARD talking and
      # must not be rendered as the assistant's reply.
      assert Map.delete(out, :terminal_source) == halted
      assert OptimalSystemAgent.Agent.Loop.TerminalSource.of(out) == :guard
    end

    test "defaults: enabled true, max_retries 2, threshold 4 when unconfigured" do
      Application.delete_env(:optimal_system_agent, @key)
      assert Resample.enabled?() == true
      assert Resample.max_retries() == 2
      assert Resample.threshold() == 4
      assert Resample.backoff_ms() == 0
    end
  end

  describe "detection is preserved + threshold is configurable" do
    defp base_state do
      %{
        session_id: "test-thr",
        total_tool_calls: 0,
        recent_failure_signatures: [],
        messages: []
      }
    end

    defp identical_calls(n) do
      for i <- 1..n, do: %{id: "c#{i}", name: "file_read", arguments: %{"path" => "a.ex"}}
    end

    defp results_for(tcs) do
      Enum.map(tcs, fn tc ->
        {tc, {%{role: "tool", tool_call_id: tc.id, content: "ok"}, "ok"}}
      end)
    end

    test "still halts on identical-call loop at the default threshold (detection intact)" do
      put_config(enabled: true, max_retries: 2, threshold: 4)
      tcs = identical_calls(4)

      assert {:halt, msg, _state} = DoomLoop.check(results_for(tcs), tcs, base_state())
      assert msg =~ "identical arguments"
    end

    test "a lowered threshold declares the loop sooner" do
      put_config(enabled: true, max_retries: 2, threshold: 2)
      tcs = identical_calls(2)

      assert {:halt, _msg, _state} = DoomLoop.check(results_for(tcs), tcs, base_state())
    end

    test "a raised threshold does not halt below it" do
      put_config(enabled: true, max_retries: 2, threshold: 6)
      tcs = identical_calls(4)

      assert {:ok, _state} = DoomLoop.check(results_for(tcs), tcs, base_state())
    end
  end
end
