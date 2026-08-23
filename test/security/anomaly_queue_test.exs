defmodule OptimalSystemAgent.Security.AnomalyQueueTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.AnomalyQueue

  @bing_rule "follow one hop before dismissing (XBow Bing rule)"

  setup do
    sid = "aq-#{System.unique_integer([:positive])}"
    {:ok, session_id: sid}
  end

  test "record 500, dismiss immediately errors with the Bing-rule phrase", %{session_id: sid} do
    assert {:ok, rec} =
             AnomalyQueue.record(sid, %{target: "/upload", kind: :http_500, note: "500 on POST"})

    assert rec.status == :open
    assert rec.hops == 0
    assert rec.kind == :http_500
    assert rec.target == "/upload"
    assert is_binary(rec.id) and rec.id != ""
    assert %DateTime{} = rec.inserted_at

    assert {:error, msg} = AnomalyQueue.dismiss(sid, rec.id)
    assert msg == @bing_rule
    assert [%{id: id}] = AnomalyQueue.open(sid)
    assert id == rec.id
  end

  test "hop then dismiss :ok", %{session_id: sid} do
    {:ok, rec} = AnomalyQueue.record(sid, %{target: "https://app.example/fetch"})

    assert {:ok, hopped} = AnomalyQueue.hop(sid, rec.id, "followed Location to internal host")
    assert hopped.hops == 1
    assert hopped.status == :open
    assert hopped.note =~ "followed Location to internal host"

    assert :ok = AnomalyQueue.dismiss(sid, rec.id)
    assert AnomalyQueue.open(sid) == []
  end

  test "chain marks chained, not in open/1", %{session_id: sid} do
    {:ok, rec} = AnomalyQueue.record(sid, %{target: "/proxy?url=", kind: :ssrf_clue})

    assert {:ok, chained} = AnomalyQueue.chain(sid, rec.id)
    assert chained.status == :chained
    assert chained.id == rec.id
    refute Enum.any?(AnomalyQueue.open(sid), &(&1.id == rec.id))
  end

  test "assert_clear errors while open", %{session_id: sid} do
    {:ok, _} = AnomalyQueue.record(sid, %{target: "/a"})
    {:ok, _} = AnomalyQueue.record(sid, %{target: "/b", kind: :odd_upload})

    assert {:error, msg} = AnomalyQueue.assert_clear(sid)
    assert msg =~ "2"
    assert msg =~ "open"
  end

  test "assert_clear :ok when empty", %{session_id: sid} do
    assert :ok = AnomalyQueue.assert_clear(sid)
  end

  test "from_http 500 records, 200 ignored", %{session_id: sid} do
    assert {:ok, rec} = AnomalyQueue.from_http(sid, 500, "/boom")
    assert rec.kind == :http_500
    assert rec.target == "/boom"
    assert rec.status == :open
    assert rec.hops == 0

    assert :ignored = AnomalyQueue.from_http(sid, 200, "/ok")
    assert length(AnomalyQueue.open(sid)) == 1
  end

  test "missing target errors", %{session_id: sid} do
    assert {:error, reason} = AnomalyQueue.record(sid, %{note: "no target"})
    assert reason =~ "target"
    assert AnomalyQueue.open(sid) == []
  end

  test "record defaults kind to :http_500 and hops 0", %{session_id: sid} do
    {:ok, rec} = AnomalyQueue.record(sid, %{target: "/x"})
    assert rec.kind == :http_500
    assert rec.hops == 0
    assert rec.status == :open
    assert rec.note == ""
  end

  test "assert_clear :ok after hop+dismiss and after chain", %{session_id: sid} do
    {:ok, a} = AnomalyQueue.record(sid, %{target: "/a"})
    {:ok, b} = AnomalyQueue.record(sid, %{target: "/b", kind: :redirect_offscope})

    {:ok, _} = AnomalyQueue.hop(sid, a.id, "one hop")
    assert :ok = AnomalyQueue.dismiss(sid, a.id)
    {:ok, _} = AnomalyQueue.chain(sid, b.id)

    assert AnomalyQueue.open(sid) == []
    assert :ok = AnomalyQueue.assert_clear(sid)
  end

  test "from_http ignores nil and non-5xx", %{session_id: sid} do
    assert :ignored = AnomalyQueue.from_http(sid, nil, "/x")
    assert :ignored = AnomalyQueue.from_http(sid, 404, "/x")
    assert :ignored = AnomalyQueue.from_http(sid, 499, "/x")
    assert {:ok, _} = AnomalyQueue.from_http(sid, 599, "/x")
    assert :ignored = AnomalyQueue.from_http(sid, 600, "/x")
  end
end
