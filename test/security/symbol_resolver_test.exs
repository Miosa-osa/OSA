defmodule OptimalSystemAgent.Security.SymbolResolverTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.SymbolResolver

  setup do
    root = Path.join(System.tmp_dir!(), "osa-symres-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "node_modules/pkg"))

    File.write!(
      Path.join(root, "lib/a.py"),
      """
      import db

      def show(user):
          rows = build_query(user.id)
          return rows

      def build_query(user_id):
          # from_a_only
          return "SELECT * FROM users WHERE id=" + user_id
      """
    )

    File.write!(
      Path.join(root, "lib/b.py"),
      """
      def build_query(user_id):
          # from_b_only
          return "SELECT * FROM orders WHERE id=" + user_id
      """
    )

    File.write!(
      Path.join(root, "node_modules/pkg/evil.py"),
      """
      def build_query(user_id):
          return "from_node_modules"

      def only_in_nm():
          return 1
      """
    )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "code_line unique to a.py selects a.py over b.py", %{root: root} do
    assert {:ok, hit} =
             SymbolResolver.resolve("build_query",
               root: root,
               name: "build_query",
               code_line: "rows = build_query(user.id)"
             )

    assert Path.basename(hit.path) == "a.py"
    assert hit.snippet =~ "def build_query"
    assert hit.snippet =~ "from_a_only"
    refute hit.snippet =~ "from_b_only"
    refute hit.snippet =~ "from_node_modules"
    assert hit.line >= 1
    assert hit.kind == :definition
  end

  test "missing name returns :not_found", %{root: root} do
    assert :not_found =
             SymbolResolver.resolve("no_such_symbol",
               root: root,
               name: "no_such_symbol"
             )
  end

  test "reader tuple form works", %{root: root} do
    reader = SymbolResolver.reader(root)
    line = "rows = build_query(user.id)"

    assert {:ok, src} = reader.({:symbol, "build_query", line})
    assert src =~ "def build_query"
    assert src =~ "from_a_only"

    assert {:ok, src2} = reader.({"build_query", line})
    assert src2 =~ "from_a_only"

    assert {:ok, src3} = reader.("build_query")
    assert src3 =~ "def build_query"
  end

  test "skips node_modules so a fake def there does not win", %{root: root} do
    assert :not_found =
             SymbolResolver.resolve("only_in_nm", root: root, name: "only_in_nm")

    assert {:ok, hit} =
             SymbolResolver.resolve("build_query",
               root: root,
               name: "build_query",
               code_line: "rows = build_query(user.id)"
             )

    refute hit.path =~ "node_modules"
    refute hit.snippet =~ "from_node_modules"
  end

  test "empty name is an error", %{root: root} do
    assert {:error, reason} = SymbolResolver.resolve("", root: root, name: "")
    assert is_binary(reason)
    assert reason =~ "name"
  end

  test "missing root is an error" do
    assert {:error, reason} = SymbolResolver.resolve("build_query", name: "build_query")
    assert is_binary(reason)
    assert reason =~ "root"
  end

  test "call without a def returns the call-site snippet", %{root: root} do
    File.write!(
      Path.join(root, "lib/handler.py"),
      """
      def show(user):
          return mystery_helper(user.id)
      """
    )

    assert {:ok, hit} =
             SymbolResolver.resolve("mystery_helper",
               root: root,
               name: "mystery_helper",
               code_line: "return mystery_helper(user.id)"
             )

    assert Path.basename(hit.path) == "handler.py"
    assert hit.kind == :call_site
    assert hit.snippet =~ "mystery_helper"
    assert hit.line >= 1
  end
end
