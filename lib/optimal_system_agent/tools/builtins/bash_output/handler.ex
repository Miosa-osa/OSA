defmodule OptimalSystemAgent.Tools.Builtins.BashOutput.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `bash_output`.

  INTERFACE layer — thin wrapper over the background-shell MECHANISM
  (`OptimalSystemAgent.Shell.BackgroundManager`). Split mirrors
  `TaskOutput.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (polling is session-local)
    * `execute/2`           — polls (or kills) the background command by id
  """

  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"background_id" => id} = input, _ctx) when is_binary(id) do
    if String.trim(id) == "" do
      {:error, "background_id must not be empty", -32_602}
    else
      {:ok, input}
    end
  end

  def validate(%{"background_id" => _}, _ctx),
    do: {:error, "background_id must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: background_id", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"background_id" => id} = input, _ctx) do
    result =
      if truthy?(input["kill"]) do
        BackgroundManager.kill(id)
      else
        BackgroundManager.output(id)
      end

    case result do
      {:ok, snapshot} ->
        # WS6: the model has now SEEN a terminal status — claim the per-task
        # notified flag so the completion broadcast doesn't ALSO queue a
        # <task-notification> (poll + completion race → exactly one).
        if snapshot.status != :running do
          OptimalSystemAgent.Agent.TaskNotifications.mark_notified(snapshot.id)
        end

        {:ok, format_snapshot(snapshot)}

      {:error, :not_found} ->
        {:ok, not_found_message(id)}
    end
  rescue
    e -> {:error, "Failed to get background output: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx),
    do: {:error, "Missing required parameter: background_id"}

  # ── Private ────────────────────────────────────────────────────────────

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp not_found_message(id) do
    "No background command with id \"#{id}\". It may have finished and been " <>
      "retired, been killed, or the id may be incorrect."
  end

  defp format_snapshot(snap) do
    header =
      [
        "Background command #{snap.id} is #{snap.status}.",
        "- Command: #{snap.command}",
        "- Status: #{snap.status}",
        exit_line(snap),
        output_file_line(snap),
        "- Output bytes: #{snap.bytes}#{if snap.truncated, do: " (truncated)", else: ""}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body =
      case String.trim(snap.output) do
        "" -> "(no output yet)"
        out -> out
      end

    header <> "\n\n--- output ---\n" <> body
  end

  defp exit_line(%{exit_code: nil}), do: nil
  defp exit_line(%{exit_code: code}), do: "- Exit code: #{code}"

  defp output_file_line(%{output_file: file}) when is_binary(file),
    do: "- Full output file: #{file} (read with the read tool)"

  defp output_file_line(_), do: nil
end
