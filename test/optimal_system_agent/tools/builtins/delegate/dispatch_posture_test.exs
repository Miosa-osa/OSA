defmodule OptimalSystemAgent.Tools.Builtins.Delegate.DispatchPostureTest do
  @moduledoc """
  Two defects on the `delegate` dispatch path.

  1. A `tasks:[]` fan-out went through `Orchestrator.run_parallel/3`
     SYNCHRONOUSLY, so a wave held the parent's turn until its slowest
     workstream joined. `delegate` had already defaulted a single teammate to
     background for precisely this reason — the fan-out kept the defect on the
     path most likely to run for hours.

  2. `dispatch_foreground/1` mapped `{:error, reason}` to
     `{:ok, "Delegation failed: ..."}`, handing the model a SUCCESSFUL tool
     result for a delegation that produced nothing.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Delegate.Handler

  describe "foreground_result/2 — a failed delegation must not read as success" do
    test "an error stays an error" do
      assert {:error, message} = Handler.foreground_result({:error, :timeout}, "")
      assert message =~ "Delegation failed"
      assert message =~ "timeout"
    end

    test "every failure reason shape is classified as a failure" do
      for reason <- [:timeout, :cancelled, "boom", {:exit, :killed}, %{code: 500}] do
        assert {:error, _} = Handler.foreground_result({:error, reason}, ""),
               "#{inspect(reason)} was laundered into a successful tool result"
      end
    end

    test "success is still success, with the note prefixed" do
      assert {:ok, "[note] done"} = Handler.foreground_result({:ok, "done"}, "[note] ")
    end
  end

  describe "fanout_background?/2 — the wave's posture" do
    # Configs as `build_config/6` produces them: `:background` carries the agent
    # definition's choice, defaulting to true when the definition is silent.
    defp cfg(background), do: %{background: background}

    test "a wave of ordinary workstreams runs in the background" do
      assert Handler.fanout_background?(%{}, [cfg(true), cfg(true)])
    end

    test "an explicit background: false on the call joins the wave" do
      refute Handler.fanout_background?(%{"background" => false}, [cfg(true), cfg(true)])
    end

    test "an explicit background: true wins over a definition's opt-out" do
      assert Handler.fanout_background?(%{"background" => true}, [cfg(false)])
    end

    test "one workstream's deliberate opt-out keeps the whole wave joined" do
      # Resolution is by KEY PRESENCE upstream (`default_background/1`), so a
      # definition that said `background: false` is distinguishable from one
      # that never mentioned it — and its opt-out has to survive.
      refute Handler.fanout_background?(%{}, [cfg(true), cfg(false), cfg(true)])
    end

    test "an empty config list is not a background wave" do
      refute Handler.fanout_background?(%{}, [])
    end
  end

  describe "fanout_launch_notice/2 — what the lead reads on launch" do
    test "carries the batch id and workstream count" do
      notice = Handler.fanout_launch_notice("batch:s1:7", 3)
      assert notice =~ "batch:s1:7"
      assert notice =~ "3"
      assert notice =~ "task-notification"
    end

    test "tells the lead to keep working and never to poll or stop" do
      notice = Handler.fanout_launch_notice("batch:s1:7", 2)
      assert notice =~ "KEEP WORKING"
      assert notice =~ "do NOT poll"

      # Same discipline as `async_launch_notice/3`: offered the choice, a model
      # ends its turn almost every time, leaving the user holding a launch
      # notice instead of an answer.
      refute notice =~ "end your response"
    end
  end
end
