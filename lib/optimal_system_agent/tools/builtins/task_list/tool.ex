defmodule OptimalSystemAgent.Tools.Builtins.TaskList.Tool do
  @moduledoc """
  List known subagent runs from the lifecycle store.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.RunStore

  @impl true
  def name, do: "task_list"

  @impl true
  def aliases, do: ["agent_list", "list_tasks", "list_subagents"]

  @impl true
  def search_hint, do: "list running and recently completed subagents"

  @impl true
  def description do
    "List known subagent runs, including active and completed background agents."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "status" => %{
          "type" => "string",
          "enum" => ["running", "completed", "failed", "cancelled"],
          "description" => "Optional status filter."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of runs to return. Defaults to 20."
        }
      }
    }
  end

  @impl true
  def execute(input, _ctx) do
    status = parse_status(Map.get(input, "status"))
    limit = parse_limit(Map.get(input, "limit"))

    runs = RunStore.list(status: status, limit: limit)

    if runs == [] do
      {:ok, "No subagent runs found."}
    else
      body =
        runs
        |> Enum.map_join("\n", fn run ->
          "- #{run.agent_id} [#{run.status}] #{run.role} - #{String.slice(run.task, 0, 80)}"
        end)

      {:ok, "## Subagent Runs\n\n#{body}"}
    end
  end

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def to_classifier_input(input), do: input

  defp parse_status(nil), do: nil

  defp parse_status(status) when status in ~w(running completed failed cancelled),
    do: String.to_atom(status)

  defp parse_status(_), do: nil

  defp parse_limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp parse_limit(_), do: 20
end
