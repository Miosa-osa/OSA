defmodule OptimalSystemAgent.Tools.Builtins.Pty.PtyStop do
  @moduledoc """
  Kill the child process of a PTY session and stop it.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Shell.Pty.Manager
  alias OptimalSystemAgent.Tools.Builtins.Pty.Shared

  @impl true
  def name, do: "pty_stop"

  @impl true
  def aliases, do: ["pty_kill"]

  @impl true
  def search_hint, do: "terminate an interactive pty session"

  @impl true
  def description do
    "Stop a PTY session started with pty_start: sends SIGTERM then SIGKILL to the " <>
      "child and removes the session. Idempotent — stopping an already-exited session is fine."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session" => %{"type" => "string", "description" => "The pty session id or name."}
      },
      "required" => ["session"]
    }
  end

  @impl true
  def should_defer?, do: true

  @impl true
  def safety, do: :terminal

  @impl true
  def execute(input), do: run(input)

  @impl true
  def execute(input, _ctx), do: run(input)

  defp run(input) do
    with {:ok, session} <- Shared.session_id(input) do
      case Manager.stop(session) do
        :ok -> {:ok, "Stopped pty session #{session}."}
        {:error, :not_found} -> {:ok, "pty session #{session} not found (already stopped)."}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end
end
