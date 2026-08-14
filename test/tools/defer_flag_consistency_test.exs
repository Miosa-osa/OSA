defmodule OptimalSystemAgent.Tools.DeferFlagConsistencyTest do
  @moduledoc """
  `always_load?` and `should_defer?` must never both be true.

  They are read by two consumers that never compare notes:

    * `Tools.PromptAssembler.partition/2` honours `always_load?` and emits the
      tool's full prose plus a re-encoded JSON schema into the system prompt.
    * `Tools.Registry.list_active/0` consults only `should_defer?`, and that
      list is the SOLE source of the provider's native `tools` array.

  Set both and the tool is paid for on every request and callable on none —
  under a native-tool provider a name absent from the array cannot be emitted
  by the API at all, and no "unknown tool" error ever surfaces to make the
  failure visible. Five tools were in that state (`send_message`,
  `task_output`, `task_resume`, `task_stop`, `code_symbols`), costing a
  measured 3,561 bytes / ~890 estimated tokens of static prefix per request.

  This is a whole-registry invariant rather than five assertions, because the
  next tool to get it wrong has not been written yet, and the failure is
  silent by construction.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Registry

  defp builtins, do: :persistent_term.get({Registry, :builtin_tools}, %{})

  defp flag(mod, fun) do
    function_exported?(mod, fun, 0) and apply(mod, fun, [])
  end

  test "no builtin both always-loads and defers" do
    offenders =
      builtins()
      |> Enum.filter(fn {_name, mod} ->
        flag(mod, :always_load?) and (flag(mod, :should_defer?) or flag(mod, :deferred?))
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert offenders == [],
           """
           These tools set always_load? AND should_defer?/deferred?:

               #{Enum.join(offenders, "\n    ")}

           That combination ships full prose + schema into the system prompt for
           a tool that `Registry.list_active/0` excludes from the native tools
           array — full cost, zero reachability. Pick one:

             * meant to be always available -> should_defer?, do: false
             * meant to be deferred         -> always_load?, do: false
           """
  end

  test "the registry is actually populated, so the invariant above is not vacuous" do
    # A guard on the guard. If `:builtin_tools` were empty — a boot-order change,
    # a renamed persistent_term key — the test above would pass by finding
    # nothing to check, and would keep passing forever while the defect it
    # exists for walked back in.
    assert map_size(builtins()) > 20
  end

  test "every tool that defers is absent from the native tools array" do
    active = MapSet.new(Registry.list_active(), & &1.name)

    deferring =
      builtins()
      |> Enum.filter(fn {_name, mod} ->
        flag(mod, :should_defer?) or flag(mod, :deferred?)
      end)
      |> Enum.map(&elem(&1, 0))

    still_advertised = Enum.filter(deferring, &MapSet.member?(active, &1))

    assert still_advertised == [],
           "deferred tools leaking into the native tools array: #{inspect(still_advertised)}"
  end

  test "the five formerly-contradictory tools are still registered and executable" do
    # Removing `always_load?` must take away the PROSE, not the tool. They stay
    # in the full registry, which is what `Registry.execute_unguarded/2` and
    # `tool_search` resolve against — so nothing that could reach them before
    # can fail to reach them now.
    for name <- ~w(send_message task_output task_resume task_stop code_symbols) do
      assert Map.has_key?(builtins(), name), "#{name} vanished from the registry"
      assert Registry.module_for(name) != nil, "#{name} is no longer resolvable by name"
    end
  end
end
