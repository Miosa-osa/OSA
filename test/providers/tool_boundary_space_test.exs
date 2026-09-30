defmodule OptimalSystemAgent.Providers.ToolBoundarySpaceTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ToolBoundarySpace, as: TBS

  # Replays a chunk sequence the way the Ollama stream does, ending in a tool
  # call when `tool?`, and returns the text that reached the screen.
  defp replay(chunks, tool?) do
    {emitted, holder} =
      Enum.reduce(chunks, {"", TBS.new()}, fn chunk, {emitted, holder} ->
        {pieces, holder} = TBS.content(holder, chunk)
        {emitted <> Enum.join(pieces), holder}
      end)

    {pieces, _} = if tool?, do: TBS.tool_call(holder), else: TBS.flush(holder)
    emitted <> Enum.join(pieces)
  end

  describe "the space Ollama trims before a tool call" do
    # Every pair is a real one: either captured from the local daemon's raw
    # NDJSON, or read off the operator's saved transcripts, where it is the last
    # word of a narration line that ends in a tool call.
    for {before, last, want} <- [
          {"Checking the audit's own progress file", "instead.",
           "Checking the audit's own progress file instead."},
          {"Waiting for it to finish the", "sweep.", "Waiting for it to finish the sweep."},
          {"Collecting the duplicate", "inventory.", "Collecting the duplicate inventory."},
          {"Using Spotlight and git's own worktree registry — both", "instant.",
           "Using Spotlight and git's own worktree registry — both instant."},
          {"Let me find out why the settings read isn't picking it", "up.",
           "Let me find out why the settings read isn't picking it up."},
          {"it defaults to `true`, so it is on by", "default.",
           "it defaults to `true`, so it is on by default."},
          {"so we can inspect the settings", "read.", "so we can inspect the settings read."},
          {"why it keeps", "dropping.", "why it keeps dropping."},
          {"testing whether it actually", "responds.", "testing whether it actually responds."},
          {"so I can prune", "them.", "so I can prune them."},
          {"Checking whether", "the live node rebuilt.",
           "Checking whether the live node rebuilt."}
        ] do
      test "restores #{inspect(before <> " " <> last)}" do
        assert replay([unquote(before), unquote(last)], true) == unquote(want)
      end
    end
  end

  describe "a chunk that splits a word is left alone" do
    # Chunk boundaries inside words, captured from the same daemon mid-stream
    # (about 9% of all boundaries in measured narration). Inserting a space
    # there would trade one broken word for another.
    for {before, last} <- [
          {"so launchd resp", "awned it."},
          {"restart the da", "emon."},
          {"I will unconditionally thrott", "ling."},
          {"the launch", "d job."},
          {"tearing down each work", "trees."},
          {"counting duplicate check", "outs."},
          {"read the pl", "ist."},
          {"it will print", "ing."},
          {"there is any", "thing."}
        ] do
      test "keeps #{inspect(before <> last)} whole" do
        assert replay([unquote(before), unquote(last)], true) == unquote(before <> last)
      end
    end
  end

  describe "streams that never reach a tool boundary" do
    test "a held chunk followed by more prose is released unchanged" do
      assert replay(["the settings", "read", " is fine."], false) == "the settingsread is fine."
    end

    test "a message with no tool call is byte-for-byte unchanged" do
      assert replay(["Checking the file", "instead."], false) == "Checking the fileinstead."
    end

    test "chunks that do not touch letter against letter are never held" do
      {_, holder} = TBS.content(TBS.new(), "hello")
      {pieces, holder} = TBS.content(holder, " world")
      assert pieces == [" world"]
      assert holder.held == nil

      {_, holder} = TBS.content(TBS.new(), "path /")
      assert {["tmp"], _} = TBS.content(holder, "tmp")
    end

    test "only the candidate chunk is held, and only until the next event" do
      {["the listing"], holder} = TBS.content(TBS.new(), "the listing")
      {pieces, holder} = TBS.content(holder, "instead.")
      assert pieces == []
      {pieces, holder} = TBS.content(holder, " Next.")
      assert pieces == ["instead.", " Next."]
      assert holder.held == nil
    end

    test "a tool call with nothing held emits nothing" do
      {_, holder} = TBS.content(TBS.new(), "done.")
      assert {[], ^holder} = TBS.tool_call(holder)
    end

    test "the seam is judged on the text before it, however long the message" do
      long = String.duplicate("word ", 200) <> "so I can prune"
      assert replay([long, "them."], true) == long <> " them."
    end
  end
end
