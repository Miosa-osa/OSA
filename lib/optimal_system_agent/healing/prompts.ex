defmodule OptimalSystemAgent.Healing.Prompts do
  @moduledoc """
  LLM prompts for ephemeral healing agents.

  Prompts are structured to maximise signal-to-noise: each prompt gives the
  agent a single, unambiguous task with a machine-parseable output contract.
  """

  @doc """
  Build the diagnostic prompt for an ephemeral diagnostician agent.

  The diagnostician receives the error context and must return a structured
  diagnosis identifying root cause, confidence, and recommended remediation
  strategy.

  `context` is expected to contain:
  - `:agent_id` — the session that failed
  - `:error` — the raw error (string or inspect)
  - `:category` — classified error category atom
  - `:severity` — severity atom
  - `:retryable` — boolean
  - `:messages` — last N messages from the agent conversation (optional)
  - `:working_dir` — working directory of the failed agent (optional)
  - `:tool_history` — list of recent tool calls (optional)
  - `:attempt_count` — how many times healing has been attempted
  """
  @spec diagnostic_prompt(map()) :: String.t()
  def diagnostic_prompt(context) do
    agent_id = Map.get(context, :agent_id, "unknown")
    error = Map.get(context, :error, "unknown error")
    category = Map.get(context, :category, :unknown)
    severity = Map.get(context, :severity, :medium)
    retryable = Map.get(context, :retryable, true)
    attempt_count = Map.get(context, :attempt_count, 0)
    working_dir = Map.get(context, :working_dir, "unknown")
    tool_history = Map.get(context, :tool_history, [])
    messages = Map.get(context, :messages, [])

    tool_history_text =
      if Enum.empty?(tool_history) do
        "  (no tool calls recorded)"
      else
        tool_history
        |> Enum.take(-10)
        |> Enum.map_join("\n", fn t ->
          "  - #{Map.get(t, :tool, "unknown_tool")}: #{inspect(Map.get(t, :result, :no_result))}"
        end)
      end

    last_messages_text =
      if Enum.empty?(messages) do
        "  (no recent messages)"
      else
        messages
        |> Enum.take(-5)
        |> Enum.map_join("\n", fn m ->
          role = Map.get(m, :role, "unknown")
          content = m |> Map.get(:content, "") |> truncate(500)
          "  [#{role}] #{content}"
        end)
      end

    """
    You are a diagnostic specialist for an AI agent self-healing system.

    An agent session has failed and requires analysis. Your task is to identify
    the root cause precisely and recommend a concrete remediation strategy.

    ## Failed Session

    - Agent ID: #{agent_id}
    - Working Directory: #{working_dir}
    - Error Category: #{category}
    - Severity: #{severity}
    - Retryable: #{retryable}
    - Healing Attempt: #{attempt_count + 1}

    ## Error Details

    #{format_error(error)}

    ## Recent Tool History (last 10 calls)

    #{tool_history_text}

    ## Recent Conversation (last 5 messages)

    #{last_messages_text}

    ## Your Task

    Diagnose the root cause of this failure. Be specific and concise.

    Respond in this exact JSON format (no markdown, no preamble):

    {
      "root_cause": "<one sentence describing the exact root cause>",
      "confidence": <float 0.0-1.0>,
      "category_confirmed": "<confirmed or corrected category: tool_failure|llm_error|timeout|budget_exceeded|permission_denied|file_conflict|assertion_failure|unknown>",
      "remediation_strategy": "<one of: retry|fix_prompt|fix_tool_call|fix_file|change_approach|escalate>",
      "remediation_details": "<specific instructions for the fixer agent — what exactly to change>",
      "files_to_inspect": ["<list of file paths that may be relevant>"],
      "preventable": <true|false>
    }
    """
  end

  @doc """
  Build the fix prompt for an ephemeral fixer agent.

  The fixer receives the diagnosis and original error context, then applies
  the recommended remediation.

  `diagnosis` is the parsed JSON map from the diagnostician.
  `context` is the same map passed to `diagnostic_prompt/1`.
  """
  @spec fix_prompt(map(), map()) :: String.t()
  def fix_prompt(diagnosis, context) do
    agent_id = Map.get(context, :agent_id, "unknown")
    working_dir = Map.get(context, :working_dir, "unknown")

    root_cause = Map.get(diagnosis, "root_cause", Map.get(diagnosis, :root_cause, "unknown"))
    strategy = Map.get(diagnosis, "remediation_strategy", Map.get(diagnosis, :remediation_strategy, "retry"))
    details = Map.get(diagnosis, "remediation_details", Map.get(diagnosis, :remediation_details, ""))
    confidence = Map.get(diagnosis, "confidence", Map.get(diagnosis, :confidence, 0.0))
    files_to_inspect = Map.get(diagnosis, "files_to_inspect", Map.get(diagnosis, :files_to_inspect, []))

    files_text =
      case files_to_inspect do
        [] -> "  (none identified)"
        files -> Enum.map_join(files, "\n", fn f -> "  - #{f}" end)
      end

    """
    You are a repair specialist for an AI agent self-healing system.

    A diagnostician has identified the root cause of a failed agent session.
    Your task is to apply the remediation and confirm the fix.

    ## Context

    - Agent ID: #{agent_id}
    - Working Directory: #{working_dir}

    ## Diagnosis

    - Root Cause: #{root_cause}
    - Diagnostician Confidence: #{confidence}
    - Remediation Strategy: #{strategy}
    - Remediation Details: #{details}

    ## Files to Inspect

    #{files_text}

    ## Your Task

    Apply the remediation described above. Follow these rules:

    1. Make the minimum change necessary to fix the root cause.
    2. Do not refactor unrelated code.
    3. If the strategy is `retry`, confirm the conditions for retry are met.
    4. If the strategy is `fix_file`, read the file first, then write the corrected version.
    5. If the strategy is `fix_prompt` or `fix_tool_call`, describe what was wrong and the corrected form.
    6. If the strategy is `escalate`, do not attempt a fix — describe why escalation is needed.
    7. If you cannot apply the fix, explain why precisely.

    After completing (or determining you cannot complete) the fix, respond in this exact JSON format
    (no markdown, no preamble):

    {
      "fix_applied": <true|false>,
      "description": "<one sentence summary of what was done or why it was not possible>",
      "file_changes": [
        {"path": "<file path>", "action": "<read|write|delete>", "summary": "<what changed>"}
      ],
      "retry_viable": <true|false>,
      "escalation_reason": "<only if fix_applied is false — why escalation is needed>"
    }
    """
  end

  # -- Private helpers --

  defp format_error(error) when is_binary(error) do
    truncate(error, 2000)
  end

  defp format_error(error) do
    error |> inspect(limit: 50, printable_limit: 500) |> truncate(2000)
  end

  defp truncate(string, max_len) when is_binary(string) and byte_size(string) > max_len do
    String.slice(string, 0, max_len) <> "… [truncated]"
  end

  defp truncate(string, _max_len), do: string
end
