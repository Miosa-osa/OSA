defmodule OptimalSystemAgent.Agent.Effort do
  @moduledoc """
  Effort level system — controls thinking depth, iteration limits, and temperature.

  Levels:
    - `:fast`   — Fast, concise responses. Minimal thinking.
    - `:medium` — Balanced depth and speed. Default.
    - `:high`   — Deep reasoning, thorough analysis.
    - `:xhigh`  — Maximum thinking, extended reasoning enabled.
    - `:ultra`  — Maximum reasoning + dynamic workflows (OSA's `ultracode`).

  Ordering (lowest→highest): `:fast < :medium < :high < :xhigh < :ultra`. Use
  `rank/1`, `at_least?/2`, and `current_at_least?/1` for ordinal comparisons —
  never rely on map/list position.

  Back-compat: the ladder was renamed from `:low/:medium/:high/:max` — legacy
  `:low`/`:max` (and their string forms, plus `"off"`) are accepted everywhere
  and mapped via `normalize/1` (`:low → :fast`, `:max → :xhigh`, `"off" → :fast`)
  so persisted settings and old callers keep working.
  """

  ## The `max_response_tokens` column — why it is what it is

  # This column was flat at 32_768 across all five tiers, and a prior audit read
  # that as deliberate "since the four sibling columns do vary". The history
  # says otherwise **[measured]**:
  #
  #   * `84eced65` (2026-04-30) introduced the ladder with a VARYING column:
  #     `low: 2_048 · medium: 8_192 · high: 16_384 · max: 32_768`.
  #   * `50761171` (2026-04-30, same day) raised `low`/`medium`/`high` to
  #     `32_768` — the value `max` already had — in a 40-line commit message
  #     about skills, checkpoints, skins and personas that does not mention
  #     output tokens at all. The other three columns were retuned individually
  #     in that same hunk; this one was levelled.
  #   * `ee3b77c0` (2026-07-21) added `ultra` by copying the row.
  #
  # So the flat value is the residue of raising the floor to meet the old
  # ceiling, not a decision that 32,768 is the right ceiling. And 32,768 was
  # never measured against any model: `Providers.ModelLimits` puts `glm-5.2` —
  # the model of the reference benchmark run — at **128,000** output tokens.
  # OSA was clamping it to a quarter of what it can produce.
  #
  # It is still not raised to 128k, and deliberately. Output tokens are the
  # expensive half of a request, and a bigger ceiling on a runaway generation
  # is real money: the run that exposed this produced a single 350,880-character
  # thinking block. The ceiling is not the defect — a ceiling that silently
  # converts a long answer into a fragment presented as complete is. That is
  # fixed where it belongs, in `ReactLoop`, which now detects every provider's
  # truncation stop reason, continues the generation, and marks anything it
  # cannot finish.
  #
  # What changes here is only the top of the ladder, where the operator has
  # explicitly asked for maximum depth and is already paying for 32k–64k
  # thinking budgets. No tier is lowered, so no existing configuration
  # regresses; the ladder is monotone non-decreasing again.
  @levels %{
    fast: %{
      thinking_budget: 0,
      # Raised from 30. CC has no fixed per-turn iteration ceiling by default; the
      # cap is a backstop, not a routine limit. Explicit :max_iterations wins.
      max_iterations: 50,
      max_response_tokens: 32_768,
      tool_budget: 18,
      temperature: 0.2,
      label: "fast",
      description: "Fast path: full capability with speculative prefetch and lean routing"
    },
    medium: %{
      thinking_budget: 5_000,
      # Raised 30 → 100 (default effort). A 30-round cap killed legitimate
      # multi-file tasks mid-work; CC keeps going until the model stops emitting
      # tool_use, bounded by context + budget. This keeps the canned stop as a
      # genuine backstop rather than a routine cap.
      max_iterations: 100,
      max_response_tokens: 32_768,
      tool_budget: 24,
      temperature: 0.7,
      label: "medium",
      description: "Balanced depth and speed"
    },
    high: %{
      thinking_budget: 10_000,
      # Raised 50 → 150 to match the higher default ceilings; still a backstop.
      max_iterations: 150,
      max_response_tokens: 32_768,
      tool_budget: 32,
      temperature: 0.7,
      label: "high",
      description: "Deep reasoning, thorough analysis"
    },
    xhigh: %{
      thinking_budget: 32_000,
      # Raised from 100 → 2000 so effort-driven autonomous callers (the
      # "autonomous" preset uses :xhigh) aren't capped mid-run. Explicit
      # `:max_iterations` config still wins over this ceiling.
      max_iterations: 2000,
      # 32_768 → 48_000. See the note above the ladder: the flat column was an
      # artefact of `50761171`, not a decision. `:xhigh` runs a 32k thinking
      # budget, so a 32k OUTPUT ceiling on top of it is the tier most likely to
      # be cut off mid-answer.
      max_response_tokens: 48_000,
      tool_budget: 40,
      temperature: 0.8,
      label: "xhigh",
      description: "Maximum thinking, extended reasoning"
    },
    ultra: %{
      thinking_budget: 64_000,
      # Above :xhigh's 2000 — ultra drives dynamic-workflow orchestration and must
      # not be capped mid-run. Explicit `:max_iterations` config still wins.
      max_iterations: 4000,
      # 32_768 → 64_000, matching the ceiling `ReactLoop`'s truncation recovery
      # already doubles up to. `:ultra` is the tier that drives dynamic-workflow
      # orchestration; capping its single answer at the same size `:fast` gets
      # was never a decision anyone made.
      max_response_tokens: 64_000,
      tool_budget: 48,
      temperature: 0.9,
      label: "Ultra",
      description: "Maximum reasoning + dynamic workflows"
    }
  }

  # Ordinal rank per level (low→high). Drives `at_least?/2` gates such as the
  # dynamic-workflow (`ultra`-only) gate — never compare by map/list position.
  @ranks %{fast: 0, medium: 1, high: 2, xhigh: 3, ultra: 4}

  @valid_levels [:fast, :medium, :high, :xhigh, :ultra]

  @doc """
  Normalize a level to a current-ladder atom.

  Maps legacy names (`:low → :fast`, `:max → :xhigh`, and the string forms), the
  wire value `"off" → :fast` (lowest / disabled), and coerces known level strings
  to atoms. Unknown values pass through unchanged.
  """
  def normalize(:low), do: :fast
  def normalize(:max), do: :xhigh
  def normalize(level) when is_atom(level), do: level

  def normalize(level) when is_binary(level) do
    case level |> String.trim() |> String.downcase() do
      "low" -> :fast
      "max" -> :xhigh
      "off" -> :fast
      s when s in ~w(fast medium high xhigh ultra) -> String.to_atom(s)
      _ -> level
    end
  end

  def normalize(other), do: other

  @doc "Get config for an effort level (legacy names normalized)."
  def get(level), do: Map.get(@levels, normalize(level), @levels[:medium])

  @doc "List all available levels, lowest→highest."
  def levels, do: @valid_levels

  @doc "Ordinal rank of a level (higher = more effort). Unknown levels rank -1."
  def rank(level) when is_atom(level), do: Map.get(@ranks, normalize(level), -1)
  def rank(level) when is_binary(level), do: Map.get(@ranks, normalize(level), -1)
  def rank(_), do: -1

  @doc "True when `level` is at least `floor` on the effort ladder."
  def at_least?(level, floor) do
    rank(level) >= rank(floor)
  end

  @doc "True when the current global effort is at least `floor`."
  def current_at_least?(floor), do: at_least?(current(), floor)

  @doc "Get the current global effort level (legacy values normalized)."
  def current do
    # A bounded recovery may raise effort for this loop process only. It must
    # never mutate the global/session setting because other live sessions can
    # be issuing requests concurrently.
    (Process.get(:osa_effort_override) ||
       OptimalSystemAgent.Settings.get(:effort_level) ||
       Application.get_env(:optimal_system_agent, :effort_level, :medium))
    |> normalize()
  end

  @doc false
  def with_process_override(level, fun) when is_function(fun, 0) do
    previous = Process.get(:osa_effort_override)
    Process.put(:osa_effort_override, normalize(level))

    try do
      fun.()
    after
      if previous == nil,
        do: Process.delete(:osa_effort_override),
        else: Process.put(:osa_effort_override, previous)
    end
  end

  @doc """
  Set the global effort level.

  Accepts current ladder atoms plus legacy names (`:low`/`:max`, string forms,
  `"off"`) — the value is normalized before validation and only the canonical
  atom is persisted.
  """
  def set(level) do
    case normalize(level) do
      norm when norm in @valid_levels ->
        OptimalSystemAgent.Settings.set_session(:effort_level, norm)
        Application.put_env(:optimal_system_agent, :effort_level, norm)
        :ok

      _ ->
        {:error, :invalid_level}
    end
  end

  @doc "Get the current thinking budget based on effort level."
  def thinking_budget, do: get(current()).thinking_budget

  @doc "Get the current max iterations based on effort level."
  def max_iterations, do: get(current()).max_iterations

  @doc "Get the current max response tokens based on effort level."
  def max_response_tokens, do: get(current()).max_response_tokens

  @doc "Get the current tool budget based on effort level."
  def tool_budget, do: get(current()).tool_budget

  @doc """
  Temperature for the current effort level.

  > #### Not on any request path {: .warning}
  >
  > **Nothing in `lib/` calls this.** `Agent.Loop.LLMClient.temperature/0` reads
  > `:temperature` from app env instead, so the `:temperature` column of the
  > ladder above reaches no provider. That is mostly correct by accident and
  > should not be "fixed" by wiring it up: Anthropic's Claude 5 family and
  > Opus/Sonnet 4.6+ **reject** `temperature`, `top_p`, and `top_k` outright,
  > and OpenAI's reasoning models 400 on an explicit `temperature` too. The
  > providers deliberately never send it.
  >
  > It is kept because non-reasoning models on Ollama and the OpenAI-compatible
  > path still take a temperature, and because callers outside the tree may read
  > it. Treat it as advisory, not as a description of what goes on the wire.
  """
  def temperature, do: get(current()).temperature

  @doc "Check if fast mode is active (effort == :fast)."
  def fast_mode?, do: current() == :fast

  @doc "Toggle fast mode on/off (fast ↔ medium)."
  def toggle_fast do
    if fast_mode?(), do: set(:medium), else: set(:fast)
  end
end
