defmodule OptimalSystemAgent.CriticalFlowsRegressionTest do
  @moduledoc """
  Regression tests for the critical-flow blockers/crashes fixed in this pass:

    * #1  Anthropic.format_messages/1 must not raise on JSON-restored
          (string-keyed) tool_call history — the amnesia-class resume crash.
    * #12 Pasted/attached images must reach the model as image content blocks.
    * #17 The Integrity plug must exempt auth/channel/health routes by full path.
    * #18 CacheBodyReader must stash the exact raw request bytes for HMAC verify.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Channels.HTTP.CacheBodyReader
  alias OptimalSystemAgent.Channels.HTTP.Integrity

  describe "#1 Anthropic.format_messages/1 — restored (string-keyed) tool_calls" do
    test "does not raise and preserves ids when history is JSON round-tripped" do
      # Live shape: atom-keyed tool_calls with a nested arguments map.
      live = %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "toolu_abc", name: "file_read", arguments: %{"path" => "/x"}}]
      }

      # Simulate SessionPersistence/Checkpoint restore: JSON round-trip then
      # re-atomize ONLY the top-level keys (nested tool_calls stay string-keyed).
      restored =
        live
        |> Jason.encode!()
        |> Jason.decode!()
        |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

      # tool_calls list is now [%{"id" => ..., "name" => ..., "arguments" => ...}]
      assert [%{"id" => "toolu_abc"}] = restored.tool_calls

      formatted = Anthropic.format_messages([restored])

      assert [%{"role" => "assistant", "content" => blocks}] = formatted

      tool_use = Enum.find(blocks, &(&1["type"] == "tool_use"))
      assert tool_use["id"] == "toolu_abc"
      assert tool_use["name"] == "file_read"
      assert tool_use["input"] == %{"path" => "/x"}
    end

    test "still works for live atom-keyed tool_calls" do
      msg = %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "t1", name: "shell_execute", arguments: %{"command" => "ls"}}]
      }

      assert [%{"content" => blocks}] = Anthropic.format_messages([msg])
      assert Enum.any?(blocks, &(&1["id"] == "t1"))
    end
  end

  describe "#12 image threading" do
    test "build_messages/3 emits image content blocks for image entries" do
      state = %{turn_count: 0, permission_tier: :full}
      b64 = Base.encode64("fake-png-bytes")

      messages = MessageHandler.build_messages("what is in this image", state, [b64])

      user_msg = List.last(messages)
      assert user_msg.role == "user"
      assert is_list(user_msg.content)

      assert Enum.any?(user_msg.content, &match?(%{type: "text"}, &1))

      image_block = Enum.find(user_msg.content, &match?(%{type: "image"}, &1))
      assert image_block.source.type == "base64"
      assert image_block.source.data == b64
    end

    test "build_messages/3 with no images keeps a plain string user turn" do
      state = %{turn_count: 0, permission_tier: :full}
      messages = MessageHandler.build_messages("hello", state, [])
      assert List.last(messages) == %{role: "user", content: "hello"}
    end
  end

  describe "#17 Integrity route exemptions (full request_path)" do
    test "auth login is exempt even when a shared secret is configured" do
      conn = %Plug.Conn{request_path: "/api/v1/auth/login", path_info: ["auth", "login"]}
      assert Integrity.call(conn, []) == conn
      refute Integrity.call(conn, []).halted
    end

    test "channel webhooks are exempt" do
      conn = %Plug.Conn{request_path: "/api/v1/channels/slack/events"}
      assert Integrity.call(conn, []) == conn
    end

    test "health is exempt" do
      conn = %Plug.Conn{request_path: "/health"}
      assert Integrity.call(conn, []) == conn
    end
  end

  describe "#18 CacheBodyReader stashes raw bytes" do
    test "caches the exact request body in assigns.raw_body" do
      conn = Plug.Test.conn(:post, "/api/v1/channels/slack/events", ~s({"a":1,"b":2}))
      {:ok, body, conn} = CacheBodyReader.read_body(conn, [])

      assert body == ~s({"a":1,"b":2})
      assert conn.assigns.raw_body == ~s({"a":1,"b":2})
    end
  end
end
