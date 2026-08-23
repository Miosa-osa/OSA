defmodule OptimalSystemAgent.Tools.FailureReporter do
  @moduledoc """
  Unified tool failure logging channel.

  Every tool failure across OSA can be reported through this module, which
  logs structured metadata (tool name, error, sandbox state, session) to the
  telemetry system. The logging is fire-and-forget — it never changes the tool
  result or blocks execution.

  Adapted from HackerAI's `tool-failure.ts` pattern.

  ## Usage

      # In a tool handler after a failure:
      Tools.FailureReporter.report("shell_execute", %{
        error: "command timed out",
        session_id: session_id,
        sandbox: "e2b"
      })
  """

  require Logger

  @type failure_event :: %{
          tool: String.t(),
          error: String.t(),
          session_id: String.t() | nil,
          sandbox: String.t() | nil,
          command: String.t() | nil,
          extra: map() | nil
        }

  @doc """
  Report a tool failure to the telemetry system.

  Fire-and-forget: never raises, never blocks, never changes the tool result.
  """
  @spec report(String.t(), map()) :: :ok
  def report(tool_name, metadata \\ %{}) when is_binary(tool_name) do
    event = %{
      tool: tool_name,
      error: Map.get(metadata, :error) || Map.get(metadata, "error") || "unknown",
      session_id: Map.get(metadata, :session_id) || Map.get(metadata, "session_id"),
      sandbox: Map.get(metadata, :sandbox) || Map.get(metadata, "sandbox"),
      command: Map.get(metadata, :command) || Map.get(metadata, "command"),
      extra: Map.get(metadata, :extra) || Map.get(metadata, "extra")
    }

    :telemetry.execute(
      [:osa, :tool, :failure],
      %{count: 1},
      event
    )

    Logger.debug("[ToolFailure] #{tool_name}: #{event.error}")

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Report a tool failure with a structured error reason."
  @spec report(String.t(), String.t(), keyword()) :: :ok
  def report(tool_name, error, opts) when is_binary(tool_name) and is_binary(error) do
    report(tool_name, %{
      error: error,
      session_id: Keyword.get(opts, :session_id),
      sandbox: Keyword.get(opts, :sandbox),
      command: Keyword.get(opts, :command),
      extra: Keyword.get(opts, :extra)
    })
  end
end
