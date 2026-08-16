defmodule OptimalSystemAgent.Tools.AliasDispatchTest do
  @moduledoc """
  The `aliases/0` callback existed but nothing ever read it: `module_for/1` and
  both execute paths did a plain `Map.get(builtin_tools, name)` keyed by
  canonical name only. Measured consequence in the corpus: 21 `bash_execute` +
  9 `bash` calls that resolved to nothing at all, against a tool named
  `shell_execute` whose 6,201-byte description had failed to prevent it.

  The second half of the fix is the constraint: an alias must cost ZERO prefix
  tokens, so it must never appear in the advertised array.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry

  @shell OptimalSystemAgent.Tools.Builtins.ShellExecute.Tool

  describe "alias resolution" do
    test "the names the model actually invented resolve to shell_execute" do
      assert Registry.module_for("bash") == @shell
      assert Registry.module_for("bash_execute") == @shell
    end

    test "pre-existing declared aliases resolve too" do
      assert Registry.module_for("shell") == @shell
      assert Registry.module_for("read") == OptimalSystemAgent.Tools.Builtins.FileRead.Tool

      assert Registry.module_for("mem_recall") ==
               OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
    end

    test "a canonical name still resolves to its own module" do
      assert Registry.module_for("shell_execute") == @shell
      assert Registry.module_for("file_read") == OptimalSystemAgent.Tools.Builtins.FileRead.Tool
    end

    test "a canonical name always wins over an alias claiming it" do
      # Every canonical tool name resolves to the module registered under it,
      # never to some other tool that happens to list it as an alias.
      for {name, mod} <- :persistent_term.get({Registry, :builtin_tools}, %{}) do
        assert Registry.module_for(name) == mod
      end
    end

    test "an unknown name is still nil (aliases do not invent tools)" do
      assert Registry.module_for("definitely_not_a_tool_xyz") == nil
      assert Registry.module_for("mcp_something") == nil
    end
  end

  describe "the advertised array must not grow" do
    test "no alias name appears in list_active/0" do
      advertised = Registry.list_active() |> MapSet.new(& &1.name)

      alias_names =
        :persistent_term.get({Registry, :builtin_tools}, %{})
        |> Enum.flat_map(fn {name, mod} ->
          if function_exported?(mod, :aliases, 0) do
            mod.aliases() |> Enum.reject(&(&1 == name))
          else
            []
          end
        end)
        |> Enum.reject(&(Registry.module_for_alias(&1) == nil))

      assert alias_names != [], "expected some aliases to exist to make this test meaningful"

      for a <- alias_names do
        refute MapSet.member?(advertised, a),
               "alias #{a} leaked into the advertised tool array — that costs prefix tokens every turn"
      end
    end

    test "list_active/0 advertises only canonical registered names" do
      builtins = :persistent_term.get({Registry, :builtin_tools}, %{})

      for tool <- Registry.list_active(), not String.starts_with?(tool.name, "mcp_") do
        assert Map.has_key?(builtins, tool.name) or Registry.module_for_alias(tool.name) == nil
      end
    end
  end
end
