defmodule OptimalSystemAgent.Tools.Builtins.ProgressNote.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `progress_note`.

  Split mirrors `SessionSearch.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (writes only to the session's own
                              ledger; no sensitive side effects)
    * `execute/2`           — writes to `Agent.ProgressLedger`

  A note prefixed with `goal:` (case-insensitive) sets the ledger goal via
  `ProgressLedger.set_goal/2`; anything else is appended as a timestamped bullet
  via `ProgressLedger.append_entry/2`.
  """

  require Logger

  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Tools.Builtins.ProgressNote.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @goal_prefix ~r/^goal:\s*/i

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"note" => note} = input, _ctx) when is_binary(note) do
    cond do
      String.trim(note) == "" ->
        {:error, "note must not be empty", -32_602}

      String.length(note) > Constants.max_note_chars() ->
        {:error, "note exceeds #{Constants.max_note_chars()} characters", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"note" => _}, _ctx),
    do: {:error, "note must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: note", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"note" => note}, ctx) do
    case session_id(ctx) do
      nil ->
        {:error, "No active session — progress ledger requires a session id"}

      sid ->
        record(sid, String.trim(note))
    end
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: note"}

  # ── Private ────────────────────────────────────────────────────────────

  @spec record(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp record(sid, note) do
    if Regex.match?(@goal_prefix, note) do
      goal = Regex.replace(@goal_prefix, note, "")

      case ProgressLedger.set_goal(sid, goal) do
        {:ok, saved} -> {:ok, "Ledger goal set: #{saved}"}
        {:error, reason} -> {:error, "Failed to set goal: #{inspect(reason)}"}
      end
    else
      case ProgressLedger.append_entry(sid, note) do
        {:ok, _line} -> {:ok, "Recorded to progress ledger: #{note}"}
        {:error, reason} -> {:error, "Failed to record note: #{inspect(reason)}"}
      end
    end
  end

  @spec session_id(UseContext.t()) :: String.t() | nil
  defp session_id(%{session_id: sid}) when is_binary(sid) and sid != "", do: sid
  defp session_id(_), do: nil
end
