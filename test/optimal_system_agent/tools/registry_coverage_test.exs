defmodule OptimalSystemAgent.Tools.RegistryCoverageTest do
  @moduledoc """
  Single-source-of-truth guardrail for the tool registry.

  Every behaviour-conforming tool module under
  `lib/optimal_system_agent/tools/builtins/**` — i.e. every module exporting
  `name/0` + `execute/1` — MUST be one of:

    1. wired into the static builtin map (`Registry.load_builtin_tools/0`), or
    2. a flat-layout duplicate that is *shadowed* by a registered
       `<Module>.Tool` (structured-layout migration in progress), or
    3. explicitly listed on `@allowlist` (genuinely not a model-facing tool).

  This prevents the drift documented in the tools-registry audit, where 17
  fully-implemented tool modules sat on disk unregistered and invisible to the
  model. If you add a new flat tool, REGISTER it — do not reach for the
  allowlist unless the module is not a tool the model should ever call.
  """

  # async: false — this test reads the global {Registry, :builtin_tools}
  # persistent_term key, which a few other suites (e.g. Soul.ToolsSection,
  # MCP end-to-end) temporarily swap. Running serially avoids a false failure
  # from an interleaved swap.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry

  @builtins_prefix "Elixir.OptimalSystemAgent.Tools.Builtins."

  # Modules that export name/0 + execute/1 but are intentionally NOT registered
  # and are NOT shadowed by a <Module>.Tool. Keep this EMPTY if at all possible —
  # every entry is a model-invisible capability. Add with a justifying comment.
  # Intentionally NOT registered: their backends don't exist (MCTS.Indexer /
  # Integrations.Wallet / Vault), so exposing them to the model would only
  # produce runtime errors. A tool earns registration only when it works.
  @allowlist [
    OptimalSystemAgent.Tools.Builtins.MCTSIndex,
    OptimalSystemAgent.Tools.Builtins.WalletOps,
    OptimalSystemAgent.Tools.Builtins.VaultCheckpoint,
    OptimalSystemAgent.Tools.Builtins.VaultContext,
    OptimalSystemAgent.Tools.Builtins.VaultInject,
    OptimalSystemAgent.Tools.Builtins.VaultRemember,
    OptimalSystemAgent.Tools.Builtins.VaultSleep,
    OptimalSystemAgent.Tools.Builtins.VaultWake
  ]

  # The functional tools closed out by the P1 registration pass. Asserting them
  # by name keeps them from silently dropping back out of the map.
  @previously_orphaned ~w(
    browser github semantic_search codebase_explore code_sandbox knowledge
    orchestrate diff budget_status
  )

  defp builtin_map, do: :persistent_term.get({Registry, :builtin_tools}, %{})

  defp registered_modules, do: builtin_map() |> Map.values() |> MapSet.new()

  defp builtin_tool_modules do
    {:ok, mods} = :application.get_key(:optimal_system_agent, :modules)

    Enum.filter(mods, fn mod ->
      String.starts_with?(Atom.to_string(mod), @builtins_prefix) and
        Code.ensure_loaded?(mod) and
        function_exported?(mod, :name, 0) and
        function_exported?(mod, :execute, 1)
    end)
  end

  test "the registry published a non-empty builtin tool map" do
    assert map_size(builtin_map()) > 0,
           "Tools.Registry did not publish {Registry, :builtin_tools} — did the GenServer boot?"
  end

  test "every builtins/** tool module (name/0 + execute/1) is registered or shadowed" do
    registered = registered_modules()

    unregistered =
      builtin_tool_modules()
      |> Enum.reject(fn mod ->
        MapSet.member?(registered, mod) or
          MapSet.member?(registered, Module.concat(mod, Tool)) or
          mod in @allowlist
      end)
      |> Enum.sort()

    assert unregistered == [],
           """
           These builtin tool modules export name/0 + execute/1 but are NOT wired
           into OptimalSystemAgent.Tools.Registry.load_builtin_tools/0. They are
           invisible to the model and cannot be executed:

           #{Enum.map_join(unregistered, "\n", &("  * " <> inspect(&1)))}

           Fix: add each to the static builtin map in load_builtin_tools/0
           (preferred), or — only if it is genuinely NOT a model-facing tool —
           add it to @allowlist in this test with a justifying comment.
           """
  end

  test "previously-orphaned tools are registered by name" do
    keys = builtin_map() |> Map.keys() |> MapSet.new()

    missing = Enum.reject(@previously_orphaned, &MapSet.member?(keys, &1))

    assert missing == [],
           "Regression: these tools dropped out of the builtin map: #{inspect(missing)}"
  end
end
