defmodule OptimalSystemAgent.Providers.ToolCallDedupTest do
  @moduledoc """
  P2 audit gap B: duplicate tool_use/tool_call stream events must not both
  execute. This is the stream-parse-layer dedup unit-tested directly; the
  provider integration is covered in `ollama_test.exs` / `anthropic_test.exs`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ToolCallDedup

  @call %{id: "call_1", name: "file_read", arguments: %{"path" => "/tmp/x"}}

  describe "classify/2" do
    test "a call with a fresh id is :new" do
      assert ToolCallDedup.classify([], @call) == :new
      assert ToolCallDedup.classify([%{id: "other", name: "x", arguments: %{}}], @call) == :new
    end

    test "an exact repeat (same id, name, arguments) is :exact_duplicate" do
      assert ToolCallDedup.classify([@call], @call) == :exact_duplicate
    end

    test "same id, different arguments is :conflict" do
      conflicting = %{@call | arguments: %{"path" => "/tmp/y"}}
      assert ToolCallDedup.classify([@call], conflicting) == :conflict
    end

    test "same id, different name is :conflict" do
      conflicting = %{@call | name: "file_write"}
      assert ToolCallDedup.classify([@call], conflicting) == :conflict
    end

    test "a missing id is always :new" do
      no_id = %{name: "file_read", arguments: %{}}
      assert ToolCallDedup.classify([no_id], no_id) == :new
    end
  end

  describe "append/2" do
    test "appends a new call in order" do
      other = %{id: "call_2", name: "file_read", arguments: %{"path" => "/tmp/y"}}
      assert ToolCallDedup.append([@call], other) == [@call, other]
    end

    test "drops an exact duplicate — the list is unchanged" do
      assert ToolCallDedup.append([@call], @call) == [@call]
    end

    test "keeps both on a genuine conflict, so ToolOrchestrator.uniquify_ids/1 can repair it" do
      conflicting = %{@call | arguments: %{"path" => "/tmp/y"}}
      assert ToolCallDedup.append([@call], conflicting) == [@call, conflicting]
    end
  end

  describe "append_all/2" do
    test "dedupes a batch against what is already accumulated" do
      other = %{id: "call_2", name: "file_read", arguments: %{"path" => "/tmp/y"}}
      result = ToolCallDedup.append_all([@call], [other, @call])
      assert result == [@call, other]
    end
  end

  describe "prepend/2" do
    test "prepends a new call, keeping newest-first order" do
      other = %{id: "call_2", name: "file_read", arguments: %{"path" => "/tmp/y"}}
      assert ToolCallDedup.prepend([@call], other) == [other, @call]
    end

    test "drops an exact duplicate regardless of list order" do
      assert ToolCallDedup.prepend([@call], @call) == [@call]
    end
  end
end
