defmodule Canopy.AlertEvaluator do
  @moduledoc """
  Periodic evaluator for alert rules.

  Runs on a configurable interval (default: 60s), checks all enabled
  alert rules against current system state, and fires alerts when
  conditions are met. Respects cooldown periods.
  """
  use GenServer
  require Logger

  alias Canopy.Repo
  alias Canopy.Schemas.{AlertRule, AlertHistory, Agent, Session}
  import Ecto.Query

  @eval_interval :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Evaluate all alert rules immediately."
  def evaluate_now do
    GenServer.cast(__MODULE__, :evaluate)
  end

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{last_eval: nil}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    evaluate_all_rules()
    schedule_next()
    {:noreply, %{state | last_eval: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast(:evaluate, state) do
    evaluate_all_rules()
    {:noreply, %{state | last_eval: DateTime.utc_now()}}
  end

  defp schedule_next do
    Process.send_after(self(), :evaluate, @eval_interval)
  end

  defp evaluate_all_rules do
    rules = Repo.all(from r in AlertRule, where: r.enabled == true)

    for rule <- rules do
      if should_evaluate?(rule) do
        case evaluate_rule(rule) do
          {:triggered, value} ->
            fire_alert(rule, value)

          :ok ->
            :ok
        end
      end
    end
  end

  defp should_evaluate?(%AlertRule{last_triggered_at: nil}), do: true

  defp should_evaluate?(%AlertRule{last_triggered_at: last, cooldown_minutes: cooldown}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last, :minute)
    elapsed >= cooldown
  end

  defp evaluate_rule(%AlertRule{entity: entity, field: field, operator: op, value: threshold}) do
    current_value = get_entity_value(entity, field)

    if current_value != nil and compare(current_value, op, threshold) do
      {:triggered, to_string(current_value)}
    else
      :ok
    end
  end

  defp get_entity_value("Agent", "error_count") do
    Repo.aggregate(from(a in Agent, where: a.status == "error"), :count)
  end

  defp get_entity_value("Agent", "active_count") do
    Repo.aggregate(from(a in Agent, where: a.status in ["active", "working"]), :count)
  end

  defp get_entity_value("Session", "active_count") do
    Repo.aggregate(from(s in Session, where: s.status == "active"), :count)
  end

  defp get_entity_value("Budget", "total_today_cents") do
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    Repo.one(
      from ce in Canopy.Schemas.CostEvent,
        where: ce.inserted_at >= ^today,
        select: coalesce(sum(ce.cost_cents), 0)
    )
  end

  defp get_entity_value(_, _), do: nil

  defp compare(current, "gt", threshold), do: to_number(current) > to_number(threshold)
  defp compare(current, "gte", threshold), do: to_number(current) >= to_number(threshold)
  defp compare(current, "lt", threshold), do: to_number(current) < to_number(threshold)
  defp compare(current, "lte", threshold), do: to_number(current) <= to_number(threshold)
  defp compare(current, "eq", threshold), do: to_string(current) == to_string(threshold)
  defp compare(current, "neq", threshold), do: to_string(current) != to_string(threshold)
  defp compare(_, _, _), do: false

  defp to_number(val) when is_integer(val), do: val
  defp to_number(val) when is_float(val), do: val

  defp to_number(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp fire_alert(rule, entity_value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Record in history
    %AlertHistory{
      rule_id: rule.id,
      entity_value: entity_value,
      inserted_at: now
    }
    |> Repo.insert!()

    # Update rule
    rule
    |> Ecto.Changeset.change(
      trigger_count: rule.trigger_count + 1,
      last_triggered_at: now
    )
    |> Repo.update!()

    # Broadcast
    Canopy.EventBus.broadcast(Canopy.EventBus.activity_topic(), %{
      event: "alert.triggered",
      rule_id: rule.id,
      rule_name: rule.name,
      entity: rule.entity,
      field: rule.field,
      value: entity_value
    })

    Logger.info(
      "[AlertEvaluator] Alert triggered: #{rule.name} (#{rule.entity}.#{rule.field} #{rule.operator} #{rule.value})"
    )
  end
end
