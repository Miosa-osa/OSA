defmodule OptimalSystemAgent.Agent.ImageContentCrashTest do
  @moduledoc """
  Regression: attaching an image makes a message's `content` a LIST of typed
  blocks (`[%{type: "text", ..}, %{type: "image", ..}]`). Several message
  scanners did `to_string(content)`, which raises
  `ArgumentError: cannot convert the given list to a string` on a list — so
  pasting an image crashed the whole turn (surfaced to the user as
  "I hit an error processing that request: ArgumentError...").
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Utils.Text, as: Utils

  @image_message %{
    role: "user",
    content: [
      %{type: "text", text: "[Image #2] [Image #3] Look at this"},
      %{type: "image", source: %{data: "iVBORw0KGgoAAAANS"}}
    ]
  }

  describe "Utils.content_text/1" do
    test "returns the prose of a block list, dropping image blocks, without raising" do
      assert Utils.content_text(@image_message.content) == "[Image #2] [Image #3] Look at this"
    end

    test "passes a plain string through" do
      assert Utils.content_text("hello") == "hello"
    end

    test "nil becomes empty string" do
      assert Utils.content_text(nil) == ""
    end

    test "joins multiple text blocks with blank lines" do
      blocks = [%{"text" => "one"}, %{type: "image", source: %{data: "x"}}, %{text: "two"}]
      assert Utils.content_text(blocks) == "one\n\ntwo"
    end
  end

  describe "Loop.scaffold_message?/1 with image content" do
    test "does not raise on block-list content (the reported crash)" do
      # Before the fix this raised ArgumentError and killed the turn.
      assert Loop.scaffold_message?(@image_message) == false
    end

    test "still detects a real task-notification marker" do
      assert Loop.scaffold_message?(%{role: "user", content: "<task-notification>x</task-notification>"})
    end
  end
end
