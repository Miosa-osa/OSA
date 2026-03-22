defmodule OptimalSystemAgent.Agent.Orchestrator.GoalDispatch do
  @moduledoc """
  Goal construction and dispatch prompt generation for multi-agent orchestration.

  Provides three primitives used by the orchestrator's coordination layer:

  - `build_goal/2,3`   — construct a typed goal struct from a role + objective
  - `dispatch/1,2`     — render an agent-facing prompt from a goal (+ optional agent config)
  - `merge_results/1`  — fold a list of agent results into a single merged summary

  ## Goal struct

  ```
  %{
    role:       atom,           # e.g. :backend, :frontend
    objective:  String.t(),
    context:    %{
      files:         [String.t()],
      constraints:   [String.t()],
      prior_results: map(),
      tools:         [String.t()],
      dependencies:  [term()],   # optional
      metadata:      map()       # optional
    },
    built_at:   DateTime.t()
  }
  ```
  """

  # ── Context defaults ─────────────────────────────────────────────────────

  @empty_context %{
    files: [],
    constraints: [],
    prior_results: %{},
    tools: [],
    dependencies: [],
    metadata: %{}
  }

  # ── build_goal/2,3 ───────────────────────────────────────────────────────

  @doc """
  Build a goal with `role` and `objective`, using an empty context.
  """
  @spec build_goal(atom(), String.t()) :: map()
  def build_goal(role, objective), do: build_goal(role, objective, %{})

  @doc """
  Build a goal with `role`, `objective`, and a (possibly partial) `context` map.

  Missing context keys are normalised to their defaults.
  """
  @spec build_goal(atom(), String.t(), map()) :: map()
  def build_goal(role, objective, context) when is_atom(role) and is_binary(objective) do
    trimmed = String.trim(objective)
    normalised = Map.merge(@empty_context, context)

    %{
      role: role,
      objective: trimmed,
      context: normalised,
      built_at: DateTime.utc_now()
    }
  end

  # ── dispatch/1,2 ─────────────────────────────────────────────────────────

  @doc """
  Render a dispatch prompt from `goal` without agent config.
  """
  @spec dispatch(map()) :: String.t()
  def dispatch(goal), do: dispatch(goal, nil)

  @doc """
  Render a dispatch prompt from `goal` and optional `agent_config` map.

  The prompt is designed to give the agent its objective and context without
  prescriptive step-by-step instructions.  The agent decides the approach.
  """
  @spec dispatch(map(), map() | nil) :: String.t()
  def dispatch(goal, agent_config) do
    role_label = goal.role |> to_string() |> String.capitalize()

    sections = [
      goal_section(role_label, goal.objective),
      context_section(goal.context),
      tools_section(goal.context.tools),
      constraints_section(goal.context.constraints),
      execution_section(agent_config)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # ── merge_results/1 ──────────────────────────────────────────────────────

  @doc """
  Merge a list of agent result maps into a single summary map.

  Each result is expected to have at minimum:
  `%{agent: string, status: :ok | :error, output: string}`

  Metadata is optional and preserved when present.

  ## Return shape

  ```
  %{
    status:    :ok | :partial | :error,
    succeeded: [normalised_result],
    failed:    [normalised_result],
    synthesis: String.t()
  }
  ```
  """
  @spec merge_results([map()]) :: map()
  def merge_results([]) do
    %{
      status: :error,
      succeeded: [],
      failed: [],
      synthesis: "No agent results to merge."
    }
  end

  def merge_results(results) when is_list(results) do
    normalised = Enum.map(results, &normalise_result/1)

    succeeded = Enum.filter(normalised, &(&1.status == :ok))
    failed = Enum.filter(normalised, &(&1.status == :error))

    status =
      cond do
        failed == [] -> :ok
        succeeded == [] -> :error
        true -> :partial
      end

    synthesis = build_synthesis(status, succeeded, failed)

    %{
      status: status,
      succeeded: succeeded,
      failed: failed,
      synthesis: synthesis
    }
  end

  # ── Private section renderers ────────────────────────────────────────────

  defp goal_section(role_label, objective) do
    """
    ## Goal

    **Role:** #{role_label}
    **Objective:** #{objective}

    You decide the approach. Deliver the best result for the objective above.\
    """
  end

  defp context_section(context) do
    has_files = context.files != []
    has_prior = context.prior_results != %{}

    if not has_files and not has_prior do
      nil
    else
      parts = []

      parts =
        if has_files do
          file_list =
            context.files
            |> Enum.map(&"- `#{&1}`")
            |> Enum.join("\n")

          parts ++ ["### Relevant Files\n\n#{file_list}"]
        else
          parts
        end

      parts =
        if has_prior do
          prior_list =
            context.prior_results
            |> Enum.map(fn {agent, output} -> "- **#{agent}**: #{output}" end)
            |> Enum.join("\n")

          parts ++ ["### Prior Agent Results\n\n#{prior_list}"]
        else
          parts
        end

      "## Context\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp tools_section([]), do: nil

  defp tools_section(tools) do
    tool_list = Enum.join(tools, ", ")
    "## Available Tools\n\n#{tool_list}"
  end

  defp constraints_section([]), do: nil

  defp constraints_section(constraints) do
    list =
      constraints
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    "## Constraints\n\n#{list}"
  end

  defp execution_section(nil), do: nil
  defp execution_section(config) when map_size(config) == 0, do: nil

  defp execution_section(config) do
    name = Map.get(config, :name, "unknown")
    tier = config |> Map.get(:tier, :unknown) |> to_string()

    "## Execution\n\nAgent: #{name}\nTier: #{tier}"
  end

  # ── Private merge helpers ────────────────────────────────────────────────

  defp normalise_result(result) do
    %{
      agent: Map.get(result, :agent, "unknown"),
      status: Map.get(result, :status, :error),
      output: Map.get(result, :output, ""),
      metadata: Map.get(result, :metadata, %{})
    }
  end

  defp build_synthesis(:error, _succeeded, failed) do
    failed_lines =
      failed
      |> Enum.map(fn r -> "- #{r.agent} (FAILED): #{r.output}" end)
      |> Enum.join("\n")

    "All agents FAILED:\n\n#{failed_lines}"
  end

  defp build_synthesis(:ok, succeeded, _failed) do
    success_lines =
      succeeded
      |> Enum.map(fn r -> "- #{r.agent}: #{r.output}" end)
      |> Enum.join("\n")

    "Completed:\n\n#{success_lines}"
  end

  defp build_synthesis(:partial, succeeded, failed) do
    success_lines =
      succeeded
      |> Enum.map(fn r -> "- #{r.agent}: #{r.output}" end)
      |> Enum.join("\n")

    failed_lines =
      failed
      |> Enum.map(fn r -> "- #{r.agent} (FAILED): #{r.output}" end)
      |> Enum.join("\n")

    "Completed:\n\n#{success_lines}\n\nFailed:\n\n#{failed_lines}"
  end
end
