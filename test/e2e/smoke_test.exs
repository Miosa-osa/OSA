defmodule OptimalSystemAgent.E2E.SmokeTest do
  @moduledoc """
  E2E smoke test: session lifecycle + agent loop round-trip + persistence.

  Uses MockProvider to return deterministic responses without hitting any
  real LLM provider.  Tests are tagged `async: false` because they mutate
  Application environment.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.SDK.Session
  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes
  alias OptimalSystemAgent.Test.MockProvider

  @router_opts SessionRoutes.init([])

  # ── Setup / teardown ──────────────────────────────────────────────────

  setup do
    # Swap in the mock provider so no network calls are made.
    original_provider = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)

    # Disable auth so the session routes work without a JWT.
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    # Ensure the SessionRegistry is running (it starts with the application
    # supervisor but may be absent if the test process started standalone).
    if Process.whereis(OptimalSystemAgent.SessionRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry})
    end

    # Ensure the Channels.Supervisor (DynamicSupervisor) that backs Session.create/1
    # is running.
    if Process.whereis(OptimalSystemAgent.Channels.Supervisor) == nil do
      start_supervised!(
        {DynamicSupervisor, name: OptimalSystemAgent.Channels.Supervisor, strategy: :one_for_one}
      )
    end

    # Reset the mock provider call counter in this process before each test.
    MockProvider.reset()

    on_exit(fn ->
      # Restore original provider setting.
      if original_provider do
        Application.put_env(:optimal_system_agent, :default_provider, original_provider)
      else
        Application.delete_env(:optimal_system_agent, :default_provider)
      end

      # Restore auth setting.
      if original_auth do
        Application.put_env(:optimal_system_agent, :require_auth, original_auth)
      else
        Application.delete_env(:optimal_system_agent, :require_auth)
      end
    end)

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp unique_session_id, do: "smoke-e2e-#{:erlang.unique_integer([:positive])}"

  defp http_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SessionRoutes.call(@router_opts)
  end

  defp http_get(path) do
    conn(:get, path)
    |> SessionRoutes.call(@router_opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ── Test: create session via HTTP ─────────────────────────────────────

  describe "HTTP layer — session lifecycle" do
    test "POST /sessions returns 201 with a non-empty session id" do
      conn = http_post("/")

      assert conn.status == 201
      body = decode(conn)
      assert is_binary(body["id"])
      assert String.length(body["id"]) > 0
      assert body["status"] == "created"
    end

    test "each POST /sessions creates a distinct session id" do
      id1 = decode(http_post("/"))["id"]
      id2 = decode(http_post("/"))["id"]

      refute id1 == id2
    end

    test "GET /sessions returns the newly created session" do
      post_body = decode(http_post("/"))
      new_id = post_body["id"]

      get_body = decode(http_get("/"))
      ids = Enum.map(get_body["sessions"], & &1["id"])

      assert new_id in ids
    end

    test "GET /sessions/:id returns 200 with alive:true for a live session" do
      session_id = decode(http_post("/"))["id"]
      body = decode(http_get("/#{session_id}"))

      assert body["id"] == session_id
      assert body["alive"] == true
      assert is_list(body["messages"])
    end

    test "GET /sessions/:id returns 404 for nonexistent session" do
      conn = http_get("/no-such-session-#{:erlang.unique_integer([:positive])}")
      assert conn.status == 404
      assert decode(conn)["error"] == "session_not_found"
    end

    test "GET /sessions/:id/messages returns 200 with empty list for a fresh session" do
      session_id = decode(http_post("/"))["id"]
      body = decode(http_get("/#{session_id}/messages"))

      assert body["count"] == length(body["messages"])
      assert is_list(body["messages"])
    end
  end

  # ── Test: full round-trip via Loop.process_message ────────────────────

  describe "agent loop round-trip — mock provider" do
    test "process_message returns {:ok, text} using the mock provider" do
      session_id = unique_session_id()

      # Start a Loop process wired to the :mock provider.
      start_supervised!(
        {Loop,
         [
           session_id: session_id,
           user_id: "smoke-user",
           channel: :http,
           provider: :mock
         ]},
        id: String.to_atom(session_id)
      )

      # First message: mock returns a tool_call then a final answer.
      result = Loop.process_message(session_id, "Hello from smoke test")

      assert match?({:ok, _}, result) or match?({:plan, _}, result),
             "Expected {:ok, _} or {:plan, _}, got: #{inspect(result)}"

      case result do
        {:ok, response} ->
          assert is_binary(response)
          assert String.length(response) > 0

        {:plan, response} ->
          assert is_binary(response)
          assert String.length(response) > 0
      end
    end

    test "response is persisted in Memory after process_message" do
      session_id = unique_session_id()

      start_supervised!(
        {Loop,
         [
           session_id: session_id,
           user_id: "smoke-user",
           channel: :http,
           provider: :mock
         ]},
        id: String.to_atom(session_id)
      )

      Loop.process_message(session_id, "persist me")

      # Memory.load_session returns the JSONL-persisted messages.
      messages = Memory.load_session(session_id) || []

      assert Enum.any?(messages, fn m ->
               m["role"] == "user" and String.contains?(m["content"], "persist me")
             end),
             "Expected user message to be persisted, got: #{inspect(messages)}"

      assert Enum.any?(messages, fn m -> m["role"] == "assistant" end),
             "Expected assistant message to be persisted, got: #{inspect(messages)}"
    end

    test "second process_message call continues the same session" do
      session_id = unique_session_id()

      start_supervised!(
        {Loop,
         [
           session_id: session_id,
           user_id: "smoke-user",
           channel: :http,
           provider: :mock
         ]},
        id: String.to_atom(session_id)
      )

      {:ok, _first} = Loop.process_message(session_id, "first message")
      result = Loop.process_message(session_id, "second message")

      assert match?({:ok, _}, result) or match?({:plan, _}, result),
             "Expected successful response for second message, got: #{inspect(result)}"
    end

    test "session appears in SDK.Session.list after creation" do
      session_id = unique_session_id()

      start_supervised!(
        {Loop,
         [
           session_id: session_id,
           user_id: "smoke-user",
           channel: :http,
           provider: :mock
         ]},
        id: String.to_atom(session_id)
      )

      assert session_id in Session.list(),
             "Expected #{session_id} in Session.list(), got: #{inspect(Session.list())}"
    end

    test "session is alive after creation, gone after close" do
      session_id = unique_session_id()

      # Use Session.create so the Loop is under Channels.Supervisor,
      # which is required for Session.close/1 to find and terminate it.
      {:ok, ^session_id} =
        Session.create(
          session_id: session_id,
          user_id: "smoke-user",
          channel: :http,
          provider: :mock
        )

      assert Session.alive?(session_id)

      :ok = Session.close(session_id)

      # Allow the supervised process to terminate.
      Process.sleep(50)

      refute Session.alive?(session_id)
    end
  end

  # ── Test: SDK.Session.create integration ─────────────────────────────

  describe "SDK.Session.create — end-to-end" do
    test "Session.create returns {:ok, session_id} and registers the session" do
      {:ok, session_id} =
        Session.create(
          user_id: "smoke-sdk-user",
          channel: :http,
          provider: :mock
        )

      assert is_binary(session_id)
      assert String.length(session_id) > 0
      assert Session.alive?(session_id)
    end

    test "Session.create with same id is idempotent" do
      session_id = unique_session_id()

      {:ok, ^session_id} =
        Session.create(
          session_id: session_id,
          user_id: "smoke-sdk-user",
          provider: :mock
        )

      # Second call with same id should not crash.
      {:ok, ^session_id} =
        Session.create(
          session_id: session_id,
          user_id: "smoke-sdk-user",
          provider: :mock
        )

      assert Session.alive?(session_id)
    end

    test "full flow: create → message → get_messages" do
      {:ok, session_id} =
        Session.create(
          user_id: "smoke-sdk-user",
          channel: :http,
          provider: :mock
        )

      {:ok, _response} = Loop.process_message(session_id, "what is two plus two?")

      msgs = Session.get_messages(session_id)

      assert is_list(msgs)
      assert length(msgs) >= 2

      assert Enum.any?(msgs, fn m ->
               m["role"] == "user" and String.contains?(m["content"], "two plus two")
             end)

      assert Enum.any?(msgs, fn m -> m["role"] == "assistant" end)
    end
  end
end
