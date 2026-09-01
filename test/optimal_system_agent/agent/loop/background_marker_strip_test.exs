defmodule OptimalSystemAgent.Agent.Loop.BackgroundMarkerStripTest do
  @moduledoc """
  Regression: the `BACKGROUND_INTENTIONAL:` marker is an internal gate-release
  signal. It was detected (to release the finish) but never stripped, so it
  leaked into the user's final answer as a stray line.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.VerificationGate, as: Gate

  test "removes the marker line from the final answer" do
    content = "All set — kicked off the build.\n\nBACKGROUND_INTENTIONAL: build runs in background"
    assert Gate.strip_background_marker(content) == "All set — kicked off the build."
  end

  test "handles the marker with varied spacing/casing" do
    assert Gate.strip_background_marker("done\nbackground-intentional : x") == "done"
    assert Gate.strip_background_marker("done\nBACKGROUND_INTENTIONAL:x") == "done"
  end

  test "content that is only the marker collapses to empty" do
    assert Gate.strip_background_marker("BACKGROUND_INTENTIONAL: nothing else") == ""
  end

  test "leaves ordinary content untouched" do
    assert Gate.strip_background_marker("Just a normal answer.") == "Just a normal answer."
  end

  test "nil passes through" do
    assert Gate.strip_background_marker(nil) == nil
  end
end
