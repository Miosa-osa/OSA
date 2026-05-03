defmodule OptimalSystemAgent.Agent.DevelopmentMode do
  @moduledoc """
  Development workflow presets for agent and subagent execution.

  Modes are intentionally small policy maps. Callers can use them to select
  model tier, permission posture, verification expectations, and delegation
  style without spreading mode-specific conditionals through tools.
  """

  @type mode :: :explore | :diagnose | :implement | :review | :test | :ship

  @type policy :: %{
          mode: mode(),
          tier: :specialist | :elite,
          permission_tier: :read_only | :workspace | :subagent,
          background: boolean(),
          required_output: [String.t()],
          verification: [String.t()],
          tool_guidance: String.t()
        }

  @modes [:explore, :diagnose, :implement, :review, :test, :ship]

  @doc "Return all supported development modes."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "Parse user/tool input into a supported mode."
  @spec parse(term()) :: mode() | nil
  def parse(nil), do: nil

  def parse(value) when is_atom(value) and value in @modes, do: value

  def parse(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "explore" -> :explore
      "diagnose" -> :diagnose
      "debug" -> :diagnose
      "implement" -> :implement
      "build" -> :implement
      "review" -> :review
      "test" -> :test
      "verify" -> :test
      "ship" -> :ship
      _ -> nil
    end
  end

  def parse(_), do: nil

  @doc "Return the execution policy for a mode."
  @spec policy(mode() | nil) :: policy()
  def policy(:explore) do
    base(:explore,
      tier: :specialist,
      permission_tier: :read_only,
      background: true,
      verification: ["Report files inspected and evidence; do not modify files."],
      tool_guidance: "Prefer rg/file_glob, focused file_read, and concise synthesis."
    )
  end

  def policy(:diagnose) do
    base(:diagnose,
      tier: :elite,
      permission_tier: :workspace,
      background: false,
      verification: ["Reproduce first, identify a failing signal, verify the fix."],
      tool_guidance: "Use tests or logs as the feedback loop before changing code."
    )
  end

  def policy(:implement) do
    base(:implement,
      tier: :elite,
      permission_tier: :workspace,
      background: false,
      verification: ["Run focused tests for touched modules.", "Report any tests not run."],
      tool_guidance: "Read before write, keep edits scoped, and preserve user changes."
    )
  end

  def policy(:review) do
    base(:review,
      tier: :elite,
      permission_tier: :read_only,
      background: true,
      verification: ["List findings by severity with file references."],
      tool_guidance: "Prioritize bugs, regressions, and missing tests."
    )
  end

  def policy(:test) do
    base(:test,
      tier: :specialist,
      permission_tier: :workspace,
      background: false,
      verification: ["Run the target tests and summarize failures with next actions."],
      tool_guidance: "Prefer focused deterministic test commands before broad suites."
    )
  end

  def policy(:ship) do
    base(:ship,
      tier: :elite,
      permission_tier: :workspace,
      background: false,
      verification: ["Run final integration checks.", "Confirm residual risks."],
      tool_guidance: "Check git diff, run relevant suites, and prepare a concise handoff."
    )
  end

  def policy(_), do: policy(:implement)

  @doc "Append mode instructions to a delegated task prompt."
  @spec annotate_task(String.t(), mode() | nil) :: String.t()
  def annotate_task(task, nil), do: task

  def annotate_task(task, mode) do
    policy = policy(mode)

    """
    #{task}

    ## Development Mode
    Mode: #{policy.mode}
    Tool guidance: #{policy.tool_guidance}
    Required output: #{Enum.join(policy.required_output, ", ")}
    Verification: #{Enum.join(policy.verification, " ")}
    """
    |> String.trim()
  end

  defp base(mode, opts) do
    %{
      mode: mode,
      tier: Keyword.fetch!(opts, :tier),
      permission_tier: Keyword.fetch!(opts, :permission_tier),
      background: Keyword.fetch!(opts, :background),
      required_output: [
        "summary",
        "files inspected",
        "files changed",
        "findings",
        "commands run",
        "tests run",
        "blockers",
        "assumptions",
        "next actions",
        "confidence"
      ],
      verification: Keyword.fetch!(opts, :verification),
      tool_guidance: Keyword.fetch!(opts, :tool_guidance)
    }
  end
end
