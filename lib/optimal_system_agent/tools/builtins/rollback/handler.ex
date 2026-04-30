defmodule OptimalSystemAgent.Tools.Builtins.Rollback.Handler do
  @moduledoc """
  Validation and execution logic for the `rollback` tool.

  Three actions:
    * `list`    — list recent checkpoints (no checkpoint_id required)
    * `diff`    — show what changed in a checkpoint (checkpoint_id required)
    * `restore` — restore files from a checkpoint back to disk (checkpoint_id required)
  """

  alias OptimalSystemAgent.FSCheckpoint.Server
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when action in ~w(list diff restore) do
    if action in ~w(diff restore) and not Map.has_key?(input, "checkpoint_id") do
      {:error, "checkpoint_id is required for #{action} action", -32_602}
    else
      {:ok, input}
    end
  end

  def validate(%{"action" => action}, _ctx),
    do: {:error, "Invalid action: #{action}. Use list, diff, or restore.", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "list"} = input, _ctx) do
    limit = Map.get(input, "limit", 20)

    case Server.list_checkpoints(limit) do
      {:ok, []} ->
        {:ok,
         "No checkpoints found. Checkpoints are created automatically before destructive file operations."}

      {:ok, entries} ->
        formatted =
          entries
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, idx} ->
            "#{idx}. [#{entry.id}] #{entry.tool} — #{entry.files} (#{entry.date})"
          end)
          |> Enum.join("\n")

        {:ok, "Filesystem Checkpoints:\n#{formatted}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{"action" => "diff", "checkpoint_id" => id}, _ctx) do
    case Server.diff(id) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "restore", "checkpoint_id" => id}, _ctx) do
    case Server.restore(id) do
      {:ok, msg} -> {:ok, msg}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(input, _ctx), do: {:error, "Invalid rollback input: #{inspect(input)}"}
end
