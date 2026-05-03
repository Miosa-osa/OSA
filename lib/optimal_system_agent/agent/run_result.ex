defmodule OptimalSystemAgent.Agent.RunResult do
  @moduledoc """
  Structured contract for subagent run results.

  The orchestrator still returns a legacy text summary for model compatibility,
  but every completed run is stored with this shape so parent agents, tools,
  the TUI, and later verification gates can reason over the same data.
  """

  @type status :: :completed | :failed | :cancelled | :running

  @type t :: %{
          agent_id: String.t(),
          parent_session_id: String.t(),
          role: String.t(),
          status: status(),
          summary: String.t(),
          files_inspected: [String.t()],
          files_changed: [String.t()],
          findings: [String.t()],
          commands_run: [String.t()],
          tests_run: [String.t()],
          blockers: [String.t()],
          errors: [String.t()],
          assumptions: [String.t()],
          next_actions: [String.t()],
          verification: map(),
          confidence: non_neg_integer(),
          tool_count: non_neg_integer(),
          tokens_used: non_neg_integer(),
          duration_ms: non_neg_integer(),
          transcript_path: String.t(),
          worktree: map() | nil
        }

  @required ~w(agent_id parent_session_id role status)a

  @doc "Normalize arbitrary orchestrator attrs into the stable run-result shape."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    missing =
      @required
      |> Enum.reject(&Map.has_key?(attrs, &1))

    if missing != [] do
      raise ArgumentError, "missing run result fields: #{Enum.join(missing, ", ")}"
    end

    %{
      agent_id: string!(attrs.agent_id),
      parent_session_id: string!(attrs.parent_session_id),
      role: string!(attrs.role),
      status: normalize_status(attrs.status),
      summary: string(Map.get(attrs, :summary, "")),
      files_inspected: string_list(Map.get(attrs, :files_inspected, [])),
      files_changed: string_list(Map.get(attrs, :files_changed, [])),
      findings: string_list(Map.get(attrs, :findings, [])),
      commands_run: string_list(Map.get(attrs, :commands_run, [])),
      tests_run: string_list(Map.get(attrs, :tests_run, [])),
      blockers: string_list(Map.get(attrs, :blockers, [])),
      errors: string_list(Map.get(attrs, :errors, [])),
      assumptions: string_list(Map.get(attrs, :assumptions, [])),
      next_actions: string_list(Map.get(attrs, :next_actions, [])),
      verification: normalize_verification(Map.get(attrs, :verification, %{})),
      confidence: clamp_int(Map.get(attrs, :confidence, 0), 0, 100),
      tool_count: non_neg_int(Map.get(attrs, :tool_count, 0)),
      tokens_used: non_neg_int(Map.get(attrs, :tokens_used, 0)),
      duration_ms: non_neg_int(Map.get(attrs, :duration_ms, 0)),
      transcript_path: string(Map.get(attrs, :transcript_path, "unavailable")),
      worktree: Map.get(attrs, :worktree)
    }
  end

  @doc "Build a failed result without losing available execution metadata."
  @spec failure(map(), term()) :: t()
  def failure(attrs, reason) do
    attrs
    |> Map.put(:status, :failed)
    |> Map.put_new(
      :summary,
      "Subagent #{Map.get(attrs, :role, "agent")} failed: #{inspect(reason)}"
    )
    |> Map.update(:errors, [inspect(reason)], &[inspect(reason) | string_list(&1)])
    |> new()
  end

  defp normalize_status(status) when status in [:completed, :failed, :cancelled, :running],
    do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "completed" -> :completed
      "failed" -> :failed
      "cancelled" -> :cancelled
      "running" -> :running
      _ -> :failed
    end
  end

  defp normalize_status(_), do: :failed

  defp normalize_verification(%{} = verification), do: verification
  defp normalize_verification(_), do: %{}

  defp string!(value) do
    value
    |> string()
    |> case do
      "" -> raise ArgumentError, "run result string field cannot be blank"
      value -> value
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(value), do: to_string(value)

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp string_list(nil), do: []
  defp string_list(value), do: [string(value)]

  defp non_neg_int(value), do: clamp_int(value, 0, 9_223_372_036_854_775_807)

  defp clamp_int(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp clamp_int(value, min, max) when is_float(value) do
    value
    |> round()
    |> clamp_int(min, max)
  end

  defp clamp_int(_value, min, _max), do: min
end
