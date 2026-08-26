defmodule OptimalSystemAgent.Tools.Builtins.Pty.PtyWait do
  @moduledoc """
  Block until a PTY session reaches a condition (or a timeout elapses).
  Event-driven: re-checks only when the screen actually changes.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Shell.Pty.Manager
  alias OptimalSystemAgent.Tools.Builtins.Pty.Shared

  @default_timeout_ms 10_000
  @max_timeout_ms 600_000

  @impl true
  def name, do: "pty_wait"

  @impl true
  def aliases, do: ["pty_expect"]

  @impl true
  def search_hint, do: "wait for text/quiescence/exit on an interactive pty session"

  @impl true
  def description do
    """
    Wait until a PTY session meets a condition, then return the screen. Use this
    to synchronise with a slow prompt instead of guessing with sleeps.

    `condition` (exactly one key):
      {"text": "Password:"}   wait until this substring appears on screen
      {"regex": "\\\\$ $"}      wait until the screen text matches this regex
      {"gone": true}          wait until the child process exits
      {"stable_ms": 500}      wait until the screen is unchanged for 500ms (quiesced)

    Returns MATCHED / TIMEOUT / ENDED plus the screen snapshot. Event-driven, so
    it returns as soon as the condition is met rather than at the deadline.
    """
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session" => %{"type" => "string", "description" => "The pty session id or name."},
        "condition" => %{
          "type" => "object",
          "description" =>
            "Exactly one of: text (string), regex (string), gone (true), stable_ms (integer).",
          "properties" => %{
            "text" => %{"type" => "string"},
            "regex" => %{"type" => "string"},
            "gone" => %{"type" => "boolean"},
            "stable_ms" => %{"type" => "integer"}
          }
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Max time to wait in ms (default #{@default_timeout_ms}, max #{@max_timeout_ms})."
        }
      },
      "required" => ["session", "condition"]
    }
  end

  @impl true
  def should_defer?, do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true

  @impl true
  def safety, do: :read_only

  @impl true
  def execute(input), do: run(input)

  @impl true
  def execute(input, _ctx), do: run(input)

  defp run(input) do
    with {:ok, session} <- Shared.session_id(input),
         {:ok, condition} <- Shared.parse_condition(input["condition"]) do
      timeout = clamp_timeout(input["timeout_ms"])

      case Manager.wait(session, condition, timeout) do
        {:ok, outcome} -> {:ok, Shared.format_outcome(outcome)}
        {:error, :not_found} -> {:error, "No such pty session: #{session}"}
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp clamp_timeout(n) when is_integer(n) and n > 0, do: min(n, @max_timeout_ms)
  defp clamp_timeout(_), do: @default_timeout_ms
end
