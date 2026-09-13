defmodule OptimalSystemAgent.Security.EvidenceTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.Evidence

  test "records bytes, chains hashes, and verifies" do
    sid = "ev-#{System.unique_integer([:positive])}"
    {:ok, a} = Evidence.record(sid, bytes: "req-1", kind: "http", finding_key: "v1")
    {:ok, b} = Evidence.record(sid, bytes: "req-2", kind: "http", finding_key: "v1")

    assert byte_size(a.sha256) == 64
    assert b.prev == a.sha256
    assert Evidence.verify(sid) == :ok
    assert length(Evidence.list(sid)) == 2
  end

  test "records a file path" do
    sid = "ev-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "osa-ev-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "hello")

    try do
      {:ok, rec} = Evidence.record(sid, path: path, kind: "dump")
      assert rec.bytes == 5
      assert rec.path == path
    after
      File.rm(path)
    end
  end

  test "refuses a missing path" do
    sid = "ev-#{System.unique_integer([:positive])}"
    assert {:error, _} = Evidence.record(sid, path: "/no/such/osa-evidence")
  end
end
