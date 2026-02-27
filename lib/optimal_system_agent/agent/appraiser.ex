defmodule OptimalSystemAgent.Agent.Appraiser do
  @moduledoc """
  Task value estimation with role-based costing.

  Estimates the human-equivalent cost of tasks based on complexity
  and the role required to perform them. Uses rate data from
  priv/data/role_rates.json.
  """

  require Logger

  @doc """
  Estimate cost for a single task.

  Returns %{complexity, role, estimated_hours, hourly_rate, estimated_cost_usd, confidence}
  """
  @spec estimate(integer(), atom()) :: map()
  def estimate(complexity, role)
      when is_integer(complexity) and complexity >= 1 and complexity <= 10 do
    rates = load_rates()
    role_str = to_string(role)

    role_info =
      get_in(rates, ["roles", role_str]) || %{"hourly_rate" => 100, "label" => "Unknown"}

    hours = get_in(rates, ["complexity_hours", to_string(complexity)]) || complexity * 1.0

    hourly_rate = role_info["hourly_rate"] || 100
    cost = hours * hourly_rate

    # Confidence decreases with complexity (harder to estimate)
    confidence = max(0.3, 1.0 - (complexity - 1) * 0.08)

    %{
      complexity: complexity,
      role: role,
      role_label: role_info["label"] || to_string(role),
      estimated_hours: hours,
      hourly_rate: hourly_rate,
      estimated_cost_usd: Float.round(cost, 2),
      confidence: Float.round(confidence, 2)
    }
  end

  def estimate(complexity, role) when is_integer(complexity) do
    estimate(max(1, min(10, complexity)), role)
  end

  @doc """
  Estimate aggregate cost for multiple sub-tasks.

  Each sub_task should be a map with :complexity (integer) and :role (atom).
  Returns aggregate %{sub_tasks, total_hours, total_cost_usd, avg_confidence}
  """
  @spec estimate_task([map()]) :: map()
  def estimate_task(sub_tasks) when is_list(sub_tasks) do
    estimates =
      Enum.map(sub_tasks, fn task ->
        complexity = Map.get(task, :complexity, 5)
        role = Map.get(task, :role, :backend)
        estimate(complexity, role)
      end)

    total_hours = estimates |> Enum.map(& &1.estimated_hours) |> Enum.sum() |> to_float()
    total_cost = estimates |> Enum.map(& &1.estimated_cost_usd) |> Enum.sum() |> to_float()

    avg_confidence =
      if estimates == [] do
        0.0
      else
        estimates |> Enum.map(& &1.confidence) |> Enum.sum() |> to_float() |> Kernel./(length(estimates))
      end

    %{
      sub_tasks: estimates,
      count: length(estimates),
      total_hours: Float.round(total_hours, 2),
      total_cost_usd: Float.round(total_cost, 2),
      avg_confidence: Float.round(avg_confidence, 2)
    }
  end

  # Load rates from priv/data/role_rates.json with caching
  defp load_rates do
    case :persistent_term.get({__MODULE__, :rates}, nil) do
      nil ->
        rates = do_load_rates()
        :persistent_term.put({__MODULE__, :rates}, rates)
        rates

      cached ->
        cached
    end
  end

  defp do_load_rates do
    path = resolve_data_path("role_rates.json")

    if path && File.exists?(path) do
      case File.read(path) |> then(fn {:ok, data} -> Jason.decode(data) end) do
        {:ok, rates} ->
          rates

        _ ->
          Logger.warning("[Appraiser] Failed to parse role_rates.json, using defaults")
          default_rates()
      end
    else
      Logger.info("[Appraiser] role_rates.json not found, using defaults")
      default_rates()
    end
  rescue
    _ -> default_rates()
  end

  defp resolve_data_path(filename) do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} -> Path.join([File.cwd!(), "priv", "data", filename])
      priv_dir -> Path.join([to_string(priv_dir), "data", filename])
    end
  rescue
    _ -> Path.join([File.cwd!(), "priv", "data", filename])
  end

  defp to_float(x) when is_float(x), do: x
  defp to_float(x) when is_integer(x), do: x * 1.0

  defp default_rates do
    %{
      "roles" => %{
        "lead" => %{"hourly_rate" => 150, "label" => "Tech Lead"},
        "backend" => %{"hourly_rate" => 120, "label" => "Backend Engineer"},
        "frontend" => %{"hourly_rate" => 110, "label" => "Frontend Engineer"},
        "data" => %{"hourly_rate" => 130, "label" => "Data Engineer"},
        "qa" => %{"hourly_rate" => 90, "label" => "QA Engineer"},
        "design" => %{"hourly_rate" => 100, "label" => "Designer"},
        "infra" => %{"hourly_rate" => 140, "label" => "Infrastructure Engineer"},
        "red_team" => %{"hourly_rate" => 160, "label" => "Security Engineer"},
        "services" => %{"hourly_rate" => 115, "label" => "Services Engineer"}
      },
      "complexity_hours" => %{
        "1" => 0.25,
        "2" => 0.5,
        "3" => 1.0,
        "4" => 2.0,
        "5" => 4.0,
        "6" => 8.0,
        "7" => 16.0,
        "8" => 24.0,
        "9" => 40.0,
        "10" => 80.0
      }
    }
  end
end
