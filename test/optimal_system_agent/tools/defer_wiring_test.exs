defmodule OptimalSystemAgent.Tools.DeferWiringTest do
  @moduledoc """
  A tool that declares itself deferred must actually be deferred.

  `list_active/0` checked only `deferred?/0`. A module written as
  `use MiosaTools.Behaviour` gets a generated `deferred?/0` delegating to
  `should_defer?/0`; a module written as `@behaviour MiosaTools.Behaviour` gets
  no such delegate. So adding `should_defer?` to a `@behaviour`-style module was
  DEAD CODE — it compiled, it read as a fix in review, and it deferred nothing.

  That is expensive rather than cosmetic: every schema in the default set is
  re-sent on every single request, so a tool that silently fails to defer is
  paid for by every turn of every session. Measured at the time of this fix,
  the default set was 15,486 tokens across 37 tools.

  Fixing the wiring immediately revealed a pre-existing dead declaration —
  `start_speculative` had been declaring itself deferred and being sent anyway.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry

  defp active_names, do: MapSet.new(Registry.list_active(), & &1.name)

  test "a should_defer? declaration is honoured regardless of module style" do
    active = active_names()

    for name <- ["github", "workspace_map", "start_speculative"] do
      refute MapSet.member?(active, name),
             "#{name} declares itself deferred but is still in the default toolbox"
    end
  end

  test "deferring does not remove a tool — it stays callable and discoverable" do
    all = MapSet.new(Registry.list_tools(), & &1.name)

    assert MapSet.member?(all, "github"),
           "a deferred tool must remain registered and reachable via tool_search"
  end

  test "the default toolbox is strictly smaller than the full set" do
    active = length(Registry.list_active())
    all = length(Registry.list_tools())

    assert active < all,
           "deferral is doing nothing: #{active} active of #{all} total"
  end

  test "eagerly-used tools are NOT deferred" do
    # Guards the opposite failure: over-deferring makes the agent fetch a schema
    # mid-turn for something it needs on nearly every turn.
    active = active_names()

    for name <- ["shell_execute", "file_read", "file_edit"] do
      assert MapSet.member?(active, name),
             "#{name} is used on most turns and must stay in the default toolbox"
    end
  end
end
