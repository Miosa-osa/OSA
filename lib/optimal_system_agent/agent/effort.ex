defmodule OptimalSystemAgent.Agent.Effort do
  @moduledoc """
  Effort level system — controls thinking depth, iteration limits, and temperature.

  Levels:
    - `:low`    — Fast, concise responses. Minimal thinking.
    - `:medium` — Balanced depth and speed. Default.
    - `:high`   — Deep reasoning, thorough analysis.
    - `:max`    — Maximum thinking, extended reasoning enabled.
    - `:ultra`  — Maximum reasoning + dynamic workflows (OSA's `ultracode`).

  Ordering (lowest→highest): `:low < :medium < :high < :max < :ultra`. Use
  `rank/1`, `at_least?/2`, and `current_at_least?/1` for ordinal comparisons —
  never rely on map/list position.
  """

  @levels %{
    low: %{
      thinking_budget: 0,
      # Raised from 30. CC has no fixed per-turn iteration ceiling by default; the
      # cap is a backstop, not a routine limit. Explicit :max_iterations wins.
      max_iterations: 50,
      max_response_tokens: 32_768,
      tool_budget: 18,
      temperature: 0.2,
      label: "low",
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
    max: %{
      thinking_budget: 32_000,
      # Raised from 100 → 2000 so effort-driven autonomous callers (the
      # "autonomous" preset uses :max) aren't capped mid-run. Explicit
      # `:max_iterations` config still wins over this ceiling.
      max_iterations: 2000,
      max_response_tokens: 32_768,
      tool_budget: 40,
      temperature: 0.8,
      label: "max",
      description: "Maximum thinking, extended reasoning"
    },
    ultra: %{
      thinking_budget: 64_000,
      # Above :max's 2000 — ultra drives dynamic-workflow orchestration and must
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
  @ranks %{low: 0, medium: 1, high: 2, max: 3, ultra: 4}

  @doc "Get config for an effort level."
  def get(level) when is_atom(level), do: Map.get(@levels, level, @levels[:medium])
  def get(_), do: @levels[:medium]

  @doc "List all available levels, lowest→highest."
  def levels, do: [:low, :medium, :high, :max, :ultra]

  @doc "Ordinal rank of a level (higher = more effort). Unknown levels rank -1."
  def rank(level) when is_atom(level), do: Map.get(@ranks, level, -1)
  def rank(_), do: -1

  @doc "True when `level` is at least `floor` on the effort ladder."
  def at_least?(level, floor) when is_atom(level) and is_atom(floor) do
    rank(level) >= rank(floor)
  end

  @doc "True when the current global effort is at least `floor`."
  def current_at_least?(floor) when is_atom(floor), do: at_least?(current(), floor)

  @doc "Get the current global effort level."
  def current do
    # Settings cascade: session → local → project → user → app default
    OptimalSystemAgent.Settings.get(:effort_level) ||
      Application.get_env(:optimal_system_agent, :effort_level, :medium)
  end

  @doc "Set the global effort level."
  def set(level) when level in [:low, :medium, :high, :max, :ultra] do
    OptimalSystemAgent.Settings.set_session(:effort_level, level)
    Application.put_env(:optimal_system_agent, :effort_level, level)
    :ok
  end

  def set(_), do: {:error, :invalid_level}

  @doc "Get the current thinking budget based on effort level."
  def thinking_budget, do: get(current()).thinking_budget

  @doc "Get the current max iterations based on effort level."
  def max_iterations, do: get(current()).max_iterations

  @doc "Get the current max response tokens based on effort level."
  def max_response_tokens, do: get(current()).max_response_tokens

  @doc "Get the current tool budget based on effort level."
  def tool_budget, do: get(current()).tool_budget

  @doc "Get the current temperature based on effort level."
  def temperature, do: get(current()).temperature

  @doc "Check if fast mode is active (effort == :low)."
  def fast_mode?, do: current() == :low

  @doc "Toggle fast mode on/off."
  def toggle_fast do
    if fast_mode?(), do: set(:medium), else: set(:low)
  end
end
