defmodule OptimalSystemAgent.Tools.Builtins.BudgetStatus do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.Budget

  @impl true
  def name, do: "budget_status"

  @impl true
  def description, do: "Check API spend budget status and limits"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  @impl true
  def execute(_args) do
    case Budget.get_status() do
      {:ok, status} ->
        output = """
        Budget Status
        ─────────────────────────────────────
        Daily:   $#{status.daily_spent} / $#{status.daily_limit} ($#{status.daily_remaining} remaining)
        Monthly: $#{status.monthly_spent} / $#{status.monthly_limit} ($#{status.monthly_remaining} remaining)
        Per-call limit: $#{status.per_call_limit}
        Ledger entries: #{status.ledger_entries}
        Daily resets:   #{format_datetime(status.daily_reset_at)}
        Monthly resets: #{format_datetime(status.monthly_reset_at)}
        """

        {:ok, String.trim(output)}

      {:error, reason} ->
        {:error, "Failed to fetch budget status: #{reason}"}
    end
  rescue
    e -> {:error, "Budget service unavailable: #{Exception.message(e)}"}
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: inspect(other)
end
