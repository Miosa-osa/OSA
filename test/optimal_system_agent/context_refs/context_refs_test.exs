defmodule OptimalSystemAgent.ContextRefsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.ContextRefs.Hook
  alias OptimalSystemAgent.ContextRefs.Parser
  alias OptimalSystemAgent.ContextRefs.Resolvers

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "foo.ex"), Enum.map_join(1..30, "\n", &"line #{&1}"))
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/nested.txt"), "nested content")
    File.write!(Path.join(dir, "my file.txt"), "spaced content")
    File.write!(Path.join(dir, "bin.dat"), <<0, 255, 254, 1>>)
    :ok
  end

  describe "typed refs (backwards compat)" do
    test "@file: with :start-end range is stripped from cleaned text", %{tmp_dir: dir} do
      {cleaned, refs} = Parser.parse("check @file:foo.ex:10-25 please", working_dir: dir)
      assert refs == [{:file, "foo.ex", {10, 25}}]
      refute cleaned =~ "@file:"
    end

    test "@file: keeps working without an existence check" do
      {_cleaned, refs} = Parser.parse("@file:does/not/exist.ex")
      assert refs == [{:file, "does/not/exist.ex", {nil, nil}}]
    end

    test "@diff, @staged, @git still parse" do
      {_cleaned, refs} = Parser.parse("@diff @staged @git:3")
      assert {:diff, nil} in refs
      assert {:staged, nil} in refs
      assert {:git, 3} in refs
    end
  end

  describe "bare @path mentions" do
    test "bare path becomes a file ref when it exists", %{tmp_dir: dir} do
      {cleaned, refs} = Parser.parse("explain @foo.ex please", working_dir: dir)
      assert refs == [{:file, "foo.ex", {nil, nil}}]
      # bare mention text stays in the prose
      assert cleaned == "explain @foo.ex please"
    end

    test "prose @words that are not files are ignored", %{tmp_dir: dir} do
      {_cleaned, refs} =
        Parser.parse("ping @here, email a@b.com, cc @channel", working_dir: dir)

      assert refs == []
    end

    test "trailing punctuation is stripped", %{tmp_dir: dir} do
      for msg <- ["see @foo.ex.", "see @foo.ex, ok", "(see @foo.ex)"] do
        {_cleaned, refs} = Parser.parse(msg, working_dir: dir)
        assert refs == [{:file, "foo.ex", {nil, nil}}], "failed for: #{msg}"
      end
    end

    test "quoted path with spaces", %{tmp_dir: dir} do
      {_cleaned, refs} = Parser.parse(~s(read @"my file.txt" now), working_dir: dir)
      assert refs == [{:file, "my file.txt", {nil, nil}}]
    end

    test "colon range form", %{tmp_dir: dir} do
      assert {_, [{:file, "foo.ex", {10, 25}}]} =
               Parser.parse("@foo.ex:10-25", working_dir: dir)
    end

    test "Claude-Code #L range forms", %{tmp_dir: dir} do
      assert {_, [{:file, "foo.ex", {10, 20}}]} =
               Parser.parse("@foo.ex#L10-20", working_dir: dir)

      assert {_, [{:file, "foo.ex", {10, 10}}]} =
               Parser.parse("@foo.ex#L10", working_dir: dir)
    end

    test "reversed range is normalized", %{tmp_dir: dir} do
      assert {_, [{:file, "foo.ex", {10, 20}}]} =
               Parser.parse("@foo.ex#L20-10", working_dir: dir)
    end

    test "directory mention with trailing slash", %{tmp_dir: dir} do
      assert {_, [{:file, "sub/", {nil, nil}}]} = Parser.parse("list @sub/", working_dir: dir)
    end

    test "duplicate mentions dedupe", %{tmp_dir: dir} do
      {_cleaned, refs} = Parser.parse("@foo.ex and again @foo.ex", working_dir: dir)
      assert refs == [{:file, "foo.ex", {nil, nil}}]
    end

    test "agent-style mentions are never files", %{tmp_dir: dir} do
      {_cleaned, refs} = Parser.parse("ask @agent-code-reviewer", working_dir: dir)
      assert refs == []
    end

    test "typed and bare refs for the same path dedupe", %{tmp_dir: dir} do
      {_cleaned, refs} = Parser.parse("@file:foo.ex and @foo.ex", working_dir: dir)
      assert refs == [{:file, "foo.ex", {nil, nil}}]
    end
  end

  describe "Resolvers.File" do
    test "resolves relative to working_dir, not process cwd", %{tmp_dir: dir} do
      assert {:ok, block} = Resolvers.File.resolve("foo.ex", {nil, nil}, 10_000, dir)
      assert block.type == :file
      assert block.content =~ "line 1"
    end

    test "line ranges slice content", %{tmp_dir: dir} do
      assert {:ok, block} = Resolvers.File.resolve("foo.ex", {10, 12}, 10_000, dir)
      assert block.content =~ "line 10"
      assert block.content =~ "line 12"
      refute block.content =~ "line 13"
    end

    test "directory emits a capped listing, not a read error", %{tmp_dir: dir} do
      assert {:ok, block} = Resolvers.File.resolve("sub", {nil, nil}, 10_000, dir)
      assert block.type == :directory
      assert block.content =~ "nested.txt"
    end

    test "binary file is refused, not spliced into the prompt", %{tmp_dir: dir} do
      assert {:error, block} = Resolvers.File.resolve("bin.dat", {nil, nil}, 10_000, dir)
      assert block.content =~ "Binary file"
    end

    test "missing file yields a clear error block", %{tmp_dir: dir} do
      assert {:error, block} = Resolvers.File.resolve("nope.ex", {nil, nil}, 10_000, dir)
      assert block.content =~ "Error reading"
    end
  end

  describe "hook end-to-end" do
    test "bare mention attaches file content to the message", %{tmp_dir: dir} do
      payload = %{message: "explain @foo.ex", session_id: "t1", working_dir: dir}

      assert {:ok, %{message: expanded}} = Hook.user_prompt_submit(payload)
      assert expanded =~ "--- @file:foo.ex ---"
      assert expanded =~ "line 30"
    end

    test "directory mention attaches a listing", %{tmp_dir: dir} do
      payload = %{message: "what is in @sub/", session_id: "t1", working_dir: dir}

      assert {:ok, %{message: expanded}} = Hook.user_prompt_submit(payload)
      assert expanded =~ "--- @dir:sub/ ---"
      assert expanded =~ "nested.txt"
    end

    test "message with no resolvable refs skips", %{tmp_dir: dir} do
      payload = %{message: "hello @world", session_id: "t1", working_dir: dir}
      assert :skip = Hook.user_prompt_submit(payload)
    end
  end
end
