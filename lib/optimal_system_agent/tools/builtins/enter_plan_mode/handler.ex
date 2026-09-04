defmodule OptimalSystemAgent.Tools.Builtins.EnterPlanMode.Handler do
  @moduledoc """
  Validation, permission, and execution for `enter_plan_mode`.

  State propagation strategy: calls `Agent.Loop.enter_plan_mode/1` via the
  session_id stored in the UseContext. This routes a GenServer call to the
  live Loop process for the current session, mutating `plan_mode_enabled`
  in the server state. This is the correct OTP approach — the Loop GenServer
  owns the authoritative state and is the single writer.

  If no session is running (e.g., in tests), execution falls back gracefully
  and still returns a confirmation message.
  """

  require Logger

  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agent.Loop

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input), do: {:ok, input}

  def validate(_input, _ctx),
    do: {:error, "Input must be a map", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(_input, %UseContext{session_id: session_id}) do
    case Loop.enter_plan_mode(session_id) do
      {:ok, :entered} ->
        {:ok, "Plan mode entered — read-only operations only until exit_plan_mode is called."}

      {:ok, :already_active} ->
        {:ok, "Plan mode is already active."}

      {:error, :no_session} ->
        Logger.error(
          "[enter_plan_mode] no live Loop for session #{inspect(session_id)} — " <>
            "plan_mode flag not toggled. Read-only enforcement will NOT be active."
        )

        {:error,
         "Cannot enter plan mode: no live Loop process for session #{inspect(session_id)}. " <>
           "Read-only enforcement will NOT be active this turn."}

      {:error, reason} ->
        {:error, "Failed to enter plan mode: #{inspect(reason)}"}
    end
  end
end
