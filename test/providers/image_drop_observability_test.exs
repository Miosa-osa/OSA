defmodule OptimalSystemAgent.Providers.ImageDropObservabilityTest do
  @moduledoc """
  When OSA destroys an attached image, an operator has to be able to find out.

  Until now the only trace was the replacement sentence sitting inside the
  prompt: visible to the model, invisible to every log, metric and dashboard.
  `Ollama.apply_tools/3` already emits `[:osa, :ollama, :tools_stripped]` on
  exactly this reasoning — "a capability silently removed must never be a
  decision someone has to go looking for" — and the image gate had no equivalent.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry

  @image %{type: "image", source: %{type: "base64", media_type: "image/png", data: "AAAA"}}

  setup do
    handler = "image-drop-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:osa, :images, :dropped],
      fn _event, measurements, metadata, _ ->
        send(test, {:dropped, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "dropping images for a transport that cannot carry them is reported" do
    messages = [%{role: "user", content: [%{type: "text", text: "look"}, @image, @image]}]

    # Cohere exports no `supports_image_content?/0`, so the transport gate is
    # false and both images are replaced with the placeholder sentence.
    Registry.normalize_message_content(messages, OptimalSystemAgent.Providers.Cohere,
      model: "command-r-plus"
    )

    assert_receive {:dropped, %{count: 2}, %{reason: :transport, provider: :cohere}}
  end

  test "a turn with no images says nothing" do
    # Structured content is usually cache markers or plain text parts, and a
    # "0 images dropped" event on every turn is noise — which is its own way of
    # being invisible.
    messages = [%{role: "user", content: [%{type: "text", text: "no pictures here"}]}]

    Registry.normalize_message_content(messages, OptimalSystemAgent.Providers.Cohere,
      model: "command-r-plus"
    )

    refute_receive {:dropped, _, _}, 100
  end

  test "a transport that CAN carry images reports nothing" do
    messages = [%{role: "user", content: [%{type: "text", text: "look"}, @image]}]

    Registry.normalize_message_content(messages, OptimalSystemAgent.Providers.Ollama,
      model: "llava:7b"
    )

    refute_receive {:dropped, _, _}, 100
  end
end
