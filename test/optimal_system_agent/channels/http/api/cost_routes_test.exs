defmodule OptimalSystemAgent.Channels.HTTP.API.CostRoutesTest do
  @moduledoc """
  HTTP contract + error-path coverage for the /cost routes.

  Verifies every route returns a clean JSON response (never a crash), the
  budget-write validation rejects bad input with 400, unknown paths 404, and
  the money-rounding is integer-safe (regression for the `Float.round/2`
  ArgumentError when a summed cost is an integer).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.CostRoutes

  @opts CostRoutes.init([])

  defp call(conn), do: CostRoutes.call(conn, @opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp content_type(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [ct | _] -> ct
      [] -> nil
    end
  end

  defp put_json(path, body) do
    conn(:put, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(
      Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])
    )
    |> call()
  end

  # Isolate the config file the PUT route persists to under a per-run temp dir
  # so tests never touch ~/.osa/config.json.
  setup do
    prev = Application.get_env(:optimal_system_agent, :bootstrap_dir)
    tmp = Path.join(System.tmp_dir!(), "osa-cost-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :bootstrap_dir, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev do
        Application.put_env(:optimal_system_agent, :bootstrap_dir, prev)
      else
        Application.delete_env(:optimal_system_agent, :bootstrap_dir)
      end
    end)

    :ok
  end

  describe "GET / — cost summary" do
    test "returns 200 JSON with the expected shape" do
      conn = call(conn(:get, "/"))
      assert conn.status == 200
      assert content_type(conn) =~ "application/json"

      body = decode(conn)
      assert Map.has_key?(body, "total_cost_usd")
      assert Map.has_key?(body, "total_tokens")
      assert Map.has_key?(body, "sessions")
      assert is_number(body["total_cost_usd"])
    end
  end

  describe "GET /by-agent and /by-model — grouped breakdowns" do
    test "by-agent returns a JSON list (empty when no ledger)" do
      conn = call(conn(:get, "/by-agent"))
      assert conn.status == 200
      assert is_list(decode(conn)["agents"])
    end

    test "by-model returns a JSON list (empty when no ledger)" do
      conn = call(conn(:get, "/by-model"))
      assert conn.status == 200
      assert is_list(decode(conn)["models"])
    end
  end

  describe "GET /events — pagination" do
    test "returns a paginated envelope" do
      conn = call(conn(:get, "/events?page=1&per_page=5"))
      assert conn.status == 200

      body = decode(conn)
      assert body["page"] == 1
      assert body["per_page"] == 5
      assert is_list(body["events"])
      assert is_integer(body["count"])
    end

    test "clamps per_page to the 100 maximum" do
      conn = call(conn(:get, "/events?per_page=9999"))
      assert conn.status == 200
      assert decode(conn)["per_page"] == 100
    end
  end

  describe "GET /budgets" do
    test "returns the budgets map including a global entry" do
      conn = call(conn(:get, "/budgets"))
      assert conn.status == 200

      body = decode(conn)
      assert is_map(body["budgets"])
      assert Map.has_key?(body["budgets"], "global")
    end
  end

  describe "PUT /budgets/:agent — validation error paths" do
    test "empty body → 400 invalid_request" do
      conn = put_json("/budgets/worker", %{})
      assert conn.status == 400
      assert decode(conn)["error"] == "invalid_request"
    end

    test "no recognised budget fields → 400" do
      conn = put_json("/budgets/worker", %{"nonsense" => 1})
      assert conn.status == 400
      assert decode(conn)["error"] == "invalid_request"
    end

    test "negative limit value → 400 invalid_request" do
      conn = put_json("/budgets/worker", %{"daily_limit_usd" => -5})
      assert conn.status == 400
      assert decode(conn)["error"] == "invalid_request"
    end

    test "non-numeric limit value → 400 invalid_request" do
      conn = put_json("/budgets/worker", %{"daily_limit_usd" => "lots"})
      assert conn.status == 400
      assert decode(conn)["error"] == "invalid_request"
    end

    test "valid limits → 200 and persists the values" do
      conn = put_json("/budgets/worker", %{"daily_limit_usd" => 12.5})
      assert conn.status == 200

      body = decode(conn)
      assert body["agent"] == "worker"
      assert body["limits"]["daily_limit_usd"] == 12.5

      # The write is durable — a follow-up GET /budgets reflects it.
      get_body = call(conn(:get, "/budgets")) |> decode()
      assert get_body["budgets"]["worker"]["daily_limit_usd"] == 12.5
    end
  end

  describe "unknown path" do
    test "returns 404 not_found JSON" do
      conn = call(conn(:get, "/nope"))
      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"
    end
  end
end
