defmodule OptimalSystemAgent.Providers.AnthropicPrefillTest do
  @moduledoc """
  Regression coverage for the live v1.0.048 bug:

      Error (llm_error): Anthropic returned 400: This model does not support
      assistant message prefill. The conversation must end with a user message.

  Root cause: `Providers.Anthropic` hoisted EVERY `role: "system"` message onto
  the top-level `system` field. `ReactLoop`'s steering paths append
  `[assistant_text, system_nudge]` as a pair, so hoisting the nudge stranded the
  assistant message as the last entry in `messages` — an assistant prefill,
  which Opus/Sonnet 4.6 and the whole Claude 5 family reject with a 400.

  The fix is enforced at the provider boundary (`Anthropic.split_system/2`) so
  no caller can reintroduce the shape.

  NOTE: there is no live Anthropic key on this machine. Every test here runs
  against a local Bandit stub, so the request SHAPE is verified but the fix is
  **unverified against the real Anthropic API**.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Providers.AnthropicModels
  alias OptimalSystemAgent.Providers.ErrorCatalog

  # A 4.6+/5-family model (prefill removed) and a 4.5-era model (prefill kept).
  @no_prefill "claude-opus-5"
  @prefill "claude-haiku-4-5"

  # The exact message pair ReactLoop's steering paths append: the assistant's
  # text, then the system-role nudge meant to be the last thing the model reads.
  # This is the shape that produced the 400 in the field.
  defp steering_history do
    [
      %{role: "system", content: "You are OSA."},
      %{role: "user", content: "Fix the failing test."},
      %{role: "assistant", content: "I'll read the file.", tool_calls: []},
      %{role: "tool", tool_call_id: "toolu_1", content: "defmodule Foo do end"},
      %{role: "assistant", content: "I would now edit the file."},
      %{
        role: "system",
        content:
          "[System: You described what you would do but did not call any tools. " <>
            "EXECUTE by calling the appropriate tools NOW.]"
      }
    ]
  end

  defp last_role(msgs), do: msgs |> List.last() |> Map.fetch!("role")

  defp text_of(msg) do
    case msg["content"] do
      c when is_binary(c) -> c
      blocks when is_list(blocks) -> Enum.map_join(blocks, "", &(&1["text"] || ""))
    end
  end

  describe "split_system/2 — the exact shape that produced the 400" do
    test "history ending in a hoisted system nudge no longer ends with assistant" do
      formatted = Anthropic.format_messages(steering_history())

      # Reproduce the OLD behaviour to prove the bug is real, not theoretical.
      {_old_system, old_chat} = Enum.split_with(formatted, &(&1["role"] == "system"))

      assert last_role(old_chat) == "assistant",
             "precondition: the old split_with really did strand an assistant message last"

      # New behaviour.
      {system_text, chat} = Anthropic.split_system(formatted, @no_prefill)

      assert last_role(chat) == "user"
      assert system_text == "You are OSA."
    end

    test "the steering nudge still reaches the model verbatim" do
      {_system, chat} =
        steering_history()
        |> Anthropic.format_messages()
        |> Anthropic.split_system(@no_prefill)

      last = List.last(chat)

      assert last["role"] == "user"

      assert text_of(last) =~ "did not call any tools",
             "the nudge is meaningful steering — it must survive normalization, not be dropped"

      assert text_of(last) =~ "EXECUTE by calling the appropriate tools NOW"
    end

    test "the assistant text preceding the nudge is preserved in place" do
      {_system, chat} =
        steering_history()
        |> Anthropic.format_messages()
        |> Anthropic.split_system(@no_prefill)

      assistant_texts =
        chat |> Enum.filter(&(&1["role"] == "assistant")) |> Enum.map(&text_of/1)

      assert Enum.any?(assistant_texts, &(&1 =~ "I would now edit the file"))
    end

    test "only LEADING system messages become the system prompt" do
      {system_text, chat} =
        [
          %{role: "system", content: "Prompt A"},
          %{role: "system", content: "Prompt B"},
          %{role: "user", content: "hi"},
          %{role: "assistant", content: "hello"},
          %{role: "system", content: "[System: mid-turn steering]"}
        ]
        |> Anthropic.format_messages()
        |> Anthropic.split_system(@no_prefill)

      assert system_text == "Prompt A\n\nPrompt B"

      refute Enum.any?(chat, &(&1["role"] == "system")),
             "a mid-conversation role:system message 400s on Sonnet 5 / Haiku / 4.6 / 4.7"

      assert last_role(chat) == "user"
      assert text_of(List.last(chat)) =~ "mid-turn steering"
    end
  end

  describe "split_system/2 — trailing-assistant safety net" do
    test "a bare trailing assistant message is normalized, and its content survives" do
      {_system, chat} =
        [
          %{role: "system", content: "sys"},
          %{role: "user", content: "write a haiku"},
          %{role: "assistant", content: "An old silent pond—"}
        ]
        |> Anthropic.format_messages()
        |> Anthropic.split_system(@no_prefill)

      assert last_role(chat) == "user"

      # The partial reply is NOT dropped; it stays where it was.
      assert Enum.any?(chat, fn m ->
               m["role"] == "assistant" and text_of(m) =~ "An old silent pond"
             end)

      # ...and the appended turn tells the model to resume rather than restart.
      assert text_of(List.last(chat)) =~ "Continue from exactly where it stopped"
    end

    test "a model that DOES support prefill is left byte-for-byte unchanged" do
      formatted =
        Anthropic.format_messages([
          %{role: "system", content: "sys"},
          %{role: "user", content: "write a haiku"},
          %{role: "assistant", content: "An old silent pond—"}
        ])

      {_system, chat} = Anthropic.split_system(formatted, @prefill)

      assert last_role(chat) == "assistant"
      assert chat == Enum.reject(formatted, &(&1["role"] == "system"))
    end

    test "an unknown model is treated as prefill-unsupported (safe direction)" do
      refute AnthropicModels.supports_prefill?("claude-some-future-model")

      {_system, chat} =
        [%{role: "user", content: "hi"}, %{role: "assistant", content: "partial"}]
        |> Anthropic.format_messages()
        |> Anthropic.split_system("claude-some-future-model")

      assert last_role(chat) == "user"
    end

    test "a history already ending in user is not touched" do
      formatted =
        Anthropic.format_messages([
          %{role: "system", content: "sys"},
          %{role: "assistant", content: "hi"},
          %{role: "user", content: "go on"}
        ])

      {_system, chat} = Anthropic.split_system(formatted, @no_prefill)
      assert chat == Enum.reject(formatted, &(&1["role"] == "system"))
    end

    test "a history ending in a tool result is not touched (tool results are user turns)" do
      {_system, chat} =
        [
          %{role: "user", content: "run it"},
          %{
            role: "assistant",
            content: "",
            tool_calls: [%{id: "t1", name: "sh", arguments: %{}}]
          },
          %{role: "tool", tool_call_id: "t1", content: "ok"}
        ]
        |> Anthropic.format_messages()
        |> Anthropic.split_system(@no_prefill)

      assert last_role(chat) == "user"
      assert length(chat) == 3, "no extra continuation turn should be appended"
    end

    test "an empty conversation stays empty" do
      assert {"sys", []} =
               Anthropic.split_system(
                 Anthropic.format_messages([%{role: "system", content: "sys"}]),
                 @no_prefill
               )
    end
  end

  describe "AnthropicModels.supports_prefill?/1" do
    test "false for every 4.6+ / Claude 5 model in the catalog" do
      for id <- ~w(claude-opus-5 claude-sonnet-5 claude-fable-5 claude-opus-4-8
                   claude-opus-4-7 claude-opus-4-6 claude-sonnet-4-6) do
        refute AnthropicModels.supports_prefill?(id), "#{id} must not be sent a prefill"
      end
    end

    test "true for Haiku 4.5, which predates the removal" do
      assert AnthropicModels.supports_prefill?("claude-haiku-4-5")
    end

    test "nil model id defaults to unsupported" do
      refute AnthropicModels.supports_prefill?(nil)
    end
  end

  describe "ErrorCatalog — a request-shape 400 must not blame the model" do
    @live_error "Anthropic returned 400: This model does not support assistant message prefill. The conversation must end with a user message."

    test "classifies the live error as :request_shape, not :unknown" do
      assert ErrorCatalog.classify(@live_error) == :request_shape
    end

    test "the user-facing message does not tell the user to switch models" do
      msg = ErrorCatalog.user_message(@live_error)

      refute msg =~ "/model to switch models",
             "switching models cannot fix a malformed request — every model rejects it"

      assert msg =~ "bug in OSA"
      assert msg =~ "switching models will not help"
    end

    test "other request-shape 400s are covered too" do
      for reason <- [
            "Anthropic returned 400: messages: roles must alternate between \"user\" and \"assistant\"",
            "Anthropic returned 400: first message must start with a user message",
            "Anthropic returned 400: role 'system' is not supported on this model"
          ] do
        assert ErrorCatalog.classify(reason) == :request_shape, "missed: #{reason}"
      end
    end

    test "unrelated 400s still classify as :invalid_request via the HTTP path" do
      assert ErrorCatalog.classify({:http_error, 400, "something else entirely"}) ==
               :invalid_request
    end

    test "rate limits and auth errors are unaffected" do
      assert ErrorCatalog.classify({:rate_limited, 30}) == :rate_limit

      assert ErrorCatalog.classify("Anthropic returned 401: invalid x-api-key") ==
               :invalid_api_key
    end
  end

  # ── Dispatch-level: assert the wire body, with the HTTP layer stubbed ──────
  describe "do_chat/5 dispatch (stubbed HTTP)" do
    setup do
      base = String.to_integer(System.get_env("OSA_HTTP_PORT") || "10231")
      test_pid = self()

      # Walk forward from the configured base until a port binds: the previous
      # test's listener can still be in TIME_WAIT when the next one starts.
      {server, port} = start_stub(base, test_pid, 0)

      prev_url = Application.get_env(:optimal_system_agent, :anthropic_url)
      prev_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)
      Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")

      on_exit(fn ->
        if prev_url,
          do: Application.put_env(:optimal_system_agent, :anthropic_url, prev_url),
          else: Application.delete_env(:optimal_system_agent, :anthropic_url)

        if prev_key,
          do: Application.put_env(:optimal_system_agent, :anthropic_api_key, prev_key),
          else: Application.delete_env(:optimal_system_agent, :anthropic_api_key)

        Process.exit(server, :normal)
      end)

      :ok
    end

    test "the body actually sent for the bug's history ends with a user message" do
      Anthropic.chat(steering_history(), model: @no_prefill)

      assert_receive {:captured_body, body}, 5_000

      messages = body["messages"]
      assert List.last(messages)["role"] == "user"

      refute Enum.any?(messages, &(&1["role"] == "system")),
             "system-role messages must never appear in the messages array"

      assert body["system"] == "You are OSA."
    end

    test "prefill-supporting models still send the assistant message last" do
      history = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "write a haiku"},
        %{role: "assistant", content: "An old silent pond—"}
      ]

      Anthropic.chat(history, model: @prefill)

      assert_receive {:captured_body, body}, 5_000
      assert List.last(body["messages"])["role"] == "assistant"
    end
  end

  defp start_stub(_base, _test_pid, attempt) when attempt > 20 do
    flunk("could not bind a stub HTTP port after 20 attempts")
  end

  defp start_stub(base, test_pid, attempt) do
    port = base + attempt

    # Probe first: Bandit.start_link/1 LINKS, so an :eaddrinuse kills the test
    # process instead of returning {:error, _} — it cannot be rescued inline.
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.CapturePlug, test_pid},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, test_pid, attempt + 1)
    end
  end

  defmodule CapturePlug do
    @moduledoc false
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, raw, conn} = read_body(conn)
      send(test_pid, {:captured_body, Jason.decode!(raw)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      )
    end
  end
end
