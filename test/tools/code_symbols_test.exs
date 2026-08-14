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
      assert Tool.should_defer?() == true
    end

    # False while `should_defer?/0` is true. See `Tools.DeferFlagConsistencyTest`.
    test "always_load? is false, because this tool defers" do
      assert Tool.always_load?() == false
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

    test "CodeSymbols.always_load?() is false, matching the tool it shims" do
      assert CodeSymbolsShim.always_load?() == false
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

  # ---------------------------------------------------------------------------
  # `name` — one definition instead of grep-then-read
  # ---------------------------------------------------------------------------

  describe "definition extraction" do
    setup do
      dir = Path.join(System.tmp_dir!(), "osa_symbols_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    defp write(dir, name, content) do
      path = Path.join(dir, name)
      File.write!(path, content)
      path
    end

    test "returns the python definition and its line range, not the file", c do
      path =
        write(c.dir, "m.py", """
        import os


        def before():
            return 0


        def target(a, b):
            total = a + b
            return total


        def after():
            return 1
        """)

      assert {:ok, out} = Handler.execute(%{"path" => path, "name" => "target"}, ctx())

      assert out =~ "def target(a, b):"
      assert out =~ "return total"
      # The neighbours are what a fixed read window would have dragged in.
      refute out =~ "def before"
      refute out =~ "def after"
      assert out =~ ":8-10"
      assert byte_size(out) < byte_size(File.read!(path))
    end

    test "returns a C function body, closing brace included", c do
      path =
        write(c.dir, "m.c", """
        #include <stdio.h>

        int add(int a, int b)
        {
            return a + b;
        }

        int main(void)
        {
            return add(1, 2);
        }
        """)

      assert {:ok, out} = Handler.execute(%{"path" => path, "name" => "add"}, ctx())
      assert out =~ "int add(int a, int b)"
      assert out =~ "return a + b;"
      refute out =~ "int main"
    end

    test "outlines a shell script's functions", c do
      path =
        write(c.dir, "s.sh", """
        #!/bin/bash
        setup() {
          mkdir -p /tmp/x
        }

        function teardown {
          echo done
        }
        """)

      assert {:ok, out} = Handler.execute(%{"path" => path}, ctx())
      assert out =~ "setup"
    end

    test "a name that is not defined here says so and does not guess", c do
      path = write(c.dir, "m.py", "def alpha():\n    return 1\n")

      assert {:ok, out} = Handler.execute(%{"path" => path, "name" => "beta"}, ctx())
      assert out =~ "No symbol named \"beta\" is DEFINED"
      refute out =~ "def alpha"
    end

    test "a near-miss name is offered back", c do
      path = write(c.dir, "m.py", "def fetch_user_by_id():\n    return 1\n")

      assert {:ok, out} = Handler.execute(%{"path" => path, "name" => "fetch_user"}, ctx())
      assert out =~ "fetch_user_by_id"
    end

    test "a non-string name is refused before any file is opened" do
      assert {:error, msg, -32_602} = Handler.validate(%{"path" => "/x", "name" => 42}, ctx())

      assert msg =~ "name must be a string"
    end

    test "the outline is unchanged when name is omitted", c do
      path = write(c.dir, "m.py", "def alpha():\n    return 1\n")

      assert {:ok, out} = Handler.execute(%{"path" => path}, ctx())
      assert out =~ "Symbols in"
      assert out =~ "[function] alpha"
    end
  end
end
