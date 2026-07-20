defmodule OptimalSystemAgent.CLI.Remote do
  @moduledoc """
  CLI handler for `osa remote <verb>` — the CLIENT side of OpenComputers.

  Where `osa opencomputers ...` claims THIS machine as a host, `osa remote ...`
  reaches OUT to hosts the account already owns, brokered through the MIOSA
  control plane.

  Verbs:

      osa remote hosts                       List your connected machines
      osa remote exec <host> [--] <cmd...>   Run one command on <host>
      osa remote agent <host> <task...>      Dispatch an agent task to <host>
              [--dir <path>] [--model <m>] [--provider <p>]
      osa remote shell <host> [--shell <p>]  Interactive PTY on <host>
      osa remote sessions <host>             List live sessions on <host>
      osa remote kill [<host>] <session_id>  Tear a session down

  Every network path degrades gracefully: a missing account credential or an
  unreachable broker prints a friendly message and exits non-zero, never a
  stack trace. The client endpoint + session broker this talks to is a MIOSA
  server dependency that is not implemented yet (see docs/OSA_REMOTE_DESIGN.md
  section 6), so until the server ships these commands report the broker as
  unreachable.
  """

  alias OptimalSystemAgent.Remote.{Auth, Client, Frames, PtyBridge}

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  @doc "Dispatch a list of CLI args to the appropriate verb handler."
  @spec dispatch([String.t()]) :: :ok
  def dispatch([verb | rest]) do
    case verb do
      "hosts" -> cmd_hosts()
      "exec" -> run_parsed(&parse_exec/1, rest, &cmd_exec/1)
      "agent" -> run_parsed(&parse_agent/1, rest, &cmd_agent/1)
      "shell" -> run_parsed(&parse_shell/1, rest, &cmd_shell/1)
      "sessions" -> run_parsed(&parse_sessions/1, rest, &cmd_sessions/1)
      "kill" -> run_parsed(&parse_kill/1, rest, &cmd_kill/1)
      v when v in ["--help", "-h", "help"] -> print_usage()
      _ -> unknown(verb)
    end
  end

  def dispatch([]), do: print_usage()

  # ── Pure arg parsers (unit-tested; no network, no halt) ──────────────────────

  @doc false
  @spec parse_exec([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_exec([]), do: {:error, "usage: osa remote exec <host> [--] <cmd...>"}

  def parse_exec([host | rest]) do
    cmd_parts = strip_leading_dashdash(rest)

    if cmd_parts == [] do
      {:error, "no command given. usage: osa remote exec <host> [--] <cmd...>"}
    else
      {:ok, %{host: host, cmd: Enum.join(cmd_parts, " ")}}
    end
  end

  @doc false
  @spec parse_agent([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_agent(args) do
    {opts, positional} =
      OptionParser.parse!(args, strict: [dir: :string, model: :string, provider: :string])

    case positional do
      [] ->
        {:error, "usage: osa remote agent <host> \"<task>\" [--dir <path>] [--model <m>]"}

      [host | task_parts] ->
        task = task_parts |> strip_leading_dashdash() |> Enum.join(" ")

        if task == "" do
          {:error, "no task given. usage: osa remote agent <host> \"<task>\""}
        else
          {:ok, %{host: host, task: task, opts: opts}}
        end
    end
  rescue
    e in OptionParser.ParseError -> {:error, Exception.message(e)}
  end

  @doc false
  @spec parse_shell([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_shell(args) do
    {opts, positional} = OptionParser.parse!(args, strict: [shell: :string])

    case positional do
      [host | _] -> {:ok, %{host: host, shell: opts[:shell]}}
      [] -> {:error, "usage: osa remote shell <host> [--shell <path>]"}
    end
  rescue
    e in OptionParser.ParseError -> {:error, Exception.message(e)}
  end

  @doc false
  @spec parse_sessions([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_sessions([host | _]) when host != "", do: {:ok, %{host: host}}
  def parse_sessions(_), do: {:error, "usage: osa remote sessions <host>"}

  @doc false
  @spec parse_kill([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_kill([host, session_id | _]), do: {:ok, %{host: host, session_id: session_id}}
  def parse_kill([session_id]), do: {:ok, %{host: nil, session_id: session_id}}
  def parse_kill(_), do: {:error, "usage: osa remote kill [<host>] <session_id>"}

  @doc false
  @spec usage() :: String.t()
  def usage do
    """
    Usage: osa remote <verb>

    Verbs:
      hosts                            List your connected machines + online status
      exec <host> [--] <cmd...>        Run one command on <host>, print stdout/exit
      agent <host> "<task>"            Dispatch an OSA agent task to <host>
            [--dir <path>]             Working directory on the host
            [--model <m>]              Model override
            [--provider <p>]           Provider override
      shell <host> [--shell <path>]    Interactive PTY on <host>
      sessions <host>                  List live sessions on <host>
      kill [<host>] <session_id>       Tear a session down

    Auth: uses your MIOSA account credential (miosa login / MIOSA_PLATFORM_API_KEY,
    or OSA_REMOTE_TOKEN to override). Endpoint override: OSA_REMOTE_CONTROL_URL.
    """
  end

  # ── Verb runners (resolve auth, open the client, degrade gracefully) ─────────

  defp cmd_hosts do
    with_client(fn pid ->
      case Client.list_hosts(pid) do
        {:ok, hosts} -> print_hosts(hosts)
        {:error, msg} -> fail(msg)
      end
    end)
  end

  defp cmd_exec(%{host: host, cmd: cmd}) do
    with_client(fn pid ->
      with {:ok, sid} <- Client.create_session(pid, host, :exec),
           {:ok, text} <- Client.run_job(pid, Frames.exec_job(sid, cmd)) do
        IO.puts(text)
      else
        {:error, msg} -> fail(msg)
      end
    end)
  end

  defp cmd_agent(%{host: host, task: task, opts: opts}) do
    with_client(fn pid ->
      with {:ok, sid} <- Client.create_session(pid, host, :agent),
           {:ok, text} <- Client.run_job(pid, Frames.agent_job(sid, task, opts)) do
        IO.puts(text)
      else
        {:error, msg} -> fail(msg)
      end
    end)
  end

  defp cmd_shell(%{host: host, shell: shell}) do
    with_client(fn pid ->
      case Client.create_session(pid, host, :shell) do
        {:ok, sid} ->
          run_interactive_shell(pid, sid, shell)

        {:error, msg} ->
          fail(msg)
      end
    end)
  end

  defp cmd_sessions(%{host: host}) do
    with_client(fn pid ->
      case Client.list_sessions(pid, host) do
        {:ok, sessions} -> print_sessions(sessions)
        {:error, msg} -> fail(msg)
      end
    end)
  end

  defp cmd_kill(%{host: host, session_id: session_id}) do
    with_client(fn pid ->
      case Client.kill_session(pid, host, session_id) do
        :ok -> IO.puts("Session #{session_id} killed.")
        {:error, msg} -> fail(msg)
      end
    end)
  end

  # ── Interactive shell wiring (best-effort; needs a live broker) ──────────────

  defp run_interactive_shell(pid, sid, shell) do
    :ok = Client.stream_to(pid, self())
    {cols, rows} = terminal_size()

    bridge =
      PtyBridge.new(sid,
        send_fn: fn frame -> Client.send_frame(pid, frame) end,
        cols: cols,
        rows: rows
      )

    bridge = PtyBridge.open(bridge, shell)

    _ = :io.setopts(:standard_io, binary: true)
    parent = self()
    reader = spawn_link(fn -> stdin_reader(parent) end)

    exit_code = PtyBridge.loop(bridge)

    if Process.alive?(reader), do: Process.exit(reader, :kill)
    IO.puts("")
    System.halt(exit_code)
  end

  defp stdin_reader(parent) do
    case IO.binread(:stdio, 1) do
      :eof ->
        send(parent, :eof)

      {:error, _reason} ->
        send(parent, :eof)

      data when is_binary(data) ->
        send(parent, {:stdin, data})
        stdin_reader(parent)
    end
  end

  defp terminal_size do
    cols =
      case :io.columns() do
        {:ok, c} -> c
        _ -> 80
      end

    rows =
      case :io.rows() do
        {:ok, r} -> r
        _ -> 24
      end

    {cols, rows}
  end

  # ── Output rendering ─────────────────────────────────────────────────────────

  defp print_hosts([]) do
    IO.puts("No hosts claimed by this account yet.")
    IO.puts("Claim one on a machine with: osa opencomputers login --key <oc_host_key>")
  end

  defp print_hosts(hosts) do
    IO.puts("")
    IO.puts("Your hosts")
    IO.puts("────────────────────────────────")

    Enum.each(hosts, fn host ->
      id = host[:alias] || host[:id] || "(unknown)"
      status = if host[:online], do: "online", else: "offline"
      os = host[:os] || ""
      IO.puts("  #{id}  [#{status}]  #{os}")
    end)

    IO.puts("")
  end

  defp print_sessions([]), do: IO.puts("No live sessions on that host.")

  defp print_sessions(sessions) do
    IO.puts("")
    IO.puts("Live sessions")
    IO.puts("────────────────────────────────")

    Enum.each(sessions, fn session ->
      sid = session[:session_id] || "(unknown)"
      kind = session[:kind] || ""
      IO.puts("  #{sid}  #{kind}")
    end)

    IO.puts("")
  end

  # ── Plumbing ─────────────────────────────────────────────────────────────────

  defp run_parsed(parser, args, runner) do
    case parser.(args) do
      {:ok, parsed} -> runner.(parsed)
      {:error, message} -> fail(message)
    end
  end

  defp with_client(fun) do
    case Auth.require_token() do
      {:ok, token} ->
        case Client.open(token: token) do
          {:ok, pid} ->
            try do
              fun.(pid)
            after
              Client.stop(pid)
            end

          {:error, message} ->
            fail(message)
        end

      {:error, message} ->
        fail(message)
    end
  end

  defp strip_leading_dashdash(["--" | rest]), do: rest
  defp strip_leading_dashdash(list), do: list

  defp print_usage, do: IO.puts(usage())

  defp unknown(verb) do
    IO.puts(:stderr, "Unknown verb: #{verb}")
    IO.puts(usage())
    System.halt(1)
  end

  defp fail(message) do
    IO.puts(:stderr, "Error: #{message}")
    System.halt(1)
  end
end
