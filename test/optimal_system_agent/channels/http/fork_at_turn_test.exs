defmodule OptimalSystemAgent.Channels.HTTP.API.ForkAtTurnTest do
  @moduledoc """
  Fork-at-turn (primitive #34): POST /sessions/:id/fork with an optional
  turn/message index seeds a new session with history up to that point.
  Whole-session fork (no index) preserves the prior behaviour.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes
  alias OptimalSystemAgent.Store.SessionTranscript

  @opts SessionRoutes.init([])

  setup do
    prev = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :require_auth, prev),
        else: Application.delete_env(:optimal_system_agent, :require_auth)
    end)

    :ok
  end

  defp fork(src, body) do
    conn(:post, "/#{src}/fork", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SessionRoutes.call(@opts)
  end

  defp seed(n) do
    # Collision-proof id: SessionTranscript is backed by persistent SQLite, and
    # System.unique_integer/1 resets to small ints on each fresh `mix test` BEAM,
    # so ids like "…-1" collided across runs and this test appended onto a prior
    # run's leftover turns (seeing 5/7/8 instead of n). Random bytes never collide.
    src = "fork-turn-src-" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    Enum.each(1..n, fn i -> SessionTranscript.save_turn(src, "user", "m#{i}") end)
    src
  end

  test "whole-session fork seeds the full transcript" do
    src = seed(4)
    conn = fork(src, %{})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)

    assert body["status"] == "resumed"
    assert body["source_session"] == src
    assert body["message_count"] == 4
    assert body["forked_at"] == nil
    assert length(SessionTranscript.get_transcript(body["id"])) == 4
  end

  test "fork-at-turn seeds only turns up to and including the index" do
    src = seed(5)
    body = fork(src, %{"turn" => 2}) |> then(&Jason.decode!(&1.resp_body))

    assert body["message_count"] == 3
    assert body["forked_at"] == 2
    assert length(SessionTranscript.get_transcript(body["id"])) == 3
  end

  test "index 0 seeds a single turn" do
    src = seed(3)
    body = fork(src, %{"index" => 0}) |> then(&Jason.decode!(&1.resp_body))

    assert body["message_count"] == 1
    assert body["forked_at"] == 0
  end

  test "numeric string index is accepted" do
    src = seed(4)
    body = fork(src, %{"message_index" => "1"}) |> then(&Jason.decode!(&1.resp_body))

    assert body["message_count"] == 2
    assert body["forked_at"] == 1
  end

  test "out-of-range index clamps to the transcript length" do
    src = seed(3)
    body = fork(src, %{"up_to" => 99}) |> then(&Jason.decode!(&1.resp_body))

    assert body["message_count"] == 3
    assert body["forked_at"] == 2
  end

  test "forking a session with no transcript yields an empty seed" do
    src = "fork-empty-#{System.unique_integer([:positive])}"
    body = fork(src, %{"turn" => 2}) |> then(&Jason.decode!(&1.resp_body))

    assert body["message_count"] == 0
    assert body["forked_at"] == nil
  end
end
