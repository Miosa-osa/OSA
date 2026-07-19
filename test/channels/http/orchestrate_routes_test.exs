defmodule OptimalSystemAgent.Channels.HTTP.OrchestrateRoutesTest do
  @moduledoc """
  Regression coverage for the OrchestrateRoutes bug fixes:

    * R1 — the per-request Bus -> PubSub bridge is gone; a normal turn's
      events are NOT duplicated on the session's PubSub topic.
    * R2 — an `:exit` inside the async agent task (the Loop GenServer crashing
      mid-turn) still emits a terminal `agent_response` + `done` frame, so the
      SSE loop in agent_routes.ex ends the turn instead of looping on
      keepalives forever.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.OrchestrateRoutes

  @opts OrchestrateRoutes.init([])

  setup do
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)
    end)

    :ok
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> OrchestrateRoutes.call(@opts)
  end

  # Registers a plain (non-GenServer) process under the same Registry name a
  # real `Agent.Loop` would use, so `SessionManager.ensure_loop/2` sees the
  # session as already live and skips starting a real loop. The process
  # blocks until told to `:die`, at which point any in-flight
  # `GenServer.call(via(session_id), ...)` targeting it raises `:exit` —
  # exactly what happens when the real Loop GenServer crashes mid-`handle_call`
  # (e.g. TurnPipeline.run raising before it gets a chance to broadcast
  # anything).
  defp start_doomed_fake_loop(session_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(OptimalSystemAgent.SessionRegistry, session_id, :test)
        send(parent, :registered)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :registered, 1_000
    pid
  end

  describe "R2: a Loop crash still emits a terminal SSE event" do
    test "an :exit while processing the message broadcasts agent_response + done" do
      session_id = "r2-crash-#{System.unique_integer([:positive])}"

      fake_loop = start_doomed_fake_loop(session_id)
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

      conn = json_post("/", %{"input" => "hello", "session_id" => session_id})
      assert conn.status == 202

      # Kill the fake loop now that the async task has (or is about to)
      # target it via GenServer.call — this converts the in-flight call into
      # an :exit signal in the async task, the same shape as a real Loop
      # crash inside handle_call.
      send(fake_loop, :die)

      # The old (broken) behavior: nothing ever arrives and the SSE consumer
      # hangs on keepalives forever. Fixed behavior: a terminal frame always
      # arrives, ending the turn.
      assert_receive {:osa_event, %{type: :agent_response, session_id: ^session_id}}, 5_000
      assert_receive {:osa_event, %{type: :done, session_id: ^session_id}}, 5_000
    end
  end

  describe "R1: no redundant per-request Bus -> PubSub bridge" do
    test "POST /orchestrate does not add rows to :osa_event_handlers per call" do
      count_before = :ets.info(:osa_event_handlers, :size)

      session_id = "r1-no-bridge-#{System.unique_integer([:positive])}"
      fake_loop = start_doomed_fake_loop(session_id)
      on_exit(fn -> if Process.alive?(fake_loop), do: send(fake_loop, :die) end)

      json_post("/", %{"input" => "hi", "session_id" => session_id})
      # Give the (now nonexistent) old bridge registration a moment to have
      # landed if it were still there.
      Process.sleep(50)

      count_after = :ets.info(:osa_event_handlers, :size)

      send(fake_loop, :die)

      # Before the R1 fix this route registered 4 new handlers
      # (:agent_response, :system_event, :llm_response, :tool_call) on every
      # single POST, forever leaking on a `:bag` table. It must now register
      # none.
      assert count_after == count_before
    end

    test "the route source no longer registers a per-request Bus handler" do
      source =
        "lib/optimal_system_agent/channels/http/api/orchestrate_routes.ex"
        |> File.read!()

      refute source =~ "Bus.register_handler"
    end
  end
end
