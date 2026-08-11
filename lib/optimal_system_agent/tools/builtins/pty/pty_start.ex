defmodule OptimalSystemAgent.Tools.Builtins.Pty.PtyStart do
  @moduledoc """
  Spawn a command under a pseudo-terminal (real tty) and return a session id.

  This is the interactive complement to `shell_execute`, which redirects stdin
  from `/dev/null` and therefore cannot drive programs that REQUIRE a tty
  (vim/nano, language REPLs, `ssh`/`sudo`/installer prompts, `top`, anything
  using readline or curses). Drive the session afterwards with `pty_send`,
  observe it with `pty_read`, synchronise with `pty_wait`, and end it with
  `pty_stop`.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.Safety.DangerousCommands
  alias OptimalSystemAgent.Shell.Pty.Manager
  alias OptimalSystemAgent.Tools.UseContext

  @impl true
  def name, do: "pty_start"

  @impl true
  def aliases, do: ["pty_spawn"]

  @impl true
  def search_hint,
    do: "run an interactive terminal program that needs a real tty (vim, REPL, ssh)"

  @impl true
  def description do
    """
    Start an interactive program under a real pseudo-terminal (tty) and return a session id.

    Use this instead of shell_execute when the program needs a tty: editors (vim, nano),
    REPLs (python, irb, node), prompting installers, ssh/sudo password prompts, or curses
    UIs. Returns `{session id}`. Then use pty_send to type keys, pty_read to see the screen,
    pty_wait to block until output appears, and pty_stop to end it.
    """
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" =>
            "The command to run under the pty, e.g. \"python3\", \"vim notes.txt\"."
        },
        "name" => %{
          "type" => "string",
          "description" =>
            "Optional friendly name to address the session by (in addition to its id)."
        },
        "cols" => %{
          "type" => "integer",
          "description" => "Initial terminal columns (default 80)."
        },
        "rows" => %{"type" => "integer", "description" => "Initial terminal rows (default 24)."},
        "cwd" => %{
          "type" => "string",
          "description" => "Working directory (default: session cwd)."
        }
      },
      "required" => ["command"]
    }
  end

  # ── Loading / semantics ───────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: true

  @impl true
  def safety, do: :terminal

  # ── Permission gate — same hard circuit-breaker as the exec tools ─────
  @impl true
  def check_permissions(%{"command" => command} = input, _ctx) when is_binary(command) do
    case DangerousCommands.check_command(command) do
      {:blocked, reason} -> {:deny, "Blocked: #{reason}. Run it yourself if genuinely intended."}
      :ok -> {:allow, input}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Execute ───────────────────────────────────────────────────────────
  @impl true
  def execute(input, %UseContext{} = ctx), do: run(input, ctx.session_id)

  @impl true
  def execute(input), do: run(input, nil)

  defp run(%{"command" => command} = input, session_id) when is_binary(command) do
    opts =
      [session_id: session_id]
      |> put_opt(:name, input["name"])
      |> put_opt(:cols, input["cols"])
      |> put_opt(:rows, input["rows"])
      |> put_opt(:cwd, input["cwd"])

    case Manager.start(command, opts) do
      {:ok, id} ->
        {:ok,
         "Started PTY session #{id}#{name_suffix(input["name"])} running: #{command}\n" <>
           "Use pty_read (session: \"#{id}\") to see output, pty_send to type, pty_stop to end."}

      {:error, reason} ->
        {:error, "pty_start failed: #{reason}"}
    end
  end

  defp run(_input, _session_id), do: {:error, "Missing required parameter: command"}

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp name_suffix(nil), do: ""
  defp name_suffix(""), do: ""
  defp name_suffix(name), do: " (name: #{name})"
end
