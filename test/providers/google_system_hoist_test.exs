defmodule OptimalSystemAgent.Providers.GoogleSystemHoistTest do
  @moduledoc """
  Regression coverage for the message-hoist bug in `Providers.Google`.

  Root cause (identical to the Anthropic one fixed in v1.0.53):

      Enum.split_with(messages, &(&1["role"] == "system"))

  hoisted EVERY `role: "system"` message onto Gemini's top-level
  `systemInstruction`, regardless of where it sat in the conversation.
  `ReactLoop`'s steering paths append `[assistant_text, system_nudge]` as a
  pair, so the nudge — written to redirect the model mid-turn — was lifted out
  of `contents` and buried in background context.

  On Anthropic this produced a hard 400 (trailing assistant prefill). Gemini
  accepts a trailing `model` turn, so on Google it failed **silently**: no
  error, just degraded steering that nothing reported.

  The fix: only LEADING system messages become `systemInstruction`; a
  mid-conversation system message stays in `contents`, demoted to a `user`
  turn. `ensure_trailing_user/2` is deliberately NOT ported — Gemini accepts a
  trailing `model` turn, so it would only inject phantom turns.

  NOTE: there is no live Google API key on this machine. Every test here runs
  against a local Bandit stub, so the request SHAPE is verified but the fix is
  **unverified against the real Gemini API**.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Google

  @model "gemini-3.6-flash"

  # The exact message pair ReactLoop's steering paths append.
  @nudge "[CRITICAL: You wrote code in markdown instead of using a tool. " <>
           "You MUST call file_write with the code as content to create the file NOW.]"

  defp steering_history do
    [
      %{role: "system", content: "You are OSA."},
      %{role: "user", content: "Create hello.exs"},
      %{role: "assistant", content: "Here is the code:\n\n```elixir\nIO.puts(1)\n```"},
      %{role: "system", content: @nudge}
    ]
  end

  defp text_of(content), do: Enum.map_join(content["parts"], "", &(&1["text"] || ""))

  describe "extract_system — leading vs mid-conversation system messages" do
    test "a LEADING system message becomes systemInstruction" do
      {system_text, contents} =
        Google.build_contents([
          %{role: "system", content: "Prompt A"},
          %{role: "system", content: "Prompt B"},
          %{role: "user", content: "hi"}
        ])

      assert system_text == "Prompt A\n\nPrompt B"
      assert [%{"role" => "user"}] = contents
    end

    test "a MID-CONVERSATION system message does NOT become systemInstruction" do
      # Reproduce the OLD behaviour first, to prove the bug was real.
      formatted = [
        %{"role" => "system", "content" => "You are OSA."},
        %{"role" => "user", "content" => "hi"},
        %{"role" => "assistant", "content" => "hello"},
        %{"role" => "system", "content" => @nudge}
      ]

      {old_sys, _} = Enum.split_with(formatted, &(&1["role"] == "system"))

      assert length(old_sys) == 2,
             "precondition: the old split_with really did hoist the mid-turn nudge"

      {system_text, contents} = Google.build_contents(formatted)

      assert system_text == "You are OSA.",
             "only the leading system message may reach systemInstruction"

      refute system_text =~ "file_write"
      assert Enum.any?(contents, &(text_of(&1) =~ "file_write"))
    end

    test "the demoted nudge appears LAST in contents, with role user" do
      {_system, contents} = Google.build_contents(steering_history())

      assert [
               %{"role" => "user"},
               %{"role" => "model"},
               %{"role" => "user"} = last
             ] = contents

      assert text_of(last) == @nudge, "the steering text must reach the model verbatim"
    end

    test "the assistant text preceding the nudge is preserved in place, as role model" do
      {_system, contents} = Google.build_contents(steering_history())

      model_turns = Enum.filter(contents, &(&1["role"] == "model"))
      assert Enum.any?(model_turns, &(text_of(&1) =~ "IO.puts(1)"))
    end

    test "no content ever carries role \"system\" — Gemini has no such role" do
      {_system, contents} = Google.build_contents(steering_history())
      assert Enum.all?(contents, &(&1["role"] in ["user", "model"]))
    end

    test "a conversation with no system message is unchanged" do
      {system_text, contents} =
        Google.build_contents([
          %{role: "user", content: "hi"},
          %{role: "assistant", content: "hello"},
          %{role: "user", content: "again"}
        ])

      assert system_text == nil
      assert Enum.map(contents, & &1["role"]) == ["user", "model", "user"]
      assert Enum.map(contents, &text_of/1) == ["hi", "hello", "again"]
    end

    test "an empty conversation stays empty" do
      assert {nil, []} = Google.build_contents([])
    end

    test "a system-only conversation yields a systemInstruction and no contents" do
      assert {"sys", []} = Google.build_contents([%{role: "system", content: "sys"}])
    end
  end

  describe "consecutive same-role turns are collapsed" do
    test "a demoted nudge following a user turn merges instead of doubling role user" do
      {_system, contents} =
        Google.build_contents([
          %{role: "system", content: "sys"},
          %{role: "user", content: "do it"},
          %{role: "system", content: @nudge}
        ])

      assert [%{"role" => "user"} = only] = contents,
             "Google's reference says roles should alternate; consecutive user turns are " <>
               "reported as 400 INVALID_ARGUMENT, so they are collapsed"

      assert length(only["parts"]) == 2
      assert text_of(only) == "do it" <> @nudge
    end

    test "roles never repeat after collapsing" do
      {_system, contents} =
        Google.build_contents([
          %{role: "user", content: "a"},
          %{role: "system", content: "b"},
          %{role: "system", content: "c"},
          %{role: "assistant", content: "d"},
          %{role: "assistant", content: "e"},
          %{role: "user", content: "f"}
        ])

      roles = Enum.map(contents, & &1["role"])
      assert roles == ["user", "model", "user"]
      refute Enum.any?(Enum.zip(roles, tl(roles)), fn {a, b} -> a == b end)
    end

    test "tool round-trip turns are NOT merged — function parts keep their own turn" do
      {_system, contents} =
        Google.build_contents([
          %{role: "system", content: "sys"},
          %{role: "user", content: "read it"},
          %{
            role: "assistant",
            content: "",
            tool_calls: [%{id: "c1", name: "file_read", arguments: %{"path" => "a.ex"}}]
          },
          %{role: "tool", tool_call_id: "c1", content: "contents of a.ex"},
          %{role: "system", content: @nudge}
        ])

      assert [
               %{"role" => "user", "parts" => [%{"text" => "read it"}]},
               %{"role" => "model", "parts" => [%{"functionCall" => call}]},
               %{"role" => "user", "parts" => [%{"functionResponse" => resp}]},
               %{"role" => "user", "parts" => [%{"text" => @nudge}]}
             ] = contents

      assert call["name"] == "file_read"
      assert resp["name"] == "file_read"
      assert resp["response"] == %{"result" => "contents of a.ex"}
    end
  end

  # ── Dispatch-level: assert the real serialized wire body ───────────────────
  describe "chat/2 dispatch (stubbed HTTP)" do
    setup do
      base =
        String.to_integer(System.get_env("OSA_HTTP_PORT") || "10331") +
          rem(System.unique_integer([:positive]), 10_000)

      test_pid = self()
      {server, port} = start_stub(base, test_pid, 0)

      prev_url = Application.get_env(:optimal_system_agent, :google_url)
      prev_key = Application.get_env(:optimal_system_agent, :google_api_key)
      Application.put_env(:optimal_system_agent, :google_url, "http://127.0.0.1:#{port}/v1beta")
      Application.put_env(:optimal_system_agent, :google_api_key, "not-a-real-key")

      on_exit(fn ->
        if prev_url,
          do: Application.put_env(:optimal_system_agent, :google_url, prev_url),
          else: Application.delete_env(:optimal_system_agent, :google_url)

        if prev_key,
          do: Application.put_env(:optimal_system_agent, :google_api_key, prev_key),
          else: Application.delete_env(:optimal_system_agent, :google_api_key)

        Supervisor.stop(server)
      end)

      :ok
    end

    test "the body actually sent keeps the steering nudge last, in contents" do
      assert {:ok, _response} = Google.chat(steering_history(), model: @model)

      assert_receive {:captured_body, body}, 5_000

      contents = body["contents"]
      last = List.last(contents)

      assert last["role"] == "user"
      assert text_of(last) == @nudge

      assert body["systemInstruction"]["parts"] == [%{"text" => "You are OSA."}],
             "only the leading system message may be hoisted"

      refute Enum.any?(contents, &(&1["role"] == "system"))
    end

    test "auth still goes in the x-goog-api-key header, not a ?key= query param" do
      assert {:ok, _response} = Google.chat(steering_history(), model: @model)

      assert_receive {:captured_request, req}, 5_000

      assert req.headers["x-goog-api-key"] == "not-a-real-key"
      refute req.query =~ "key="
      assert req.path == "/v1beta/models/#{@model}:generateContent"
    end

    test "a request with no system message sends no systemInstruction at all" do
      assert {:ok, _response} = Google.chat([%{role: "user", content: "hi"}], model: @model)

      assert_receive {:captured_body, body}, 5_000

      refute Map.has_key?(body, "systemInstruction")
      assert [%{"role" => "user", "parts" => [%{"text" => "hi"}]}] = body["contents"]
    end

    test "thinking config is still emitted for Gemini 3.x (no regression)" do
      assert {:ok, _response} =
               Google.chat([%{role: "user", content: "hi"}],
                 model: @model,
                 reasoning_effort: "high"
               )

      assert_receive {:captured_body, body}, 5_000
      assert body["generationConfig"]["thinkingLevel"] == "high"
    end
  end

  defp start_stub(_base, _test_pid, attempt) when attempt > 20 do
    flunk("could not bind a stub HTTP port after 20 attempts")
  end

  defp start_stub(base, test_pid, attempt) do
    port = base + attempt

    # Probe first: Bandit.start_link/1 LINKS, so an :eaddrinuse kills the test
    # process instead of returning {:error, _}.
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

        Process.unlink(server)
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

      send(
        test_pid,
        {:captured_request,
         %{
           path: conn.request_path,
           query: conn.query_string || "",
           headers: Map.new(conn.req_headers)
         }}
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}],
          "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 1}
        })
      )
    end
  end
end
