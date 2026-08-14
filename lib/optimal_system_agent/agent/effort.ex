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
      max_response_tokens: 32_768,
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
      max_response_tokens: 32_768,
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
    # Settings cascade: session → local → project → user → app default
    (OptimalSystemAgent.Settings.get(:effort_level) ||
       Application.get_env(:optimal_system_agent, :effort_level, :medium))
    |> normalize()
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
