defmodule OptimalSystemAgent.Verify.PostEditTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Verify.PostEdit

  @moduletag :verify

  setup do
    dir = Path.join(System.tmp_dir!(), "post_edit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # An injected exec that records calls and returns a canned {output, code}.
  defp stub_exec(result) do
    fn program, args, _cwd -> send(self(), {:exec, program, args}); result end
  end

  describe "lang_for/1" do
    test "maps known extensions to language buckets" do
      assert PostEdit.lang_for("a.ex") == :elixir
      assert PostEdit.lang_for("a.exs") == :elixir
      assert PostEdit.lang_for("a.go") == :go
      assert PostEdit.lang_for("a.rs") == :rust
      assert PostEdit.lang_for("a.js") == :js
      assert PostEdit.lang_for("a.mjs") == :js
      assert PostEdit.lang_for("a.ts") == :ts
      assert PostEdit.lang_for("a.tsx") == :ts
      assert PostEdit.lang_for("a.py") == :python
      assert PostEdit.lang_for("a.json") == :json
    end

    test "is case-insensitive on the extension" do
      assert PostEdit.lang_for("A.EX") == :elixir
    end

    test "returns nil for unsupported or missing extensions" do
      assert PostEdit.lang_for("a.txt") == nil
      assert PostEdit.lang_for("README") == nil
      assert PostEdit.lang_for(123) == nil
    end
  end

  describe "analyze/2 — Elixir (in-process, no shell)" do
    test "reports a syntax error with file:line", %{dir: dir} do
      path = Path.join(dir, "broken.ex")
      # Missing `end` — a parse error string_to_quoted must reject.
      File.write!(path, "defmodule Broken do\n  def go do\n    :ok\nend\n")

      out = PostEdit.analyze(path, stub_exec({"", 0}))
      assert out =~ "broken.ex:"
      # No external tool was invoked for the Elixir path.
      refute_received {:exec, _, _}
    end

    test "returns empty and formats a valid file in place", %{dir: dir} do
      path = Path.join(dir, "ok.ex")
      # Deliberately mis-formatted (extra spaces) but syntactically valid.
      File.write!(path, "defmodule Ok do\n  def   go,   do:   :ok\nend\n")

      assert PostEdit.analyze(path, stub_exec({"", 0})) == ""

      formatted = File.read!(path)
      # mix-format normalises the spacing; the sloppy triple-spaces are gone.
      refute formatted =~ "def   go"
      assert formatted =~ "def go, do: :ok"
    end

    test "a syntactically invalid file is left byte-for-byte untouched", %{dir: dir} do
      path = Path.join(dir, "bad.ex")
      original = "defmodule Bad do\n  def go do\n    :ok\nend\n"
      File.write!(path, original)

      _ = PostEdit.analyze(path, stub_exec({"", 0}))
      assert File.read!(path) == original
    end
  end

  describe "analyze/2 — shelled languages via injected exec" do
    test "surfaces gofmt parse errors on non-zero exit", %{dir: dir} do
      path = Path.join(dir, "main.go")
      File.write!(path, "package main\nfunc broken( {}\n")

      out = PostEdit.analyze(path, stub_exec({"main.go:2:13: expected ')'", 2}))
      assert out =~ "expected ')'"
      assert_received {:exec, "gofmt", _}
    end

    test "returns empty when the tool reports a clean exit", %{dir: dir} do
      path = Path.join(dir, "main.go")
      File.write!(path, "package main\n")
      assert PostEdit.analyze(path, stub_exec({"", 0})) == ""
    end

    test "skips cleanly when the tool binary is missing", %{dir: dir} do
      path = Path.join(dir, "main.rs")
      File.write!(path, "fn main() {}\n")
      # {:__missing__, prog} is the sentinel default_exec returns for an absent binary.
      assert PostEdit.analyze(path, fn _p, _a, _c -> {:__missing__, "rustfmt"} end) == ""
    end

    test "clamps very long diagnostics", %{dir: dir} do
      path = Path.join(dir, "main.go")
      File.write!(path, "package main\n")
      huge = String.duplicate("x", 5_000)
      out = PostEdit.analyze(path, stub_exec({huge, 1}))
      assert byte_size(out) <= 1500
    end
  end

  describe "analyze/2 — routing" do
    test "unsupported extension is a no-op", %{dir: dir} do
      path = Path.join(dir, "notes.txt")
      File.write!(path, "hello")
      assert PostEdit.analyze(path, stub_exec({"boom", 1})) == ""
      refute_received {:exec, _, _}
    end
  end

  describe "run/2 — provider entrypoint + config gate" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :post_edit_verify)
      on_exit(fn -> Application.put_env(:optimal_system_agent, :post_edit_verify, prev) end)
      :ok
    end

    test "returns empty when disabled by config", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :post_edit_verify, enabled: false)
      path = Path.join(dir, "broken.ex")
      File.write!(path, "defmodule X do")
      assert PostEdit.run(path, %{}) == ""
    end

    test "runs and reports when enabled, honoring an injected cmd_fun", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :post_edit_verify, enabled: true)
      path = Path.join(dir, "main.go")
      File.write!(path, "package main\n")
      out = PostEdit.run(path, %{cmd_fun: stub_exec({"main.go:1: oops", 1})})
      assert out =~ "oops"
    end

    test "returns empty for a nonexistent file", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :post_edit_verify, enabled: true)
      assert PostEdit.run(Path.join(dir, "ghost.ex"), %{}) == ""
    end
  end
end
