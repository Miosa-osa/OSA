defmodule OptimalSystemAgent.Channels.HTTP.API.CyberDefenseExecutionTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OptimalSystemAgent.Channels.HTTP

  setup do
    saved =
      Map.new([:require_auth, :shared_secret], fn key ->
        {key, Application.fetch_env(:optimal_system_agent, key)}
      end)

    Application.put_env(:optimal_system_agent, :require_auth, false)
    Application.delete_env(:optimal_system_agent, :shared_secret)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, previous} -> Application.put_env(:optimal_system_agent, key, previous)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    :ok
  end

  defp execute(arguments) do
    conn(:post, "/api/v1/tools/cyber_defense/execute", Jason.encode!(%{arguments: arguments}))
    |> put_req_header("content-type", "application/json")
    |> HTTP.call(HTTP.init([]))
  end

  test "HTTP surface metadata does not invalidate strict tool arguments" do
    conn = execute(%{"action" => "scenarios"})
    assert conn.status == 200, conn.resp_body
    body = Jason.decode!(conn.resp_body)
    assert body["tool"] == "cyber_defense"
    assert body["status"] == "completed"

    catalog = Jason.decode!(body["result"])

    assert Enum.sort(Enum.map(catalog["scenarios"], & &1["id"])) ==
             ["auth_rate_limit", "path_traversal", "sql_injection"]

    assert Enum.all?(catalog["scenarios"], &(is_binary(&1["control"]) and is_binary(&1["cwe"])))
  end

  test "unexpected user arguments remain rejected by the strict schema" do
    conn = execute(%{"action" => "scenarios", "unexpected_user_argument" => true})
    assert conn.status == 422, conn.resp_body
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "tool_error"
    assert body["details"] =~ "unexpected_user_argument"
    assert body["details"] =~ "additional properties"
  end
end
