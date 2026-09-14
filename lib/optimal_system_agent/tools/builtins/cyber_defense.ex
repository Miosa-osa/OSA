defmodule OptimalSystemAgent.Tools.Builtins.CyberDefense do
  @moduledoc "Runs reproducible defensive simulations in disposable, network-isolated labs."
  use OptimalSystemAgent.Tools.Behaviour
  alias OptimalSystemAgent.Security.DefenseLab

  @impl true
  def name, do: "cyber_defense"
  @impl true
  def description,
    do:
      "Discover and run isolated cyber-defense labs: baseline attack, telemetry, control gaps, lab remediation, retest and evidence. SQL injection, path traversal, authentication rate limits."

  @impl true
  def should_defer?, do: true
  @impl true
  def available?, do: true
  @impl true
  def parameters do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action"],
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["scenarios", "run"]},
        "scenario" => %{
          "type" => "string",
          "enum" => ~w(all sql_injection path_traversal auth_rate_limit)
        },
        "remediation" => %{
          "type" => "string",
          "enum" => ~w(apply none ineffective),
          "description" =>
            "apply fixes the lab; none/ineffective are negative controls, expected to remain unverified"
        },
        "timeout_seconds" => %{"type" => "integer", "minimum" => 5, "maximum" => 60}
      }
    }
  end

  @impl true
  def execute(%{"action" => "scenarios"}), do: {:ok, Jason.encode!(DefenseLab.scenarios())}

  def execute(%{"action" => "run"} = args) do
    case DefenseLab.run(args) do
      {:ok, report} -> {:ok, Jason.encode!(report)}
      {:error, error} -> {:error, Jason.encode!(error)}
    end
  end

  def execute(_),
    do: {:error, Jason.encode!(%{code: "invalid_action", message: "Use scenarios or run"})}
end
