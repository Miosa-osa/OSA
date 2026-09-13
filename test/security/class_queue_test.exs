defmodule OptimalSystemAgent.Security.ClassQueueTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.ClassQueue

  setup do
    sid = "cq-#{System.unique_integer([:positive])}"
    {:ok, session_id: sid}
  end

  test "status of a never-touched class is :not_assessed", %{session_id: sid} do
    assert ClassQueue.status(sid, :idor) == :not_assessed
    assert ClassQueue.list(sid, :idor) == []
  end

  test "exploit_allowed? is false and assert_exploit errors with not assessed", %{
    session_id: sid
  } do
    refute ClassQueue.exploit_allowed?(sid, :sqli)
    assert {:error, msg} = ClassQueue.assert_exploit(sid, :sqli)
    assert msg == "class not assessed (empty queue) - do not mark clean"
  end

  test "put one candidate -> queued, exploit allowed, assert_exploit :ok", %{session_id: sid} do
    assert {:ok, rec} =
             ClassQueue.put(sid, :idor, %{target: "/users/1", note: "swap victim id"})

    assert is_binary(rec.id) and rec.id != ""
    assert rec.target == "/users/1"
    assert rec.note == "swap victim id"
    assert %DateTime{} = rec.inserted_at

    assert ClassQueue.status(sid, :idor) == :queued
    assert ClassQueue.exploit_allowed?(sid, :idor)
    assert :ok = ClassQueue.assert_exploit(sid, :idor)
  end

  test "mark_exhausted -> exploit_allowed? false", %{session_id: sid} do
    {:ok, _} = ClassQueue.put(sid, :xss, %{target: "/search?q=x"})
    assert ClassQueue.exploit_allowed?(sid, :xss)

    assert :ok = ClassQueue.mark_exhausted(sid, :xss)
    assert ClassQueue.status(sid, :xss) == :exhausted
    refute ClassQueue.exploit_allowed?(sid, :xss)
    assert {:error, "class queue exhausted"} = ClassQueue.assert_exploit(sid, :xss)
  end

  test "mark_confirmed -> exploit_allowed? true", %{session_id: sid} do
    {:ok, _} = ClassQueue.put(sid, :ssrf, %{target: "/fetch?url="})
    assert :ok = ClassQueue.mark_confirmed(sid, :ssrf)
    assert ClassQueue.status(sid, :ssrf) == :confirmed
    assert ClassQueue.exploit_allowed?(sid, :ssrf)
    assert :ok = ClassQueue.assert_exploit(sid, :ssrf)
  end

  test "list returns put candidates", %{session_id: sid} do
    {:ok, a} = ClassQueue.put(sid, :sqli, %{id: "c-1", target: "/login", note: "union"})
    {:ok, b} = ClassQueue.put(sid, :sqli, %{"target" => "/search", "note" => "or 1=1"})

    listed = ClassQueue.list(sid, :sqli)
    assert length(listed) == 2
    assert Enum.map(listed, & &1.id) == [a.id, b.id]
    assert Enum.map(listed, & &1.target) == ["/login", "/search"]
    assert hd(listed).note == "union"
  end

  test "put without target errors", %{session_id: sid} do
    assert {:error, reason} = ClassQueue.put(sid, :idor, %{note: "no target"})
    assert reason =~ "target"
    assert ClassQueue.status(sid, :idor) == :not_assessed
  end

  test "render lists existing classes and states unknown as not_assessed", %{session_id: sid} do
    {:ok, _} = ClassQueue.put(sid, :idor, %{target: "/api/user/2"})
    ClassQueue.mark_exhausted(sid, :csrf)

    out = ClassQueue.render(sid)
    assert out =~ "idor"
    assert out =~ "queued"
    assert out =~ "csrf"
    assert out =~ "exhausted"
    assert out =~ "not_assessed"
  end
end
