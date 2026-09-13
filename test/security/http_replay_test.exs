defmodule OptimalSystemAgent.Security.HttpReplayTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.HttpReplay

  @har """
  {"log":{"entries":[
    {"request":{"method":"GET","url":"https://example.com/api",
      "headers":[{"name":"Accept","value":"application/json"}]},
     "response":{"status":200}},
    {"request":{"method":"POST","url":"https://example.com/api/users",
      "headers":[{"name":"Content-Type","value":"application/json"}],
      "postData":{"text":"{\\"name\\":\\"a\\"}"}},
     "response":{"status":201}}
  ]}}
  """

  defp sid, do: "http-replay-#{System.unique_integer([:positive])}"

  defp flunk_client do
    fn _req -> flunk("http_client must not be invoked") end
  end

  test "ingest a minimal HAR with 2 entries, list length 2, ids req-1 req-2" do
    sid = sid()
    assert {:ok, recs} = HttpReplay.ingest_har(sid, @har)
    assert length(recs) == 2
    assert Enum.map(recs, & &1.id) == ["req-1", "req-2"]

    listed = HttpReplay.list(sid)
    assert length(listed) == 2
    assert Enum.map(listed, & &1.id) == ["req-1", "req-2"]

    [a, b] = listed
    assert a.method == "GET"
    assert a.url == "https://example.com/api"
    assert a.status == 200
    assert a.source == :har
    assert {"Accept", "application/json"} in a.headers

    assert b.method == "POST"
    assert b.body == ~s({"name":"a"})
    assert b.status == 201
  end

  test "view unknown id errors" do
    sid = sid()
    assert {:ok, _} = HttpReplay.ingest_har(sid, @har)
    assert {:error, reason} = HttpReplay.view(sid, "req-999")
    assert is_binary(reason)
  end

  test "filter list by method GET" do
    sid = sid()
    assert {:ok, _} = HttpReplay.ingest_har(sid, @har)
    gets = HttpReplay.list(sid, method: "GET")
    assert length(gets) == 1
    assert hd(gets).id == "req-1"
    assert hd(gets).method == "GET"
  end

  test "repeat without roe errors and http_client is not invoked" do
    sid = sid()
    assert {:ok, _} = HttpReplay.ingest_har(sid, @har)

    assert {:error, "roe required"} =
             HttpReplay.repeat(sid, "req-1", http_client: flunk_client())
  end

  test "repeat with roe targets example.com against in-scope URL calls client" do
    sid = sid()
    assert {:ok, _} = HttpReplay.ingest_har(sid, @har)

    client = fn req ->
      assert req.method == "GET"
      assert req.url == "https://example.com/api"
      {:ok, %{status: 200, headers: %{}, body: "ok"}}
    end

    assert {:ok, resp} =
             HttpReplay.repeat(sid, "req-1",
               roe: %{targets: ["example.com"]},
               http_client: client
             )

    assert resp.status == 200
    assert resp.body == "ok"
    assert resp.request_id == "req-1"
  end

  test "repeat against evil.com with roe targets example.com errors and does not call client" do
    sid = sid()

    assert {:ok, rec} =
             HttpReplay.put(sid, %{method: "GET", url: "https://evil.com/x"})

    assert {:error, reason} =
             HttpReplay.repeat(sid, rec.id,
               roe: %{targets: ["example.com"]},
               http_client: flunk_client()
             )

    assert is_binary(reason)
  end

  test "overrides url to out-of-scope host blocked" do
    sid = sid()
    assert {:ok, _} = HttpReplay.ingest_har(sid, @har)

    assert {:error, reason} =
             HttpReplay.repeat(sid, "req-1",
               roe: %{targets: ["example.com"]},
               http_client: flunk_client(),
               overrides: %{url: "https://evil.com/phish"}
             )

    assert is_binary(reason)
  end

  test "ingest invalid JSON errors" do
    sid = sid()
    assert {:error, reason} = HttpReplay.ingest_har(sid, "not-json{")
    assert is_binary(reason)
  end

  test "cap: ingesting is fine under 500" do
    sid = sid()
    assert {:ok, recs} = HttpReplay.ingest_har(sid, @har)
    assert length(recs) == 2
    assert length(HttpReplay.list(sid)) < 500
  end
end
