defmodule OptimalSystemAgent.Agent.Loop.ContextReduceTest do
  @moduledoc """
  A cheaper compaction tier: replace STALE tool-result CONTENT with a
  one-line stub (keeping the tool call that produced it), instead of paying
  for a full LLM-driven `ProactiveCompaction` summarization pass.

  Two correctness properties matter more than the mechanics:

    1. Nothing is lost — the full content is always recoverable on disk
       before the inline copy is replaced.
    2. The clearing pass is prompt-cache-aware: it is a no-op (byte-identical
       output) until enough stale candidates accumulate to cross a batch
       threshold, and once a message is stubbed it never changes again. That
       is what keeps the cached prefix stable across turns instead of
       invalidating it on every single call.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ContextReduce
  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage

  defp sid, do: "ctxreduce-#{System.unique_integer([:positive])}"

  defp user(text), do: %{role: "user", content: text}

  defp assistant_with_call(id, name, args) do
    %{role: "assistant", content: "", tool_calls: [%{id: id, name: name, arguments: args}]}
  end

  defp tool_result(id, name, content) do
    %{role: "tool", tool_call_id: id, name: name, content: content}
  end

  defp assistant_reply(text), do: %{role: "assistant", content: text}

  # One full "turn": user ask -> assistant tool call -> tool result -> assistant reply.
  defp big_turn(n, tool_name) do
    id = "call_#{n}"

    [
      user("do thing #{n}"),
      assistant_with_call(id, tool_name, %{"path" => "file_#{n}.ex"}),
      tool_result(id, tool_name, String.duplicate("x", 2_000)),
      assistant_reply("done #{n}")
    ]
  end

  defp many_turns(count, opts \\ []) do
    1..count |> Enum.flat_map(&big_turn(&1, Keyword.get(opts, :tool_name, "shell_execute")))
  end

  describe "below the batch threshold — a stable no-op" do
    test "fewer stale candidates than batch_size leaves messages byte-identical" do
      messages = many_turns(3)

      {out, stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 1,
          batch_size: 5,
          min_bytes: 100
        )

      assert out == messages
      assert stats.cleared == 0
    end
  end

  describe "keep_recent_turns — the hot window is never touched" do
    test "tool results inside the most recent N turns survive regardless of size" do
      messages = many_turns(10)

      {out, stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 10,
          batch_size: 1,
          min_bytes: 10,
          session_id: sid()
        )

      assert out == messages
      assert stats.cleared == 0
    end
  end

  describe "batched clearing" do
    setup do
      session = sid()
      on_exit(fn -> ToolResultStorage.cleanup(session) end)
      {:ok, session: session}
    end

    test "once enough stale candidates accumulate, they are all cleared in one pass", %{
      session: session
    } do
      messages = many_turns(8)

      {out, stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 2,
          batch_size: 3,
          min_bytes: 100,
          session_id: session
        )

      # 8 turns, last 2 kept hot -> 6 tool results are candidates, all >= batch_size(3).
      assert stats.cleared == 6
      assert stats.bytes_saved > 0

      tool_messages = Enum.filter(out, &(Map.get(&1, :role) == "tool"))
      {cleared, kept} = Enum.split(tool_messages, 6)

      for msg <- cleared do
        assert msg.content =~ "[Tool result cleared —"
        assert msg.content =~ "shell_execute"
      end

      for msg <- kept do
        refute msg.content =~ "[Tool result cleared —"
        assert String.starts_with?(msg.content, "xxxx")
      end

      # The tool CALLS themselves (the assistant messages) are untouched.
      assistant_calls = Enum.filter(out, &match?(%{tool_calls: [_ | _]}, &1))
      assert length(assistant_calls) == 8
      for msg <- assistant_calls, do: assert(msg.content == "")
    end

    test "the full original content is persisted to disk and recoverable", %{session: session} do
      messages = many_turns(5)

      {out, _stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 1,
          batch_size: 2,
          min_bytes: 100,
          session_id: session
        )

      cleared = out |> Enum.filter(&(Map.get(&1, :role) == "tool")) |> List.first()
      assert [_, path] = Regex.run(~r/Full output: (\S+)\./, cleared.content)
      assert File.exists?(path)
      assert File.read!(path) == String.duplicate("x", 2_000)
    end

    test "is idempotent — a second pass over already-cleared output changes nothing", %{
      session: session
    } do
      messages = many_turns(6)

      {once, stats1} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 1,
          batch_size: 2,
          min_bytes: 100,
          session_id: session
        )

      {twice, stats2} =
        ContextReduce.clear_stale_tool_results(once,
          keep_recent_turns: 1,
          batch_size: 2,
          min_bytes: 100,
          session_id: session
        )

      assert stats1.cleared > 0
      assert twice == once
      assert stats2.cleared == 0
    end

    test "reuses an existing on-disk reference instead of writing a duplicate file", %{
      session: session
    } do
      full_text = String.duplicate("z", 5_000)
      existing_path = Path.join(System.tmp_dir!(), "ctxreduce-existing-#{session}.txt")
      File.write!(existing_path, full_text)
      on_exit(fn -> File.rm(existing_path) end)

      already_offloaded_content =
        "head preview\n\n… omitted …\n\ntail preview\n\n" <>
          "[Full output written to #{existing_path} (999 lines, 4.9KB) — read it with file_read.]"

      messages = [
        user("first ask"),
        assistant_with_call("call_x", "shell_execute", %{}),
        tool_result("call_x", "shell_execute", already_offloaded_content),
        assistant_reply("ok"),
        user("second ask — keeps the previous turn out of the hot window"),
        assistant_with_call("call_y", "shell_execute", %{}),
        tool_result("call_y", "shell_execute", String.duplicate("q", 1_000)),
        assistant_reply("ok 2")
      ]

      {out, stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 1,
          batch_size: 1,
          min_bytes: 100,
          session_id: session
        )

      # Only the FIRST turn's tool result is outside the 1-turn hot window —
      # the second turn's result is the in-flight turn and must survive.
      assert stats.cleared == 1
      cleared = out |> Enum.filter(&(Map.get(&1, :role) == "tool")) |> List.first()
      assert cleared.content =~ existing_path
      # The pre-existing file's content is exactly what it was — never rewritten.
      assert File.read!(existing_path) == full_text
    end

    test "never touches block-shaped (e.g. image) tool content" do
      messages =
        [
          user("first"),
          assistant_with_call("call_img", "file_read", %{}),
          tool_result("call_img", "file_read", [
            %{type: "text", text: "Image: foo.png"},
            %{type: "image", source: %{type: "base64", media_type: "image/png", data: "AAAA"}}
          ]),
          assistant_reply("ok")
        ] ++ many_turns(4)

      {out, _stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 1,
          batch_size: 1,
          min_bytes: 10
        )

      image_msg = Enum.find(out, &(Map.get(&1, :tool_call_id) == "call_img"))
      assert is_list(image_msg.content)
    end

    test "includes a short argument hint from the matching tool call", %{session: session} do
      messages = many_turns(5)

      {out, _stats} =
        ContextReduce.clear_stale_tool_results(messages,
          keep_recent_turns: 1,
          batch_size: 2,
          min_bytes: 100,
          session_id: session
        )

      cleared = out |> Enum.filter(&(Map.get(&1, :role) == "tool")) |> List.first()
      assert cleared.content =~ "file_1.ex"
    end
  end

  describe "options default sensibly" do
    test "clear_stale_tool_results/1 works with no opts at all" do
      assert {messages, %{cleared: 0}} = ContextReduce.clear_stale_tool_results([user("hi")])
      assert messages == [user("hi")]
    end
  end
end
