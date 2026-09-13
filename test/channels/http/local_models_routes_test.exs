defmodule OptimalSystemAgent.Channels.HTTP.LocalModelsRoutesTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OptimalSystemAgent.Channels.HTTP

  # A fresh OSA_HOME (no .env) means first-run, so the routes are open — the
  # same rule the onboarding routes follow. A dead daemon port keeps the
  # overview deterministic (installed: [], error set) while the catalog and
  # hardware still come back.
  setup do
    dir = Path.join(System.tmp_dir!(), "osa-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    prev_url = Application.get_env(:optimal_system_agent, :ollama_url)
    System.put_env("OSA_HOME", dir)
    Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      if prev_url,
        do: Application.put_env(:optimal_system_agent, :ollama_url, prev_url),
        else: Application.delete_env(:optimal_system_agent, :ollama_url)

      File.rm_rf(dir)
    end)

    :ok
  end

  defp call(conn), do: HTTP.call(conn, HTTP.init([]))
  defp json(conn), do: Jason.decode!(conn.resp_body)

  test "GET /models/local returns hardware, the catalog, and the daemon error" do
    conn = call(conn(:get, "/models/local"))
    assert conn.status == 200
    body = json(conn)
    assert is_binary(body["hardware"]["summary"])
    assert body["installed"] == []
    assert length(body["catalog"]) >= 10
    assert body["error"] =~ "not running"

    row = Enum.find(body["catalog"], &(&1["catalog_id"] == "superqwen-abliterated"))
    assert row["fit"]["verdict"] in ["fits", "partial", "cpu", "no"]
    assert row["capabilities"] == ["tools", "thinking", "vision"]
  end

  test "GET /models/local/info?ref= sizes a catalog entry per quant (offline estimate)" do
    conn = call(conn(:get, "/models/local/info?ref=llama3.1-8b-abliterated"))
    assert conn.status == 200
    body = json(conn)
    assert body["tag"] =~ "hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:"
    assert body["installed"] == false
    assert Enum.all?(body["quants"], &is_binary(&1["fit"]["verdict"]))

    conn = call(conn(:get, "/models/local/info?ref=nope"))
    assert conn.status == 400
    assert json(conn)["error"] =~ "unknown model"
  end

  test "POST /models/local/install starts a job that GET /install/:id can poll" do
    conn =
      conn(
        :post,
        "/models/local/install",
        Jason.encode!(%{ref: "route-test-#{System.unique_integer([:positive])}"})
      )
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 200
    %{"job_id" => id} = json(conn)

    conn = call(conn(:get, "/models/local/install/#{id}"))
    assert conn.status == 200
    assert json(conn)["state"] in ["pulling", "error"]

    conn = call(conn(:get, "/models/local/install/job-nope"))
    assert conn.status == 400
  end

  test "bad bodies are 400s" do
    conn =
      conn(:post, "/models/local/install", "{}")
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 400
    assert json(conn)["error"] =~ "ref is required"

    conn = conn(:post, "/models/local/remove", "not json") |> call()
    assert conn.status == 400
  end
end
