defmodule OptimalSystemAgent.Tools.Builtins.Goal.Handler do
  @moduledoc """
  Validation, permissioning, and execution for `create_goal` / `update_goal`.

  ## Why the model cannot simply declare victory

  `create_goal` writes through `GoalTracker.anchor_new/3`, which refuses while a
  goal is live, and `update_goal` has no parameter that can reach the objective
  or the criteria. Together those reproduce Codex's guarantee: the objective is
  authored once by the model and is immutable to it thereafter
  (`update_goal` there hardcodes `objective: None`, and `create_goal` fails with
  "cannot create a new goal because this thread has an unfinished goal").

  `update_goal(status: "complete")` calls `GoalTracker.claim_complete/1`, which
  forces a verification round rather than completing anything. Only the skeptic
  panel, via `GoalTracker.advance/2`, can reach `:completed`.

  `update_goal(status: "blocked")` calls `GoalTracker.claim_blocked/1`, which
  enforces the three-consecutive-turn rule in code. Codex states that rule in
  prose and trusts the model to count.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Tools.Builtins.Goal.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── create_goal ────────────────────────────────────────────────────────

  @spec validate_create(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate_create(%{"objective" => objective} = input, _ctx) when is_binary(objective) do
    criteria = Map.get(input, "acceptance_criteria")

    cond do
      String.trim(objective) == "" ->
        {:error, "objective must not be empty", -32_602}

      String.downcase(String.trim(objective)) in ~w(end stop pause resume clear cancel off reset) ->
        {:error,
         "That is a goal control command, not an objective. Use /goal pause or /goal clear.",
         -32_602}

      String.length(objective) > Constants.max_objective_chars() ->
        {:error, "objective must be at most #{Constants.max_objective_chars()} characters",
         -32_602}

      not (is_nil(criteria) or is_binary(criteria)) ->
        {:error, "acceptance_criteria must be a string", -32_602}

      is_binary(criteria) and String.length(criteria) > Constants.max_criteria_chars() ->
        {:error,
         "acceptance_criteria must be at most #{Constants.max_criteria_chars()} characters",
         -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate_create(%{"objective" => _}, _ctx),
    do: {:error, "objective must be a string", -32_602}

  def validate_create(_, _ctx),
    do: {:error, "Missing required parameter: objective", -32_602}

  @spec execute_create(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute_create(input, ctx) do
    case session_id(ctx) do
      nil ->
        {:error, "No session is active, so there is nothing to anchor a goal to."}

      sid ->
        objective = input |> Map.get("objective") |> String.trim()

        opts =
          []
          |> put_text(:acceptance_criteria, Map.get(input, "acceptance_criteria"))
          |> put_text(:constraints, Map.get(input, "constraints"))

        anchor(sid, objective, opts)
    end
  end

  defp anchor(sid, objective, opts) do
    case GoalTracker.anchor_new(sid, objective, opts) do
      {:ok, snap} ->
        {:ok,
         "Goal anchored (#{snap.goal_id}). Objective and acceptance criteria are now frozen " <>
           "for the life of this goal.\n\nObjective: #{objective}" <>
           criteria_echo(opts) <>
           "\n\nThe session will keep returning to this goal after each answer until an " <>
           "independent review panel finds it met."}

      {:error, {:goal_active, snap}} ->
        {:error, goal_active_refusal(snap)}
    end
  rescue
    e ->
      Logger.warning("[create_goal] anchor failed: #{inspect(e)}")
      {:error, "Failed to anchor goal: #{Exception.message(e)}"}
  end

  # A refusal that names only what is forbidden is how the deadlock got missed:
  # the agent that hit this wall had three exits and could see none of them. Say
  # what to do, in the order it should be tried, and price each one — an
  # affordance that hides its mechanism is the defect this codebase spent the
  # week removing.
  #
  # `ask_user` is off by default, so "ask the user" is deliberately NOT offered
  # here: suggesting a tool that is not loaded is how an unattended run parks on
  # a question nobody will answer.
  defp goal_active_refusal(snap) do
    update = Constants.update_tool_name()

    "cannot create a new goal because this session has an unfinished goal; " <>
      "complete the existing goal first.\n\nActive objective: #{snap.goal}\n" <>
      "Status: #{snap.status}. Turns spent: #{snap.turn_count}. " <>
      "Verification rounds: #{snap.verify_run_count}/#{GoalTracker.max_runs_label()}.\n\n" <>
      "The objective cannot be edited or replaced while it is live — that freeze is " <>
      "what stops a hard goal being quietly traded for an easy one.\n\n" <>
      "Ways out, in order:\n" <>
      "  1. Keep working toward it. This is almost always the right one.\n" <>
      "  2. #{update}(status: \"complete\") if it is genuinely met. That is a claim, not " <>
      "a verdict — an independent review panel decides, and an early claim just spends " <>
      "a verification round.\n" <>
      "  3. #{update}(status: \"blocked\") if the SAME blocker has recurred across " <>
      "#{GoalTracker.blocked_threshold()} consecutive goal turns and you cannot progress " <>
      "without external input. Not because the work is hard or slow.\n" <>
      "  4. #{update}(status: \"abandoned\") if this objective is no longer the work at " <>
      "all — the direction genuinely changed, not the difficulty. It ends the goal " <>
      "permanently, records it as abandoned against the objective above, and lets you " <>
      "anchor the new work. The successor inherits the turns and verification rounds " <>
      "already spent, so abandoning redirects this run without refilling its budget."
  end

  defp criteria_echo(opts) do
    case Keyword.get(opts, :acceptance_criteria) do
      c when is_binary(c) and c != "" -> "\n\nAcceptance criteria:\n#{c}"
      _ -> ""
    end
  end

  # ── update_goal ────────────────────────────────────────────────────────

  @spec validate_update(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate_update(%{"status" => status} = input, _ctx) when is_binary(status) do
    if String.downcase(String.trim(status)) == "awaiting_user" do
      if Enum.all?(~w(question criterion work_summary artifact), fn key ->
           is_binary(input[key]) and String.trim(input[key]) != "" and
             String.length(input[key]) <= 4000
         end) do
        {:ok, input}
      else
        {:error,
         "awaiting_user requires question, criterion, work_summary, and artifact (nonempty, at most 4000 characters each)",
         -32_602}
      end
    else
      if String.downcase(String.trim(status)) in Constants.model_statuses() do
        {:ok, input}
      else
        {:error,
         "#{Constants.update_tool_name()} can only mark the existing goal complete or blocked, " <>
           "or abandon it outright; pause, resume, and objective changes are controlled by the " <>
           "user", -32_602}
      end
    end
  end

  def validate_update(%{"status" => _}, _ctx),
    do: {:error, "status must be a string", -32_602}

  def validate_update(_, _ctx),
    do: {:error, "Missing required parameter: status", -32_602}

  @spec execute_update(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute_update(input, ctx) do
    case session_id(ctx) do
      nil ->
        {:error, "No session is active, so there is no goal to update."}

      sid ->
        if String.downcase(String.trim(Map.get(input, "status", ""))) == "awaiting_user" do
          case GoalTracker.request_decision(sid, input) do
            {:ok, _} -> {:ok, GoalTracker.waiting_message(sid)}
            {:error, reason} -> {:error, "Cannot wait for a decision: #{inspect(reason)}"}
          end
        else
          input
          |> Map.get("status")
          |> String.trim()
          |> String.downcase()
          |> apply_status(sid)
        end
    end
  end

  defp apply_status("complete", sid) do
    case GoalTracker.claim_complete(sid) do
      {:ok, _snap} ->
        {:ok,
         "Completion claim recorded. This does not end the goal: an independent " <>
           "read-only review panel will now audit the current state against the founding " <>
           "request and the frozen acceptance criteria.\n\n" <>
           "Keep the evidence reachable — the files you changed, the command output you " <>
           "captured, the tests you ran. If the panel finds a gap the goal stays active " <>
           "and you will be returned to it with the objections."}

      {:error, :not_live} ->
        {:error, "There is no live goal to complete."}
    end
  rescue
    e -> {:error, "Failed to record completion claim: #{Exception.message(e)}"}
  end

  defp apply_status("blocked", sid) do
    threshold = GoalTracker.blocked_threshold()

    case GoalTracker.claim_blocked(sid) do
      {:blocked, _snap} ->
        {:ok,
         "Goal marked blocked after #{threshold} consecutive blocked turns. Autonomous " <>
           "continuation has stopped. Tell the user precisely what is needed to unblock it."}

      {:pending, streak, _snap} ->
        {:ok,
         "Blocked attempt #{streak}/#{threshold} recorded. #{threshold} consecutive blocked " <>
           "goal turns are required before the goal pauses — continue retrying or refining " <>
           "the approach.\n\n" <>
           "A blocker that you have not yet tried a materially different approach against " <>
           "is not an impasse. Do not use this because the work is hard, slow, or uncertain."}

      {:error, :not_live} ->
        {:error, "There is no live goal to block."}
    end
  rescue
    e -> {:error, "Failed to record blocked claim: #{Exception.message(e)}"}
  end

  defp apply_status("abandoned", sid) do
    case GoalTracker.abandon(sid) do
      {:ok, snap} ->
        {:ok,
         "Goal abandoned (#{snap.goal_id}). It is over — it did not complete, and that is now " <>
           "permanently recorded against its objective in the progress ledger.\n\n" <>
           "Abandoned objective: #{snap.goal}\n\n" <>
           "You may now anchor the new work with #{Constants.create_tool_name()}. The " <>
           "successor goal inherits the #{snap.turn_count} turn(s) and " <>
           "#{snap.verify_run_count}/#{GoalTracker.max_runs_label()} verification round(s) already " <>
           "spent: abandoning changes what this run is working on, not how much budget it " <>
           "has left.\n\n" <>
           "Tell the user plainly that the previous objective was abandoned and why — a " <>
           "goal that ends without being met must never read as one that was achieved."}

      {:error, :not_live} ->
        {:error, "There is no live goal to abandon."}
    end
  rescue
    e -> {:error, "Failed to abandon goal: #{Exception.message(e)}"}
  end

  defp apply_status(other, _sid),
    do: {:error, "unsupported status `#{other}`"}

  # ── Shared ─────────────────────────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  defp put_text(opts, _key, value) when not is_binary(value), do: opts

  defp put_text(opts, key, value) do
    case String.trim(value) do
      "" -> opts
      trimmed -> Keyword.put(opts, key, trimmed)
    end
  end

  defp session_id(%{session_id: sid}) when is_binary(sid) and sid != "", do: sid
  defp session_id(_), do: nil
end
