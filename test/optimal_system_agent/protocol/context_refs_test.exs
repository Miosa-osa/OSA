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

  describe "inject/3 — attachment policy" do
    # A `context_ref` is the non-image twin of an `images` path: the same class
    # of user-chosen file arriving on the same request body. It got no policy
    # check at all — `resolve_file/3` read whatever path was named and injected
    # it verbatim into the outbound prompt — which is the exact
    # arbitrary-file-read primitive v1.0.79 closed on `images`, one field over.
    #
    # The policy is the USER one: readable from anywhere (an `@`-mention of a
    # file outside the workspace is legitimate), never a credential store.

    test "a sensitive file named by a ref is refused, not read" do
      key = Path.join([System.user_home!(), ".ssh", "id_rsa"])
      refs = [%{"type" => "file", "path" => key}]

      result = ContextRefs.inject("summarise this", refs, nil)

      assert result =~ "error=\"denied\""
      assert result =~ "sensitive"
      refute result =~ "PRIVATE KEY"
    end

    test "a .env named by a ref is refused", %{dir: dir} do
      dotenv = Path.join(dir, ".env")
      File.write!(dotenv, "STRIPE_SECRET=sk_live_dont_leak_me")

      result = ContextRefs.inject("go", [%{"type" => "file", "path" => dotenv}], nil)

      assert result =~ "error=\"denied\""
      refute result =~ "sk_live_dont_leak_me"
    end

    test "a symlink whose target is sensitive is refused (canonicalisation)", %{dir: dir} do
      link = Path.join(dir, "innocent.txt")
      :ok = File.ln_s(Path.join([System.user_home!(), ".ssh", "id_rsa"]), link)

      result = ContextRefs.inject("go", [%{"type" => "file", "path" => link}], nil)

      assert result =~ "error=\"denied\""
    end

    test "an ordinary file outside the workspace still resolves", %{file_path: file_path} do
      # The user picked it; location is not the objection. `file_path` lives in
      # the OS temp directory, outside any project root.
      result = ContextRefs.inject("go", [%{"type" => "file", "path" => file_path}], nil)

      assert result =~ "line one"
      refute result =~ "error="
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
