defmodule OptimalSystemAgent.Protocol.ContextRefsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Protocol.ContextRefs

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-context-refs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    file_path = Path.join(dir, "greeting.txt")
    File.write!(file_path, "line one\nline two\nline three\nline four\nline five\n")

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir, file_path: file_path}
  end

  describe "inject/3 — backward compatibility" do
    test "nil context_refs leaves input unchanged" do
      assert ContextRefs.inject("hello world", nil, nil) == "hello world"
    end

    test "empty context_refs list leaves input unchanged" do
      assert ContextRefs.inject("hello world", [], "/tmp") == "hello world"
    end

    test "non-list context_refs (malformed) leaves input unchanged" do
      assert ContextRefs.inject("hello world", "not-a-list", nil) == "hello world"
    end
  end

  describe "inject/3 — file refs" do
    test "resolves an absolute file ref and injects its full content", %{file_path: file_path} do
      refs = [%{"type" => "file", "path" => file_path}]

      result = ContextRefs.inject("look at this", refs, nil)

      assert result =~ "look at this"
      assert result =~ "<context-ref type=\"file\""
      assert result =~ file_path
      assert result =~ "line one"
      assert result =~ "line five"
    end

    test "resolves a relative file ref against working_dir", %{dir: dir} do
      refs = [%{"type" => "file", "path" => "greeting.txt"}]

      result = ContextRefs.inject("hi", refs, dir)

      assert result =~ "line one"
      assert result =~ "line five"
    end

    test "a line range slices the file to just those lines (start-end)", %{file_path: file_path} do
      refs = [%{"type" => "file", "path" => file_path, "range" => "2-3"}]

      result = ContextRefs.inject("check", refs, nil)

      assert result =~ "line two"
      assert result =~ "line three"
      refute result =~ "line one"
      refute result =~ "line four"
      assert result =~ "range=\"2-3\""
    end

    test "a single-line range (\"start\" only) slices to exactly that line", %{
      file_path: file_path
    } do
      refs = [%{"type" => "file", "path" => file_path, "range" => "4"}]

      result = ContextRefs.inject("check", refs, nil)

      assert result =~ "line four"
      refute result =~ "line three"
      refute result =~ "line five"
    end

    test "a missing file is noted as an error, not silently dropped" do
      refs = [%{"type" => "file", "path" => "/nonexistent/does-not-exist.txt"}]

      result = ContextRefs.inject("check", refs, nil)

      assert result =~ "check"
      assert result =~ "error=\"unreadable\""
    end
  end

  describe "inject/3 — agent refs" do
    test "an agent ref is carried into the context block" do
      refs = [%{"type" => "agent", "name" => "debugger"}]

      result = ContextRefs.inject("please look", refs, nil)

      assert result =~ "please look"
      assert result =~ "<context-ref type=\"agent\" name=\"debugger\">"
      assert result =~ "debugger"
    end

    test "an agent ref without a name is skipped (no crash, no empty block)" do
      refs = [%{"type" => "agent"}]

      assert ContextRefs.inject("hello", refs, nil) == "hello"
    end
  end

  describe "inject/3 — mixed refs" do
    test "file and agent refs both resolve in one turn", %{file_path: file_path} do
      refs = [
        %{"type" => "file", "path" => file_path},
        %{"type" => "agent", "name" => "reviewer"}
      ]

      result = ContextRefs.inject("go", refs, nil)

      assert result =~ "line one"
      assert result =~ "reviewer"
    end

    test "an unknown ref type is skipped without breaking the others", %{file_path: file_path} do
      refs = [
        %{"type" => "carrier-pigeon", "path" => "whatever"},
        %{"type" => "file", "path" => file_path}
      ]

      result = ContextRefs.inject("go", refs, nil)

      assert result =~ "line one"
    end
  end
end
