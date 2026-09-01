defmodule OptimalSystemAgent.Tools.Builtins.Delegate.ForceBackgroundTest do
  @moduledoc """
  A research fan-out must never lock the parent's turn. An agent def marked
  `force_background: true` (e.g. `researcher`) runs in the background even when
  the model explicitly asked to foreground it, so the user can keep talking to
  the main agent — "how are the agents doing?" — and message the running wave
  (list_agents / message_agent / send_message) instead of the turn hanging for
  an hour.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Delegate.Handler
  alias OptimalSystemAgent.Agents.Registry

  test "force_background overrides an explicit foreground arg" do
    forced = %{force_background: true, background: false}
    assert Handler.background?(%{"background" => false}, forced),
           "a force_background role must run background even when foregrounded"
  end

  test "without force_background, an explicit foreground arg is honored" do
    refute Handler.background?(%{"background" => false}, %{force_background: false, background: true})
  end

  test "force_background does not disturb the normal default when nothing is set" do
    assert Handler.background?(%{}, %{}) == true
  end

  test "the researcher def carries force_background: true and its turn cap" do
    Registry.load()
    r = Registry.get("researcher")
    assert r.force_background == true
    assert r.max_iterations == 30
  end
end
