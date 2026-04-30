defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbolsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.CodeSymbols, as: CodeSymbolsShim
  alias OptimalSystemAgent.Tools.Builtins.CodeSymbols.{Constants, Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "code_symbols_test"}

  # ---------------------------------------------------------------------------
  # Structured layout — identity callbacks
  # ---------------------------------------------------------------------------

  describe "Tool identity" do
    test "name returns code_symbols" do
      assert Tool.name() == "code_symbols"
    end

    test "name matches Constants.tool_name" do
      assert Tool.name() == Constants.tool_name()
    end

    test "should_defer? is false" do
      assert Tool.should_defer?() == false
    end

    test "always_load? is true" do
      assert Tool.always_load?() == true
    end

    test "concurrency_safe? is true" do
      assert Tool.concurrency_safe?(%{}, ctx()) == true
    end

    test "read_only? is true" do
      assert Tool.read_only?(%{}, ctx()) == true
    end

    test "destructive? is false" do
      assert Tool.destructive?(%{}, ctx()) == false
    end

    test "safety is :read_only" do
      assert Tool.safety() == :read_only
    end

    test "parameters includes required path field" do
      params = Tool.parameters()
      assert params["required"] == ["path"]
    end
  end

  # ---------------------------------------------------------------------------
  # Shim parity — flat module delegates to Tool
  # ---------------------------------------------------------------------------

  describe "shim parity" do
    test "CodeSymbols.name() delegates to CodeSymbols.Tool.name()" do
      assert CodeSymbolsShim.name() == Tool.name()
    end

    test "CodeSymbols.safety() delegates to CodeSymbols.Tool.safety()" do
      assert CodeSymbolsShim.safety() == Tool.safety()
    end

    test "CodeSymbols.always_load?() is true" do
      assert CodeSymbolsShim.always_load?() == true
    end

    test "CodeSymbols has execute/2 (structured)" do
      assert {_, _} = List.keyfind(CodeSymbolsShim.__info__(:functions), :execute, 0, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — validate
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "valid input passes" do
      assert {:ok, %{"path" => "/tmp/x.ex"}} = Handler.validate(%{"path" => "/tmp/x.ex"}, ctx())
    end

    test "missing path returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "path"
    end

    test "non-string path returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{"path" => 42}, ctx())
      assert msg =~ "string"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — check_permissions
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "path outside allowed is denied" do
      input = %{"path" => "/etc/shadow"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end

    test "path in /tmp is allowed" do
      path = "/tmp/code_sym_test_#{:rand.uniform(100_000)}.ex"
      input = %{"path" => path}
      assert {:allow, _} = Handler.check_permissions(input, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — execute (symbol extraction)
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2 — Elixir files" do
    setup do
      path = "/tmp/osa_sym_test_#{:rand.uniform(100_000)}.ex"

      File.write!(path, """
      defmodule MyApp.Foo do
        def public_fn(a, b), do: a + b
        defp private_fn(x), do: x * 2
        defmacro my_macro(v), do: v
      end
      """)

      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "finds module, public function, private function, macro", %{path: path} do
      assert {:ok, result} = Handler.execute(%{"path" => path}, ctx())
      assert result =~ "[module]"
      assert result =~ "MyApp.Foo"
      assert result =~ "[function]"
      assert result =~ "public_fn"
      assert result =~ "(private)"
      assert result =~ "(macro)"
    end

    test "filter type=module returns only module symbols", %{path: path} do
      assert {:ok, result} = Handler.execute(%{"path" => path, "type" => "module"}, ctx())
      assert result =~ "[module]"
      refute result =~ "[function]"
    end

    test "filter type=function returns only functions", %{path: path} do
      assert {:ok, result} = Handler.execute(%{"path" => path, "type" => "function"}, ctx())
      assert result =~ "[function]"
      refute result =~ "[module]"
    end
  end

  describe "Handler.execute/2 — nonexistent file" do
    test "returns file not found error" do
      assert {:error, msg} = Handler.execute(%{"path" => "/tmp/no_such_file_osa_9999.ex"}, ctx())
      assert msg =~ "not found"
    end
  end

  describe "Handler.execute/2 — Python file" do
    setup do
      path = "/tmp/osa_sym_py_#{:rand.uniform(100_000)}.py"

      File.write!(path, """
      class MyClass:
          def my_method(self):
              pass

      async def fetch(url):
          pass
      """)

      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "finds class, function, async function", %{path: path} do
      assert {:ok, result} = Handler.execute(%{"path" => path}, ctx())
      assert result =~ "[class]"
      assert result =~ "MyClass"
      assert result =~ "[function]"
      assert result =~ "fetch"
    end
  end

  # ---------------------------------------------------------------------------
  # UI renders
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    alias OptimalSystemAgent.Tools.Builtins.CodeSymbols.UI

    test ":tool_use returns kind code_symbols" do
      map = UI.render(:tool_use, %{"path" => "/tmp/x.ex"}, [])
      assert map[:kind] == "code_symbols"
      assert map[:path] == "/tmp/x.ex"
    end

    test ":tool_result returns kind code_symbols_result" do
      map = UI.render(:tool_result, "Symbols in /tmp/x.ex:\n  L   1  [module] Foo", [])
      assert map[:kind] == "code_symbols_result"
    end

    test ":rejected returns kind code_symbols_rejected" do
      assert %{kind: "code_symbols_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind code_symbols_error" do
      map = UI.render(:error, "oops", [])
      assert map[:kind] == "code_symbols_error"
      assert map[:message] == "oops"
    end

    test "unknown stage returns nil" do
      assert UI.render(:progress, %{}, []) == nil
    end
  end
end
