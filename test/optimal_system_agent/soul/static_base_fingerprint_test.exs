defmodule OptimalSystemAgent.Soul.StaticBaseFingerprintTest do
  @moduledoc """
  Both tests below assume `build_base/1`'s INPUTS are a fixed point for their
  brief duration — that is the whole property under test (an invalidate+
  rebuild is a no-op cycle when nothing changed). Those inputs are not only
  the live tool registry (MCP/plugin tools can register at any point in a
  session's life — see `Soul`'s own moduledoc: they "arrive later") but also
  every bundled rule file `rules_content/0` reads fresh off disk on each
  build; either one changing mid-suite makes the SAME rebuild answer
  differently, the toolbox/files moved, not the code. Checking only the tool
  NAMES for stability (an earlier version of this fix) missed exactly that —
  the observed failure diverged deep in the rendered rules/tool-prose text
  while `Tools.Registry.list_active/0`'s name list was already stable.
  `await_stable_build/0` instead waits for the ACTUAL rebuild — the thing
  each assertion below compares — to return the same bytes on two
  consecutive tries before either test starts, so both are proven to start
  from a build that is not mid-change, without weakening what either
  assertion checks.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul

  setup do
    await_stable_build()
    :ok
  end

  defp await_stable_build(prev \\ nil, tries \\ 80)

  defp await_stable_build(_prev, 0), do: :ok

  defp await_stable_build(prev, tries) do
    Soul.invalidate_static_base()
    current = Soul.static_base(:native_tools)

    if current == prev do
      :ok
    else
      Process.sleep(25)
      await_stable_build(current, tries - 1)
    end
  end

  test "two reads with an unchanged toolbox return the same bytes" do
    Soul.invalidate_static_base()
    a = Soul.static_base(:native_tools)
    b = Soul.static_base(:native_tools)
    assert is_binary(a) and a != ""
    assert a == b
  end

  test "invalidate forces a rebuild that still matches the live toolbox" do
    first = Soul.static_base(:native_tools)
    Soul.invalidate_static_base()
    second = Soul.static_base(:native_tools)
    assert first == second
  end
end
