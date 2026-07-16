defmodule OptimalSystemAgent.Channels.HTTP.API.RewindRoutesTest do
  @moduledoc """
  Tests for RewindRoutes:
    GET  /:session_id      — list checkpoints
    GET  /:session_id/:id  — full entry
    POST /restore          — restore code / conversation / both
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OptimalSystemAgent.Channels.HTTP.API.RewindRoutes
  alias OptimalSystemAgent.Agent.Loop.Checkpoint

  @opts RewindRoutes.init([])

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_rewind_routes_#{System.unique_integer([:positive])}")
    prev_rewind = Application.get_env(:optimal_system_agent, :rewind_checkpoint_dir)
    prev_crash = Application.get_env(:optimal_system_agent, :checkpoint_dir)

    Application.put_env(:optimal_system_agent, :rewind_checkpoint_dir, Path.join(tmp, "rewind"))
    Application.put_env(:optimal_system_agent, :checkpoint_dir, Path.join(tmp, "crash"))

    session = "sess_#{System.unique_integer([:positive])}"

    {:ok, id} =
      Checkpoint.create_rewind_checkpoint(
        %{session_id: session, messages: [%{role: "user", content: "hi"}], iteration: 1, plan_mode: false, turn_count: 1},
        fs_head: nil,
        label: "first prompt"
      )

    on_exit(fn ->
      put_or_delete(:rewind_checkpoint_dir, prev_rewind)
      put_or_delete(:checkpoint_dir, prev_crash)
      File.rm_rf(tmp)
    end)

    {:ok, session: session, checkpoint_id: id}
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp put_or_delete(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp call(conn), do: RewindRoutes.call(conn, @opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp post_json(path, body) do
    conn(:post, path)
    |> Map.put(:body_params, body)
    |> Map.put(:params, body)
    |> call()
  end

  describe "GET /:session_id" do
    test "lists checkpoints", %{session: session} do
      conn = conn(:get, "/#{session}") |> call()
      assert conn.status == 200
      body = decode(conn)
      assert body["count"] == 1
      assert [cp] = body["checkpoints"]
      assert cp["label"] == "first prompt"
    end

    test "empty list for unknown session" do
      conn = conn(:get, "/unknown_#{System.unique_integer([:positive])}") |> call()
      assert conn.status == 200
      assert decode(conn)["count"] == 0
    end
  end

  describe "GET /:session_id/:id" do
    test "returns the full entry", %{session: session, checkpoint_id: id} do
      conn = conn(:get, "/#{session}/#{id}") |> call()
      assert conn.status == 200
      cp = decode(conn)["checkpoint"]
      assert cp["id"] == id
      assert is_list(cp["messages"])
    end

    test "404 for unknown id", %{session: session} do
      conn = conn(:get, "/#{session}/nope") |> call()
      assert conn.status == 404
    end
  end

  describe "POST /restore" do
    test "restores conversation", %{session: session, checkpoint_id: id} do
      conn = post_json("/restore", %{"session_id" => session, "checkpoint_id" => id, "scope" => "conversation"})
      assert conn.status == 200
      body = decode(conn)
      assert body["scope"] == "conversation"
      assert body["message_count"] == 1
    end

    test "restores code (unavailable without snapshot)", %{session: session, checkpoint_id: id} do
      conn = post_json("/restore", %{"session_id" => session, "checkpoint_id" => id, "scope" => "code"})
      assert conn.status == 200
      assert decode(conn)["code"]["status"] == "unavailable"
    end

    test "defaults scope to both when omitted", %{session: session, checkpoint_id: id} do
      conn = post_json("/restore", %{"session_id" => session, "checkpoint_id" => id})
      assert conn.status == 200
      assert decode(conn)["scope"] == "both"
    end

    test "400 on invalid scope", %{session: session, checkpoint_id: id} do
      conn = post_json("/restore", %{"session_id" => session, "checkpoint_id" => id, "scope" => "bogus"})
      assert conn.status == 400
      assert decode(conn)["error"] == "invalid_scope"
    end

    test "400 when missing fields" do
      conn = post_json("/restore", %{"scope" => "both"})
      assert conn.status == 400
    end

    test "404 for unknown checkpoint", %{session: session} do
      conn = post_json("/restore", %{"session_id" => session, "checkpoint_id" => "missing", "scope" => "both"})
      assert conn.status == 404
    end
  end

  describe "unknown route" do
    test "404" do
      conn = conn(:put, "/whatever") |> call()
      assert conn.status == 404
    end
  end
end
