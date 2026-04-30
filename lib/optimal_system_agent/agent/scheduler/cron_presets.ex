defmodule OptimalSystemAgent.Agent.Scheduler.CronPresets do
  @moduledoc """
  Cron expression presets with human-readable descriptions and next-run calculation.
  """

  alias OptimalSystemAgent.Agent.Scheduler.CronEngine

  @presets [
    %{id: "every_minute", cron: "* * * * *", label: "Every minute"},
    %{id: "every_5_minutes", cron: "*/5 * * * *", label: "Every 5 minutes"},
    %{id: "every_15_minutes", cron: "*/15 * * * *", label: "Every 15 minutes"},
    %{id: "every_30_minutes", cron: "*/30 * * * *", label: "Every 30 minutes"},
    %{id: "hourly", cron: "0 * * * *", label: "Every hour"},
    %{id: "daily_9am", cron: "0 9 * * *", label: "Daily at 9:00 AM"},
    %{id: "weekly_monday", cron: "0 9 * * 1", label: "Weekly on Monday at 9:00 AM"},
    %{id: "monthly_first", cron: "0 9 1 * *", label: "Monthly on the 1st at 9:00 AM"}
  ]

  def list_presets, do: @presets

  @doc "Resolve a preset id or cron expression to a cron expression."
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Enum.find(@presets, &(&1.id == trimmed or &1.cron == trimmed)) do
      %{cron: cron} ->
        {:ok, cron}

      nil ->
        case CronEngine.parse(trimmed) do
          {:ok, _} -> {:ok, trimmed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def resolve(_), do: {:error, "schedule must be a string"}

  def describe(cron) do
    case Enum.find(@presets, &(&1.cron == cron)) do
      %{label: label} -> label
      nil -> describe_expression(cron)
    end
  end

  def next_run(cron) do
    case CronEngine.parse(cron) do
      {:ok, fields} -> find_next(fields, DateTime.utc_now())
      {:error, _} -> nil
    end
  end

  defp find_next(fields, from) do
    next = DateTime.add(from, 60, :second)
    next = %{next | second: 0, microsecond: {0, 0}}

    # Walk forward minute-by-minute, max 527040 iterations (366 days)
    Enum.reduce_while(0..527_040, next, fn _, candidate ->
      if CronEngine.matches?(fields, candidate) do
        {:halt, candidate}
      else
        {:cont, DateTime.add(candidate, 60, :second)}
      end
    end)
  end

  defp describe_expression(cron) do
    parts = String.split(cron, " ")
    if length(parts) != 5, do: cron, else: build_description(parts)
  end

  defp build_description([min, hour, dom, _month, dow]) do
    time_part = describe_time(min, hour)
    day_part = describe_day(dom, dow)
    String.trim("#{day_part} #{time_part}")
  end

  defp describe_time("*", "*"), do: "every minute"
  defp describe_time("*/" <> n, "*"), do: "every #{n} minutes"
  defp describe_time(min, "*"), do: "at minute #{min} of every hour"
  defp describe_time("0", hour), do: "at #{pad(hour)}:00"
  defp describe_time(min, hour), do: "at #{pad(hour)}:#{pad(min)}"

  defp describe_day("*", "*"), do: ""
  defp describe_day("*", dow), do: "on #{day_name(dow)}"
  defp describe_day(dom, "*"), do: "on day #{dom} of the month"
  defp describe_day(dom, dow), do: "on day #{dom} and #{day_name(dow)}"

  defp day_name("0"), do: "Sunday"
  defp day_name("1"), do: "Monday"
  defp day_name("2"), do: "Tuesday"
  defp day_name("3"), do: "Wednesday"
  defp day_name("4"), do: "Thursday"
  defp day_name("5"), do: "Friday"
  defp day_name("6"), do: "Saturday"
  defp day_name(other), do: "day #{other}"

  defp pad(s) when byte_size(s) == 1, do: "0" <> s
  defp pad(s), do: s
end
