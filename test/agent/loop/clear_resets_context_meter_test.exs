defmodule OptimalSystemAgent.Agent.Loop.ClearResetsContextMeterTest do
  @moduledoc """
  `POST /sessions/:id/clear` must hand back a session whose ctx meter reads
  the fresh-session floor, not the discarded conversation's stale figure —
  the number a user checks to confirm a clear actually happened (see the
  comment on the TUI's `/clear` handler in `commands.rs`).

  This drives the real HTTP route (`SessionRoutes`) against a real `Agent.Loop`
  GenServer (mock provider) rather than re-deriving the fallback inline, so a
  regression in the actual `used_context_tokens/1` -> clear-swap path fails
  here rather than only in a hand-mirrored copy of it.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Store.SessionTranscript

  @opts SessionRoutes.init([])

  setup do
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_module = Application.get_env(:optimal_system_agent, :mock_provider_module)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)

    Application.put_env(
      :optimal_system_agent,
      :mock_provider_module,
      OptimalSystemAgent.Test.MockProvider
    )

    OptimalSystemAgent.Test.MockProvider.reset()

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_module,
        do: Application.put_env(:optimal_system_agent, :mock_provider_module, prev_module),
        else: Application.delete_env(:optimal_system_agent, :mock_provider_module)
    end)

    :ok
  end

  defp call_routes(conn), do: SessionRoutes.call(conn, @opts)

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp json_get(path) do
    conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> call_routes()
  end

  defp decode_body(conn), do: Jason.decode!(conn.resp_body)

  test "the fresh session after /clear reports the floor, not the old session's inflated usage" do
    old_id = "clear-ctx-#{System.unique_integer([:positive])}"

    :ok =
      SessionManager.ensure_loop(old_id,
        user_id: "test",
        working_dir: File.cwd!(),
        provider: :mock,
        model: "mock-model-1.0"
      )

    on_exit(fn -> SessionManager.cancel(old_id) end)

    # A long-running conversation: real transcript rows (so "history" is not
    # just an in-memory list) plus an inflated `last_input_tokens` — the exact
    # field the ctx meter reads once a provider has reported real usage (see
    # `used_context_tokens/1`).
    Enum.each(1..5, fn i -> SessionTranscript.save_turn(old_id, "user", "message #{i}") end)

    assert [{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, old_id)
    :sys.replace_state(pid, fn state -> %{state | last_input_tokens: 55_123} end)

    assert {:ok, before_clear} = Loop.get_state(old_id)

    assert before_clear.tokens_used == 55_123,
           "precondition: the old session's meter reflects the inflated usage"

    conn = json_post("/#{old_id}/clear")

    assert conn.status == 201
    body = decode_body(conn)
    assert body["status"] == "cleared"
    assert body["parent_session"] == old_id

    new_id = body["id"]
    assert is_binary(new_id)
    refute new_id == old_id
    on_exit(fn -> SessionManager.cancel(new_id) end)

    # History: the fresh session starts with an empty transcript regardless of
    # how long the discarded conversation was.
    messages_conn = json_get("/#{new_id}/messages")
    messages_body = decode_body(messages_conn)
    assert messages_body["messages"] == []
    assert messages_body["count"] == 0

    # Ctx meter numerator: a brand-new Loop has no `last_input_tokens` yet, so
    # it must fall back to the pre-response static-base estimate — a small
    # fixed floor — rather than carrying over the old session's 55_123.
    assert {:ok, after_clear} = Loop.get_state(new_id)

    refute after_clear.tokens_used == 55_123,
           "the new session's ctx meter must not carry over the cleared " <>
             "session's usage — got the exact stale figure back"

    assert after_clear.tokens_used < 55_123,
           "expected the fresh session's floor (#{after_clear.tokens_used}) to be " <>
             "well under the discarded conversation's usage (55123)"
  end
end
