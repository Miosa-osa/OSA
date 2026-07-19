defmodule OptimalSystemAgent.Providers.ImageBudgetTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ImageBudget

  # Build a user message carrying a single inline base64 image whose `data`
  # payload is `size` bytes. The base64 alphabet contains no JSON-escaped
  # characters, so `size` is also the exact serialized contribution of the data.
  defp image_msg(tag, size) do
    %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => "image #{tag}"},
        %{
          "type" => "image",
          "source" => %{
            "type" => "base64",
            "media_type" => "image/png",
            "data" => String.duplicate("A", size)
          }
        }
      ]
    }
  end

  defp text_msg(role, text), do: %{"role" => role, "content" => text}

  # Is the image in message `idx` still an image (vs evicted to a placeholder)?
  defp image?(body, idx) do
    body
    |> get_in([Access.key(:messages), Access.at(idx), "content"])
    |> Enum.any?(&(&1["type"] == "image"))
  end

  defp placeholder?(body, idx) do
    body
    |> get_in([Access.key(:messages), Access.at(idx), "content"])
    |> Enum.any?(&(&1["type"] == "text" and &1["text"] == ImageBudget.placeholder()))
  end

  defp count_images(body) do
    body[:messages]
    |> Enum.map(fn m ->
      case m["content"] do
        content when is_list(content) ->
          Enum.count(content, &(is_map(&1) and &1["type"] == "image"))

        _ ->
          0
      end
    end)
    |> Enum.sum()
  end

  describe "no-op when under budget" do
    test "returns the body byte-for-byte unchanged" do
      body = %{
        model: "claude-sonnet-4-6",
        messages: [
          text_msg("user", "hello"),
          image_msg("a", 500),
          image_msg("b", 500)
        ]
      }

      result = ImageBudget.apply(body, cap_bytes: 100_000_000)

      assert result == body
      assert count_images(result) == 2
      refute placeholder?(result, 1)
    end

    test "body with no images at all is unchanged" do
      body = %{
        model: "m",
        messages: [text_msg("user", "hi"), text_msg("assistant", "yo")]
      }

      assert ImageBudget.apply(body, cap_bytes: 10) == body
    end
  end

  describe "over-budget eviction" do
    test "evicts the oldest image and keeps the newest" do
      body = %{
        model: "m",
        messages: [
          image_msg("oldest", 2_000),
          image_msg("middle", 2_000),
          image_msg("newest", 2_000)
        ]
      }

      current = ImageBudget.body_byte_size(body)
      # Trigger just below current forces eviction; reclaim just below current
      # means exactly the single oldest image is evicted.
      result =
        ImageBudget.apply(body,
          cap_bytes: current,
          trigger_bytes: current - 1,
          reclaim_bytes: current - 1
        )

      # Oldest evicted to placeholder, newer images untouched.
      assert placeholder?(result, 0)
      refute image?(result, 0)
      assert image?(result, 1)
      assert image?(result, 2)
      assert count_images(result) == 2
    end

    test "measured body shrinks after eviction" do
      body = %{
        model: "m",
        messages: [image_msg("a", 3_000), image_msg("b", 3_000)]
      }

      current = ImageBudget.body_byte_size(body)

      result =
        ImageBudget.apply(body,
          cap_bytes: current,
          trigger_bytes: current - 1,
          reclaim_bytes: current - 1
        )

      assert ImageBudget.body_byte_size(result) < current
    end
  end

  describe "hysteresis" do
    test "reclaims down to the low-water mark, not just below the trigger" do
      body = %{
        model: "m",
        messages:
          for i <- 1..6 do
            image_msg("img#{i}", 4_000)
          end
      }

      current = ImageBudget.body_byte_size(body)
      reclaim = div(current, 2)

      # Gate right at the ceiling but reclaim all the way to half.
      result =
        ImageBudget.apply(body,
          cap_bytes: current,
          trigger_bytes: current - 1,
          reclaim_bytes: reclaim
        )

      after_bytes = ImageBudget.body_byte_size(result)

      # Reclaimed to the low-water mark — strictly below the trigger, not parked
      # just under it (that is the whole point of hysteresis).
      assert after_bytes <= reclaim
      assert after_bytes < current - 1

      # A batch of oldest images went; the newest survived (oldest-first).
      assert placeholder?(result, 0)
      refute image?(result, 0)
      assert image?(result, 5)
      assert count_images(result) >= 1
      assert count_images(result) < 6
    end

    test "newest image is always the last to be evicted" do
      body = %{
        model: "m",
        messages:
          for i <- 1..5 do
            image_msg("img#{i}", 5_000)
          end
      }

      current = ImageBudget.body_byte_size(body)

      # Reclaim to nothing: every image must go (backstop path).
      result =
        ImageBudget.apply(body,
          cap_bytes: current,
          trigger_bytes: current - 1,
          reclaim_bytes: 0
        )

      assert count_images(result) == 0
      assert placeholder?(result, 0)
      assert placeholder?(result, 4)

      # With a moderate reclaim target (~half) the oldest go first and the
      # newest is retained — the keep-newest ordering property.
      partial =
        ImageBudget.apply(body,
          cap_bytes: current,
          trigger_bytes: current - 1,
          reclaim_bytes: div(current, 2)
        )

      assert image?(partial, 4)
      assert placeholder?(partial, 0)

      # Placeholders form a prefix: no kept image is older than an evicted one.
      kept_after_evicted? =
        partial[:messages]
        |> Enum.with_index()
        |> Enum.reduce({false, false}, fn {_m, idx}, {seen_kept, violated} ->
          cond do
            image?(partial, idx) -> {true, violated}
            placeholder?(partial, idx) and seen_kept -> {seen_kept, true}
            true -> {seen_kept, violated}
          end
        end)
        |> elem(1)

      refute kept_after_evicted?
    end
  end

  describe "tool_result nested images" do
    test "evicts images nested inside a tool_result block" do
      tool_result_msg = %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "t1",
            "content" => [
              %{"type" => "text", "text" => "screenshot:"},
              %{
                "type" => "image",
                "source" => %{
                  "type" => "base64",
                  "media_type" => "image/png",
                  "data" => String.duplicate("A", 4_000)
                }
              }
            ]
          }
        ]
      }

      body = %{model: "m", messages: [tool_result_msg, image_msg("newest", 4_000)]}

      current = ImageBudget.body_byte_size(body)

      result =
        ImageBudget.apply(body,
          cap_bytes: current,
          trigger_bytes: current - 1,
          reclaim_bytes: current - 1
        )

      # The nested (oldest) image is evicted to a placeholder inside the
      # tool_result content; the newest top-level image is kept.
      nested =
        result[:messages]
        |> List.first()
        |> Map.get("content")
        |> List.first()
        |> Map.get("content")

      assert Enum.any?(nested, &(&1["type"] == "text" and &1["text"] == ImageBudget.placeholder()))
      refute Enum.any?(nested, &(&1["type"] == "image"))
      assert image?(result, 1)
    end
  end

  describe "measurement" do
    test "body_byte_size equals a full Jason encode of the real body" do
      body = %{
        model: "m",
        messages: [text_msg("user", "hi \"quoted\" and \\escaped\\"), image_msg("a", 1_234)]
      }

      exact = body |> Jason.encode!() |> byte_size()
      assert ImageBudget.body_byte_size(body) == exact
    end
  end
end
