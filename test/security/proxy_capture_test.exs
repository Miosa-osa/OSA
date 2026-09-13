defmodule OptimalSystemAgent.Security.ProxyCaptureTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.ProxyCapture

  @har """
  {"log":{"entries":[
    {"request":{"method":"GET","url":"https://example.com/api"},
     "response":{"status":200}}
  ]}}
  """

  defp sid, do: "proxy-capture-#{System.unique_integer([:positive])}"

  defp stub_runner do
    fn
      {:start, _port, _har_path} -> {:ok, "started"}
      {:stop, _session_id} -> {:ok, "stopped"}
    end
  end

  test "ingest_har_blob minimal HAR returns count 1" do
    sid = sid()
    assert {:ok, result} = ProxyCapture.ingest_har_blob(sid, @har)
    assert result.count == 1
    assert is_binary(result.path) or is_nil(result.path)
  end

  test "ingest_dump missing file errors" do
    sid = sid()
    missing = Path.join(System.tmp_dir!(), "osa-proxy-missing-#{sid}.har")
    File.rm(missing)

    assert {:error, reason} = ProxyCapture.ingest_dump(sid, missing)
    assert is_binary(reason)
    assert reason =~ "no such file" or reason =~ "enoent" or reason =~ "not found"
  end

  test "ingest_dump of a HAR file returns count and path" do
    sid = sid()
    path = Path.join(System.tmp_dir!(), "osa-proxy-#{sid}.har")
    File.write!(path, @har)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, result} = ProxyCapture.ingest_dump(sid, path)
    assert result.count == 1
    assert result.path == path
  end

  test "start without runner/binary errors with ingest-a-HAR message" do
    sid = sid()

    assert {:error, msg} =
             ProxyCapture.start(sid, find_executable: fn _name -> nil end)

    assert msg == "mitmdump not found - ingest a HAR dump instead"
  end

  test "start with stub runner records running status" do
    sid = sid()
    assert {:ok, session} = ProxyCapture.start(sid, runner: stub_runner(), port: 8080)

    assert session.status == :running
    assert session.port == 8080
    assert is_binary(session.har_path)
    assert ProxyCapture.status(sid) == :running
  end

  test "stop after start marks status stopped" do
    sid = sid()
    assert {:ok, _} = ProxyCapture.start(sid, runner: stub_runner())
    assert :ok = ProxyCapture.stop(sid, runner: stub_runner())
    assert ProxyCapture.status(sid) == :stopped
  end

  test "invalid JSON errors" do
    sid = sid()
    assert {:error, reason} = ProxyCapture.ingest_har_blob(sid, "not-json{")
    assert is_binary(reason)
  end

  test "status is idle when the session has never started" do
    assert ProxyCapture.status(sid()) == :idle
  end
end
