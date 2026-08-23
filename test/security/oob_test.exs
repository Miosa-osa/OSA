defmodule OptimalSystemAgent.Security.OobTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.Oob

  @jsonl """
  {"protocol":"dns","unique-id":"u1","remote-address":"1.2.3.4","raw-request":"A abc.oast.fun","timestamp":"2024-06-01T12:00:00Z"}
  {"protocol":"http","unique-id":"u2","remote-address":"5.6.7.8","raw-request":"GET / HTTP/1.1","timestamp":"2024-06-01T12:00:01Z"}
  """

  defp sid, do: "oob-#{System.unique_integer([:positive])}"

  defp start_runner(host \\ "abc.oast.fun") do
    fn
      {:start, _sid} -> {:ok, host <> "\n"}
      {:poll, _sid} -> {:ok, ""}
    end
  end

  test "start with stub returning abc.oast.fun sets host/1" do
    sid = sid()
    assert {:ok, session} = Oob.start(sid, runner: start_runner("abc.oast.fun"))
    assert session.id == sid
    assert session.host == "abc.oast.fun"
    assert session.status == :running
    assert session.hits == []
    assert {:ok, "abc.oast.fun"} = Oob.host(sid)
  end

  test "start parses a JSON host from the runner stdout" do
    sid = sid()
    runner = fn {:start, _} -> {:ok, ~s({"host":"xyz.oast.fun"}\n)} end
    assert {:ok, session} = Oob.start(sid, runner: runner)
    assert session.host == "xyz.oast.fun"
  end

  test "require_started before start errors; after start is :ok" do
    sid = sid()
    assert {:error, msg} = Oob.require_started(sid)
    assert msg == "start oob before blind payload"
    assert {:ok, _} = Oob.start(sid, runner: start_runner())
    assert :ok = Oob.require_started(sid)
  end

  test "poll JSONL two unique hits, second poll of same lines returns empty" do
    sid = sid()
    assert {:ok, _} = Oob.start(sid, runner: start_runner())

    poller = fn {:poll, _} -> {:ok, @jsonl} end
    assert {:ok, hits} = Oob.poll(sid, runner: poller)
    assert length(hits) == 2
    assert Enum.map(hits, & &1.protocol) == ["dns", "http"]
    assert Enum.map(hits, & &1.remote) == ["1.2.3.4", "5.6.7.8"]
    assert Enum.map(hits, & &1.id) == ["u1", "u2"]

    assert {:ok, []} = Oob.poll(sid, runner: poller)
    assert length(Oob.hits(sid)) == 2
  end

  test "poll parses Received DNS from text lines" do
    sid = sid()
    assert {:ok, _} = Oob.start(sid, runner: start_runner())

    poller = fn {:poll, _} -> {:ok, "Received DNS from 9.9.9.9\n"} end
    assert {:ok, [hit]} = Oob.poll(sid, runner: poller)
    assert hit.protocol == "dns"
    assert hit.remote == "9.9.9.9"
    assert hit.raw =~ "Received DNS"
  end

  test "receipt includes protocol and remote" do
    sid = sid()
    assert {:ok, _} = Oob.start(sid, runner: start_runner())
    assert {:ok, _} = Oob.poll(sid, runner: fn {:poll, _} -> {:ok, @jsonl} end)
    assert {:ok, dump} = Oob.receipt(sid)
    assert dump =~ "dns"
    assert dump =~ "1.2.3.4"
    assert dump =~ "http"
    assert dump =~ "5.6.7.8"
  end

  test "receipt with no hits is an error" do
    sid = sid()
    assert {:error, "no oob hits"} = Oob.receipt(sid)
    assert {:ok, _} = Oob.start(sid, runner: start_runner())
    assert {:error, "no oob hits"} = Oob.receipt(sid)
  end

  test "stop then poll errors" do
    sid = sid()
    assert {:ok, _} = Oob.start(sid, runner: start_runner())
    assert :ok = Oob.stop(sid)
    assert {:error, msg} = Oob.poll(sid, runner: fn {:poll, _} -> {:ok, @jsonl} end)
    assert msg == "oob session stopped"
  end

  test "poll without a session errors" do
    assert {:error, "no oob session"} = Oob.poll(sid())
  end

  test "hits/1 is empty when there is no session" do
    assert Oob.hits(sid()) == []
  end

  test "default runner errors when interactsh-client is absent" do
    sid = sid()

    # Always cover the error path. Never shell out, even if the binary is installed.
    assert {:error, msg} = Oob.start(sid, find_executable: fn "interactsh-client" -> nil end)
    assert msg == "interactsh-client not found"
  end

  test "start twice on the same session_id returns the existing running session" do
    sid = sid()
    assert {:ok, first} = Oob.start(sid, runner: start_runner("abc.oast.fun"))

    assert {:ok, second} =
             Oob.start(sid, runner: fn {:start, _} -> {:ok, "zzz.oast.pro\n"} end)

    assert second.host == first.host
    assert second.host == "abc.oast.fun"
    assert {:ok, "abc.oast.fun"} = Oob.host(sid)
  end

  test "start after stop replaces the session with a new host" do
    sid = sid()
    assert {:ok, _} = Oob.start(sid, runner: start_runner("abc.oast.fun"))
    assert :ok = Oob.stop(sid)
    assert {:ok, session} = Oob.start(sid, runner: start_runner("new.oast.fun"))
    assert session.host == "new.oast.fun"
    assert session.status == :running
    assert session.hits == []
  end
end
