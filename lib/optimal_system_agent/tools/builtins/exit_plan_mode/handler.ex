defmodule OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Handler do
  @moduledoc """
  Validation, permission, and execution for `exit_plan_mode`.

  State propagation strategy: calls `Agent.Loop.exit_plan_mode/1` via the
  session_id stored in the UseContext. The Loop GenServer restores
  `plan_mode_enabled` to the value captured at `enter_plan_mode` time,
  ensuring the toggle is reversible.

  The optional `plan` argument is logged for observability and echoed in the
  confirmation message so callers can verify the plan was recorded.
  """

  require Logger

  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agent.Loop

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input) do
    case Map.get(input, "plan") do
      nil ->
        {:ok, input}

      plan when is_binary(plan) ->
        {:ok, input}

      _other ->
        {:error, "plan must be a string", -32_602}
    end
  end

  def validate(_input, _ctx),
    do: {:error, "Input must be a map", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(input, %UseContext{session_id: session_id}) do
    plan = Map.get(input, "plan")

    if plan do
      Logger.info("[exit_plan_mode] session=#{session_id} plan=#{String.slice(plan, 0, 200)}")
    end

    case Loop.exit_plan_mode(session_id) do
      {:ok, :exited} ->
        confirmation = build_confirmation(plan)
        {:ok, confirmation}

      {:ok, :was_not_active} ->
        {:ok, "Plan mode was not active — no change made."}

      {:error, :no_session} ->
        confirmation = build_confirmation(plan)
        {:ok, "#{confirmation} (offline — no live session to update)"}

      {:error, reason} ->
        {:error, "Failed to exit plan mode: #{inspect(reason)}"}
    end
  end

  defp build_confirmation(nil),
    do: "Plan mode exited. Execution tools restored."

  defp build_confirmation(plan),
    do: "Plan mode exited. Plan to execute: #{plan}"
end
