defmodule OptimalSystemAgent.Scripts.LauncherWorkspaceIsolationTest do
  @moduledoc """
  bin/osa must never adopt — or kill — another workspace's daemon (#245).

  Auto-isolation remembers the port it picked for a directory in that
  workspace's own `run/backend.port`. The file outlives the process it
  describes, so a daemon that dies without cleaning up leaves a port NUMBER
  behind that the OS is free to hand to the next asker, including a different
  workspace's OSA daemon. `bin/osa` used to adopt on "something healthy answers
  there", which attached one folder to another folder's backend and let
  `osa stop` kill it.

  These tests drive the REAL shell functions, extracted from `bin/osa` at
  runtime so they cannot drift from a copy, against a live stub of `GET /health`.
  """
  use ExUnit.Case, async: true

  @launcher Path.expand("../../bin/osa", __DIR__)
  @http_channel Path.expand("../../lib/optimal_system_agent/channels/http.ex", __DIR__)

  @ownership_fns ~w(_daemon_workspace _same_dir _pidfile_owns_port _stop_target_is_ours)

  # ── The two halves of the contract ──────────────────────────────────────

  test "/health reports the daemon's own launch directory" do
    source = File.read!(@http_channel)

    assert source =~ "workspace: OptimalSystemAgent.Workspace.Cwd.original_cwd()",
           """
           GET /health must carry the daemon's workspace, or bin/osa's ownership
           check below is inert and #245 is only half fixed.

           Add to the Jason.encode! map in `get "/health"`:

               workspace: OptimalSystemAgent.Workspace.Cwd.original_cwd(),

           It must be `original_cwd/0` — the launch directory the daemon was
           started with. NOT `Cwd.get/0` (session-scoped, changes per turn) and
           NOT `File.cwd!()` (the OSA source tree, because the daemon starts with
           `cd "$ROOT"`).
           """
  end

  test "adoption requires the daemon to name this workspace" do
    source = File.read!(@launcher)

    # Health alone must no longer be sufficient evidence of ownership.
    assert source =~ ~S[_ws_owner="$(_daemon_workspace "$_ws_port")"]
    assert source =~ ~S[if _same_dir "$_ws_owner" "$OSA_ORIGINAL_CWD"; then]

    # ...and the kill path re-checks rather than trusting that decision.
    assert source =~ "_stop_target_is_ours || return 1"
  end

  # ── What the helpers actually do ────────────────────────────────────────

  test "reads the workspace a live daemon reports" do
    port = stub_health(~s({"status":"ok","version":"1.0.178","workspace":"/tmp/wsA"}))
    assert {"/tmp/wsA", 0} = sh(~s(_daemon_workspace #{port}))
  end

  test "reports nothing for a daemon that predates the workspace field" do
    port = stub_health(~s({"status":"ok","version":"1.0.177"}))
    assert {"", 0} = sh(~s(_daemon_workspace #{port}))
  end

  test "reports nothing when the port is dead" do
    assert {"", 0} = sh(~s(_daemon_workspace #{free_port()}))
  end

  test "path equality tolerates a trailing slash but never an unknown" do
    assert {_, 0} = sh(~s(_same_dir /tmp/wsA /tmp/wsA))
    assert {_, 0} = sh(~s(_same_dir /tmp/wsA/ /tmp/wsA))
    assert {_, 0} = sh(~s(_same_dir / /))
    assert {_, 1} = sh(~s(_same_dir /tmp/wsA /tmp/wsB))
    # An unidentified daemon must not be mistaken for ours.
    assert {_, 1} = sh(~s(_same_dir "" /tmp/wsA))
    assert {_, 1} = sh(~s(_same_dir "" ""))
  end

  # ── The gate in front of the kill ───────────────────────────────────────

  test "stops our own workspace's daemon" do
    port = stub_health(~s({"status":"ok","workspace":"/tmp/wsA"}))
    assert {_, 0} = sh(stop_check(port, "/tmp/wsA", auto_ws: 1))
  end

  test "refuses to stop a daemon that names another folder" do
    port = stub_health(~s({"status":"ok","workspace":"/tmp/wsA"}))
    {out, code} = sh(stop_check(port, "/tmp/wsB", auto_ws: 1))

    assert code == 1
    assert out =~ "Refusing to stop the backend"
    # The message has to name the other folder — otherwise the user has no way
    # to tell which of their sessions is holding the port.
    assert out =~ "/tmp/wsA"
    assert out =~ "cd /tmp/wsA && osa stop"
  end

  test "an operator-named port (--dev, OSA_PORT, OSA_HOME) is exempt" do
    # `osa stop --dev` must keep stopping :19001 from any directory: that is a
    # deliberate cross-workspace stop of a documented single-instance profile.
    port = stub_health(~s({"status":"ok","workspace":"/tmp/wsA"}))
    assert {_, 0} = sh(stop_check(port, "/tmp/wsB", auto_ws: 0))
  end

  test "a daemon too old to identify itself may still be stopped" do
    # Refusing here would leave `osa stop` unable to clean up after any
    # pre-1.0.178 daemon. Adoption is where such a daemon has to earn its way in.
    port = stub_health(~s({"status":"ok","version":"1.0.177"}))
    assert {_, 0} = sh(stop_check(port, "/tmp/wsB", auto_ws: 1))
  end

  test "a dead port has nothing to protect" do
    assert {_, 0} = sh(stop_check(free_port(), "/tmp/wsB", auto_ws: 1))
  end

  # ── Fallback proof for daemons that cannot identify themselves ──────────

  test "the recorded pid holding the listener proves the daemon is ours" do
    port = stub_health(~s({"status":"ok"}))
    dir = tmp_dir()
    pidfile = Path.join(dir, "backend.pid")

    # The stub listener is owned by this BEAM, so os_getpid/0 IS the port owner.
    File.write!(pidfile, "#{System.pid()}\n")
    assert {_, 0} = sh(~s(_pidfile_owns_port #{pidfile} #{port}))

    File.write!(pidfile, "999999\n")
    assert {_, 1} = sh(~s(_pidfile_owns_port #{pidfile} #{port}))

    assert {_, 1} = sh(~s(_pidfile_owns_port #{Path.join(dir, "absent.pid")} #{port}))
  end

  # ── Harness ─────────────────────────────────────────────────────────────

  defp stop_check(port, cwd, auto_ws: auto) do
    ~s(PORT=#{port} OSA_ORIGINAL_CWD=#{cwd} _OSA_AUTO_WS=#{auto} _stop_target_is_ours)
  end

  # Run `command` with the ownership helpers lifted verbatim out of bin/osa.
  defp sh(command) do
    source = File.read!(@launcher)
    preamble = "BOLD=; DIM=; YELLOW=; CYAN=; RESET=\n"
    fns = Enum.map_join(@ownership_fns, "\n", &shell_fn(source, &1))

    {out, code} =
      System.cmd("bash", ["-c", preamble <> fns <> "\n" <> command], stderr_to_stdout: true)

    {String.trim(out), code}
  end

  # A shell function definition from `name() {` to the closing `}` in column 0.
  defp shell_fn(source, name) do
    lines = String.split(source, "\n")
    start = Enum.find_index(lines, &(&1 == "#{name}() {"))
    assert start, "bin/osa no longer defines #{name}()"
    len = lines |> Enum.drop(start) |> Enum.find_index(&(&1 == "}"))
    lines |> Enum.slice(start, len + 1) |> Enum.join("\n")
  end

  # Minimal GET /health, on an ephemeral port, for the life of the test.
  defp stub_health(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        packet: :raw,
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)
    spawn(fn -> serve(listen, body) end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  defp serve(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 2_000)

        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: application/json\r\n",
          "Content-Length: #{byte_size(body)}\r\n",
          "Connection: close\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
        serve(listen, body)

      {:error, _closed} ->
        :ok
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "osa-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
