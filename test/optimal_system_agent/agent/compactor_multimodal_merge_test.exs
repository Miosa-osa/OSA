defmodule OptimalSystemAgent.Agent.CompactorMultimodalMergeTest do
  @moduledoc """
  Step 2 of compaction merges consecutive same-role messages. It used to do so
  with `safe_to_string(a) <> "\\n" <> safe_to_string(b)`, and `safe_to_string/1`
  `Jason.encode!`s a list — so two consecutive user messages carrying the
  multimodal block-list shape were merged into a JSON *string*.

  That is data corruption with the sign flipped on the whole step: the image is
  destroyed as an image, and the base64 that the estimator deliberately charges
  a flat rate becomes plain text hit by the `byte_size/4` floor. A step whose
  purpose is to save tokens multiplied them, and the corrupted content is what
  reached the provider and got persisted.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor

  defp image_block do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => "image/png",
        "data" => String.duplicate("A", 4000)
      }
    }
  end

  defp merge(messages) do
    messages
    |> Enum.map(&{&1, 1.0})
    |> Compactor.merge_consecutive()
    |> Enum.map(fn {msg, _imp} -> msg end)
  end

  test "two multimodal user messages merge as blocks, not as JSON text" do
    a = %{role: "user", content: [%{"type" => "text", "text" => "look"}, image_block()]}
    b = %{role: "user", content: [%{"type" => "text", "text" => "and this"}, image_block()]}

    assert [%{content: merged}] = merge([a, b])

    assert is_list(merged), "block lists must stay lists, got: #{inspect(merged, limit: 3)}"
    assert length(merged) == 4

    assert Enum.count(merged, &(&1["type"] == "image")) == 2,
           "both images must survive as image blocks"
  end

  test "the merge cannot inflate what it was called to shrink" do
    a = %{role: "user", content: [image_block()]}
    b = %{role: "user", content: [image_block()]}

    before_tokens = Compactor.estimate_tokens([a, b])
    after_tokens = Compactor.estimate_tokens(merge([a, b]))

    assert after_tokens <= before_tokens,
           "merging grew the context from #{before_tokens} to #{after_tokens} tokens"
  end

  test "a binary joining a block list is wrapped, keeping the list's key style" do
    string_keyed = %{role: "user", content: [%{"type" => "text", "text" => "first"}]}
    plain = %{role: "user", content: "second"}

    assert [%{content: merged}] = merge([string_keyed, plain])
    assert is_list(merged)
    assert Enum.map(merged, & &1["text"]) == ["first", "second"]

    atom_keyed = %{role: "user", content: [%{type: "text", text: "first"}]}
    assert [%{content: atom_merged}] = merge([atom_keyed, plain])
    assert Enum.map(atom_merged, & &1.text) == ["first", "second"]
  end

  test "plain text messages still merge exactly as before" do
    a = %{role: "assistant", content: "one"}
    b = %{role: "assistant", content: "two"}

    assert [%{content: "one\ntwo"}] = merge([a, b])
  end

  test "an unmergeable content shape declines rather than corrupting" do
    a = %{role: "user", content: %{"weird" => "map"}}
    b = %{role: "user", content: %{"other" => "map"}}

    # Two messages out, both intact — one extra message costs far less than a
    # destroyed one.
    assert [^a, ^b] = merge([a, b])
  end
end
