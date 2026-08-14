defmodule OptimalSystemAgent.Providers.OllamaImagesTest do
  @moduledoc """
  Ollama had no image path at all.

  It was honestly instrumented — an attached image was replaced with a
  model-visible sentence saying it had not been sent — which is better than
  hallucinating one. But the sentence said "OSA's integration for the provider
  serving this request cannot send images", and the only reason it could not was
  that `format_messages/1` had never learned Ollama's native shape: images ride
  as an `"images"` SIBLING of `"content"` on the message, base64, no data: URI
  and no media type. Multimodal models on Ollama are common
  (`OllamaCloud` even tracks a `vision:` flag per model, which nothing consulted).

  These tests pin the wire shape and, just as importantly, the two things that
  must NOT happen: no `images` key when there is no image, and no pretending an
  http(s) URL is base64.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Ollama
  alias OptimalSystemAgent.Providers.Registry

  @b64 "iVBORw0KGgoAAAANSUhEUg=="

  defp image_block(data \\ @b64) do
    %{type: "image", source: %{type: "base64", media_type: "image/png", data: data}}
  end

  describe "format_messages/1 with image content" do
    test "puts base64 images in the native sibling field, text in content" do
      [msg] =
        Ollama.format_messages([
          %{
            role: "user",
            content: [%{type: "text", text: "What is in this?"}, image_block()]
          }
        ])

      assert msg["role"] == "user"
      assert msg["content"] == "What is in this?"
      assert msg["images"] == [@b64]
    end

    test "carries several images in order" do
      [msg] =
        Ollama.format_messages([
          %{
            role: "user",
            content: [image_block("AAA"), %{type: "text", text: "vs"}, image_block("BBB")]
          }
        ])

      assert msg["images"] == ["AAA", "BBB"]
      assert msg["content"] == "vs"
    end

    test "omits the images key entirely when there is no image" do
      # A present-but-empty `images` list is not the same message, and some
      # servers treat it differently. Absence must stay absence.
      [msg] = Ollama.format_messages([%{role: "user", content: "plain text"}])

      refute Map.has_key?(msg, "images")
      assert msg["content"] == "plain text"

      [blocks] = Ollama.format_messages([%{role: "user", content: [%{type: "text", text: "hi"}]}])
      refute Map.has_key?(blocks, "images")
      assert blocks["content"] == "hi"
    end

    test "a tool result carrying an image keeps its attribution fields" do
      # This is the `Read`-an-image-file shape that `ToolExecutor` builds. Before
      # this change `to_string/1` on the block list raised Protocol.UndefinedError
      # here, which is why the Registry flattened ahead of the provider.
      [msg] =
        Ollama.format_messages([
          %{
            role: "tool",
            tool_call_id: "call_1",
            name: "file_read",
            content: [%{type: "text", text: "Image: /tmp/a.png"}, image_block()]
          }
        ])

      assert msg["role"] == "tool"
      assert msg["tool_call_id"] == "call_1"
      assert msg["name"] == "file_read"
      assert msg["content"] == "Image: /tmp/a.png"
      assert msg["images"] == [@b64]
    end

    test "accepts an OpenAI-shaped data: URL but refuses a remote URL" do
      # Ollama has no fetch path. Sending it an https URL in the base64 slot
      # would be a lie in the request body, so the part contributes nothing and
      # the Registry's accounting stays the one place a loss is reported.
      [ok] =
        Ollama.format_messages([
          %{
            role: "user",
            content: [%{type: "image_url", image_url: %{url: "data:image/png;base64,#{@b64}"}}]
          }
        ])

      assert ok["images"] == [@b64]

      [refused] =
        Ollama.format_messages([
          %{
            role: "user",
            content: [%{type: "image_url", image_url: %{url: "https://example.com/a.png"}}]
          }
        ])

      refute Map.has_key?(refused, "images")
    end

    test "string-keyed blocks from a rehydrated session are handled" do
      [msg] =
        Ollama.format_messages([
          %{
            role: "user",
            content: [
              %{"type" => "text", "text" => "rehydrated"},
              %{"type" => "image", "source" => %{"data" => @b64}}
            ]
          }
        ])

      assert msg["content"] == "rehydrated"
      assert msg["images"] == [@b64]
    end
  end

  describe "the Registry transport gate" do
    test "Ollama now declares that its transport carries images" do
      # `Registry.transport_carries_images?/1` asks the provider module this
      # question; Ollama not exporting it was what selected the
      # "cannot send images" placeholder for every attached image.
      assert Ollama.supports_image_content?()
    end

    test "image blocks reach the provider instead of being flattened to a placeholder" do
      messages = [%{role: "user", content: [%{type: "text", text: "look"}, image_block()]}]

      [out] =
        Registry.normalize_message_content(messages, OptimalSystemAgent.Providers.Ollama,
          model: "llava:7b"
        )

      assert is_list(out.content)
      assert Enum.any?(out.content, &match?(%{type: "image"}, &1))
      refute is_binary(out.content) and String.contains?(out.content, "cannot send images")
    end
  end
end
