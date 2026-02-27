defmodule OptimalSystemAgent.CommandsTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Commands

  # ---------------------------------------------------------------------------
  # Module smoke tests
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "Commands module is defined and loaded" do
      assert Code.ensure_loaded?(Commands)
    end

    test "exports execute/2" do
      assert function_exported?(Commands, :execute, 2)
    end

    test "exports list_commands/0" do
      assert function_exported?(Commands, :list_commands, 0)
    end

    test "exports register/3" do
      assert function_exported?(Commands, :register, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # list_commands/0 smoke tests
  # ---------------------------------------------------------------------------

  describe "list_commands/0" do
    test "returns a list" do
      result = Commands.list_commands()
      assert is_list(result)
    end

    test "each entry is a two-element tuple of strings" do
      Commands.list_commands()
      |> Enum.each(fn {name, desc} ->
        assert is_binary(name), "expected name to be a string, got: #{inspect(name)}"
        assert is_binary(desc), "expected desc to be a string, got: #{inspect(desc)}"
      end)
    end

    test "built-in help command is present" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "help" in names
    end
  end

  # ---------------------------------------------------------------------------
  # execute/2 smoke tests
  # ---------------------------------------------------------------------------

  describe "execute/2" do
    test "unknown command returns :unknown" do
      assert :unknown == Commands.execute("zzz_no_such_command_xyz", "test-session")
    end

    test "help returns a command tuple with string output" do
      # The CLI strips the leading slash before calling execute/2.
      # Builtin keys are plain names: "help", "status", etc.
      result = Commands.execute("help", "test-session")
      assert {:command, output} = result
      assert is_binary(output)
    end
  end
end
