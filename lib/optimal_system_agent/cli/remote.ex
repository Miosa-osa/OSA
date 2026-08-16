defmodule OptimalSystemAgent.CLI.Remote do
  @moduledoc """
  CLI handler for `osa remote <verb>` — the CLIENT side of OpenComputers,
  speaking the MIOSA miosa-compute #484 protocol.

  Where `osa opencomputers ...` claims THIS machine as a host, `osa remote ...`
  reaches OUT to hosts the account already owns, brokered through the MIOSA
  control plane.

  Verbs:

      osa remote hosts                       List your connected machines
      osa remote exec <host> [--] <cmd...>   Run one command on <host>
      osa remote agent <host> "<prompt>"     Dispatch an agent task to <host>
              [--dir <path>] [--model <m>] [--provider <p>]
      osa remote sessions                    (not available yet in this release)
      osa remote kill <session_id>           Close a remote session
      osa remote shell <host>                (not available yet in this release)

  Every network path degrades gracefully: a missing account credential, an
  unreachable broker, or a key without the `opencomputers:write` scope prints a
  friendly message and exits non-zero, never a stack trace.

  Interactive PTY shell is NOT part of the #484 server contract, so `shell` is
  gated off with a clear message rather than sending frames the server rejects.

  ## Untrusted output

  Everything this module prints that did not come from the source below arrived
  over the network: a remote command's stdout, an agent's answer, the host names
  and OS strings in the broker's inventory, and the broker's own error strings.
  A remote host is exactly the place an attacker would sit, and `osa remote exec`
  is `cat`-with-extra-steps for whatever that host chooses to send. All of it
  goes through `OptimalSystemAgent.CLI.Sanitize` before it reaches stdout.
  """

  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.Remote.{Auth, Client, Frames}

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  @doc "Dispatch a list of CLI args to the appropriate verb handler."
  @spec dispatch([String.t()]) :: :ok
  def dispatch([verb | rest]) do
    case verb do
      "hosts" -> cmd_hosts()
      "exec" -> run_parsed(&parse_exec/1, rest, &cmd_exec/1)
      "agent" -> run_parsed(&parse_agent/1, rest, &cmd_agent/1)
      "shell" -> cmd_shell()
      "sessions" -> cmd_sessions()
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
        {:error, "usage: osa remote agent <host> \"<prompt>\" [--dir <path>] [--model <m>]"}

      [host | prompt_parts] ->
        prompt = prompt_parts |> strip_leading_dashdash() |> Enum.join(" ")

        if prompt == "" do
          {:error, "no prompt given. usage: osa remote agent <host> \"<prompt>\""}
        else
          {:ok, %{host: host, prompt: prompt, opts: opts}}
        end
    end
  rescue
    e in OptionParser.ParseError -> {:error, Exception.message(e)}
  end

  @doc false
  @spec parse_kill([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_kill([session_id | _]) when session_id != "", do: {:ok, %{session_id: session_id}}
  def parse_kill(_), do: {:error, "usage: osa remote kill <session_id>"}

  @doc false
  @spec usage() :: String.t()
  def usage do
    """
    Usage: osa remote <verb>

    Verbs:
      hosts                            List your connected machines + online status
      exec <host> [--] <cmd...>        Run one command on <host>, print stdout/exit
      agent <host> "<prompt>"          Dispatch an OSA agent task to <host>
            [--dir <path>]             Working directory on the host
            [--model <m>]              Model override
            [--provider <p>]           Provider override
      sessions                         (not available yet in this release)
      kill <session_id>                Close a remote session
      shell <host>                     (not available yet in this release)

    Auth: uses your MIOSA account credential (miosa login / MIOSA_PLATFORM_API_KEY,
    or OSA_REMOTE_TOKEN to override). A user key needs the opencomputers:write
    scope. Endpoint override: OSA_REMOTE_CONTROL_URL.
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
      with {:ok, sid} <- Client.open_session(pid, host, :exec, Frames.exec_params(cmd)),
           {:ok, text} <- Client.await_result(pid, sid) do
        # A remote command's stdout, verbatim off the wire. Block tier: the
        # line structure of command output is the output.
        IO.puts(Sanitize.scrub_block(text))
      else
        {:error, msg} -> fail(msg)
      end
    end)
  end

  defp cmd_agent(%{host: host, prompt: prompt, opts: opts}) do
    with_client(fn pid ->
      with {:ok, sid} <-
             Client.open_session(pid, host, :agent, Frames.agent_params(prompt, opts)),
           {:ok, text} <- Client.await_result(pid, sid) do
        # A remote agent's answer — model text that has additionally crossed a
        # machine boundary. Same tier, same reason, as the local model sink.
        IO.puts(Sanitize.scrub_block(text))
      else
        {:error, msg} -> fail(msg)
      end
    end)
  end

  defp cmd_kill(%{session_id: session_id}) do
    with_client(fn pid ->
      case Client.close_session(pid, session_id) do
        :ok -> IO.puts("Session #{Sanitize.scrub_line(session_id)} closed.")
        {:error, msg} -> fail(msg)
      end
    end)
  end

  @doc false
  @spec shell_unavailable_message() :: String.t()
  def shell_unavailable_message do
    "Interactive remote shell is not available yet in this release " <>
      "(exec and agent work); coming in a later round."
  end

  @doc false
  @spec sessions_unavailable_message() :: String.t()
  def sessions_unavailable_message do
    "Listing remote sessions is not available yet in this release: sessions are " <>
      "scoped to the live client connection that opened them, and the broker does " <>
      "not expose cross-connection enumeration. Coming in a later round."
  end

  defp cmd_shell do
    IO.puts(:stderr, shell_unavailable_message())
    System.halt(2)
  end

  defp cmd_sessions do
    IO.puts(:stderr, sessions_unavailable_message())
    System.halt(2)
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

    Enum.each(hosts, &IO.puts(host_line(&1)))

    IO.puts("")
  end

  @doc false
  @spec host_line(map()) :: String.t()
  def host_line(host) do
    # Name and OS string are chosen by whoever claimed the host, and this is a
    # table: the single-line tier keeps one host to one row, so a name cannot
    # invent extra rows or a `\r` redraw another host's status as `online`.
    id = Sanitize.scrub_line(to_string(host[:name] || host[:id] || "(unknown)"))
    status = if host[:online], do: "online", else: "offline"
    os = Sanitize.scrub_line(to_string(host[:os_kind] || ""))
    "  #{id}  [#{status}]  #{os}"
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
    IO.puts(:stderr, error_line("Unknown verb: #{verb}"))
    IO.puts(usage())
    System.halt(1)
  end

  defp fail(message) do
    IO.puts(:stderr, error_line("Error: #{message}"))
    System.halt(1)
  end

  # Broker- and server-supplied failure strings land here, so the diagnostic
  # channel is a render site like any other. One error, one line.
  @doc false
  @spec error_line(term()) :: String.t()
  def error_line(message), do: message |> to_string() |> Sanitize.scrub_line()
end
