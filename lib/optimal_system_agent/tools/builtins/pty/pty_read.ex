defmodule OptimalSystemAgent.Tools.Builtins.Pty.PtyRead do
  @moduledoc """
  Read the current state of a PTY session — screen text, scrollback, cursor, or
  lifecycle status.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Shell.Pty.Manager
  alias OptimalSystemAgent.Tools.Builtins.Pty.Shared

  @impl true
  def name, do: "pty_read"

  @impl true
  def aliases, do: ["pty_screen"]

  @impl true
  def search_hint, do: "read the current screen / scrollback / status of a pty session"

  @impl true
  def description do
    """
    Read a PTY session's state. `mode`:
      "screen"     (default) the current visible screen as plain text
      "scrollback" lines that have scrolled off the top (oldest first)
      "cursor"     1-based cursor row/col
      "status"     liveness, exit code, size, generation counter

    NOTE ON THE SCREEN MODEL: OSA uses a pragmatic (not pixel-perfect) terminal
    emulator. Colors/styles are stripped; cursor addressing, line/screen erase,
    and scrolling are handled, so shells, REPLs and prompts render cleanly.
    Full-screen curses apps (e.g. vim) render readably but may leave minor
    residue since the alternate-screen buffer is not modelled.
    """
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session" => %{"type" => "string", "description" => "The pty session id or name."},
        "mode" => %{
          "type" => "string",
          "enum" => ["screen", "scrollback", "cursor", "status"],
          "description" => "What to read (default \"screen\")."
        },
        "lines" => %{
          "type" => "integer",
          "description" => "For mode=scrollback, the most recent N lines (default all)."
        }
      },
      "required" => ["session"]
    }
  end

  @impl true
  def should_defer?, do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def safety, do: :read_only

  @impl true
  def execute(input), do: run(input)

  @impl true
  def execute(input, _ctx), do: run(input)

  defp run(input) do
    with {:ok, session} <- Shared.session_id(input) do
      case input["mode"] || "screen" do
        "screen" -> reply(Manager.screen(session), session, & &1)
        "cursor" -> reply(Manager.cursor(session), session, &"cursor: row #{&1.row}, col #{&1.col}")
        "status" -> reply(Manager.status(session), session, &format_status/1)
        "scrollback" -> read_scrollback(session, input["lines"])
        other -> {:error, "unknown mode: #{other}"}
      end
    end
  end

  defp read_scrollback(session, lines) do
    count = if is_integer(lines) and lines > 0, do: lines, else: :all
    reply(Manager.scrollback(session, count), session, &Enum.join(&1, "\n"))
  end

  defp reply({:ok, value}, _session, formatter), do: {:ok, formatter.(value)}
  defp reply({:error, :not_found}, session, _f), do: {:error, "No such pty session: #{session}"}
  defp reply({:error, reason}, _session, _f), do: {:error, inspect(reason)}

  defp format_status(s) do
    liveness = if s.alive, do: "alive", else: "exited (code #{inspect(s.exit_code)})"

    """
    session:    #{s.id}#{if s.name, do: " (#{s.name})", else: ""}
    command:    #{s.command}
    state:      #{liveness}
    size:       #{s.cols}x#{s.rows} (cols x rows)
    os_pid:     #{inspect(s.os_pid)}
    generation: #{s.generation}
    scrollback: #{s.scrollback_lines} lines
    """
    |> String.trim_trailing()
  end
end
