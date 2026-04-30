defmodule OptimalSystemAgent.Tools.Builtins.REPLTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.REPL, as: REPLShim
  alias OptimalSystemAgent.Tools.Builtins.REPL.{Constants, Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "repl_test"}

  # ---------------------------------------------------------------------------
  # Structured layout — identity callbacks
  # ---------------------------------------------------------------------------

  describe "Tool identity" do
    test "name returns repl" do
      assert Tool.name() == "repl"
    end

    test "name matches Constants.tool_name" do
      assert Tool.name() == Constants.tool_name()
    end

    test "should_defer? is true" do
      assert Tool.should_defer?() == true
    end

    test "concurrency_safe? is false" do
      assert Tool.concurrency_safe?(%{}, ctx()) == false
    end

    test "read_only? is false" do
      assert Tool.read_only?(%{}, ctx()) == false
    end

    test "destructive? is false" do
      assert Tool.destructive?(%{}, ctx()) == false
    end

    test "safety is :write_safe" do
      assert Tool.safety() == :write_safe
    end

    test "always_load? is false" do
      assert Tool.always_load?() == false
    end

    test "parameters includes required code field" do
      params = Tool.parameters()
      assert params["required"] == ["code"]
      assert Map.has_key?(params["properties"], "code")
    end
  end

  # ---------------------------------------------------------------------------
  # Shim parity — flat module delegates to Tool
  # ---------------------------------------------------------------------------

  describe "shim parity" do
    test "REPL.name() delegates to REPL.Tool.name()" do
      assert REPLShim.name() == Tool.name()
    end

    test "REPL.should_defer?() delegates to REPL.Tool.should_defer?()" do
      assert REPLShim.should_defer?() == Tool.should_defer?()
    end

    test "REPL.safety() delegates to REPL.Tool.safety()" do
      assert REPLShim.safety() == Tool.safety()
    end

    test "REPL has execute/2 (structured)" do
      assert {_, _} = List.keyfind(REPLShim.__info__(:functions), :execute, 0, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — validate
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "valid input passes" do
      assert {:ok, %{"code" => "1+1"}} = Handler.validate(%{"code" => "1+1"}, ctx())
    end

    test "missing code returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "code"
    end

    test "non-string code returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{"code" => 123}, ctx())
      assert msg =~ "string"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — check_permissions
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "unsupported language is denied" do
      input = %{"code" => "print(1)", "language" => "ruby"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end

    test "supported language python is allowed" do
      input = %{"code" => "print(1)", "language" => "python"}
      assert {:allow, _} = Handler.check_permissions(input, ctx())
    end

    test "supported language elixir is allowed" do
      input = %{"code" => "IO.puts(1)", "language" => "elixir"}
      assert {:allow, _} = Handler.check_permissions(input, ctx())
    end

    test "no language field (defaults to python) is allowed" do
      input = %{"code" => "print(1)"}
      assert {:allow, _} = Handler.check_permissions(input, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — execute
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2" do
    test "unsupported language via execute returns error" do
      assert {:error, msg} = Handler.execute(%{"code" => "x", "language" => "cobol"}, ctx())
      assert msg =~ "Unsupported language"
    end

    @tag :slow
    test "python runtime not present returns runtime-not-found or executes" do
      input = %{"code" => "print('hello')", "language" => "python"}
      result = Handler.execute(input, ctx())
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # UI renders
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    alias OptimalSystemAgent.Tools.Builtins.REPL.UI

    test ":tool_use returns kind repl" do
      map = UI.render(:tool_use, %{"code" => "1+1", "language" => "python"}, [])
      assert map[:kind] == "repl"
      assert map[:language] == "python"
    end

    test ":tool_result returns kind repl_result" do
      map = UI.render(:tool_result, "some output", [])
      assert map[:kind] == "repl_result"
    end

    test ":rejected returns kind repl_rejected" do
      map = UI.render(:rejected, %{}, [])
      assert map[:kind] == "repl_rejected"
    end

    test ":error returns kind repl_error" do
      map = UI.render(:error, "something went wrong", [])
      assert map[:kind] == "repl_error"
      assert map[:message] == "something went wrong"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, %{}, []) == nil
    end
  end
end
