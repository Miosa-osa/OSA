defmodule OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Handler do
  @moduledoc """
  Validation, permission, and execution for `exit_plan_mode`.

  State propagation strategy: calls `Agent.Loop.exit_plan_mode/1` via the
  session_id stored in the UseContext. The Loop GenServer restores
  `plan_mode_enabled` to the value captured at `enter_plan_mode` time,
  ensuring the toggle is reversible.

  When a `plan` argument is provided, this ALSO routes into the same
  plan → approve → execute round-trip an investigative plan-mode turn uses
  (`Agent.PlanStore.put/3` + the `plan_proposed` event): the plan is written
  to the session's durable plan file and the TUI's `plan_review` dialog opens
  exactly as it would for a user-toggled plan-mode turn. This is what makes
  the model-invoked `enter_plan_mode` → (investigate) → `exit_plan_mode(plan:
  ...)` sequence a first-class alternative to the `/plan` toggle: the model
  decides when a task needs planning ceremony, but approval still round-trips
  through the user via the existing dialog. Calling with no `plan` argument
  is a no-op restore-permissions-only exit (unchanged behavior).
  """

  require Logger

  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.PlanStore

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
  def execute(input, %UseContext{session_id: session_id} = ctx) do
    plan = Map.get(input, "plan")

    if plan do
      Logger.info("[exit_plan_mode] session=#{session_id} plan=#{String.slice(plan, 0, 200)}")
      stash_pending_plan(session_id, plan, ctx)
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
    do:
      "Plan mode exited. Plan submitted for approval — the user will review it " <>
        "before execution continues.\n\n#{plan}"

  # Route the model-authored plan into the same approval round-trip an
  # investigative plan-mode turn uses: write the durable plan file, index the
  # pending approval, and emit `plan_proposed` so the TUI opens its
  # `plan_review` dialog (`Agent.PlanMode.approve/1` / `reject/1` / `edit/2`
  # then read/act on exactly this state).
  defp stash_pending_plan(session_id, plan, ctx) when is_binary(session_id) and is_binary(plan) do
    original_input = original_user_input(ctx)
    PlanStore.put(session_id, plan, original_input)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :system_event,
         event: :plan_proposed,
         session_id: session_id,
         plan: plan
       }}
    )
  rescue
    e -> Logger.warning("[exit_plan_mode] failed to stash pending plan: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("[exit_plan_mode] failed to stash pending plan: #{inspect(reason)}")
  end

  defp stash_pending_plan(_session_id, _plan, _ctx), do: :ok

  # Best-effort recovery of the turn's original user input from the tool-use
  # context's message list, mirroring `MessageHandler.original_user_input/1`.
  defp original_user_input(%UseContext{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} when is_binary(content) -> content
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _ -> false
    end)
  end

  defp original_user_input(_), do: ""
end
