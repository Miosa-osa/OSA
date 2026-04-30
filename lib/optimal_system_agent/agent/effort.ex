defmodule OptimalSystemAgent.Agent.Effort do
  @moduledoc """
  Effort level system — controls thinking depth, iteration limits, and temperature.

  Levels:
    - `:low`    — Fast, concise responses. Minimal thinking.
    - `:medium` — Balanced depth and speed. Default.
    - `:high`   — Deep reasoning, thorough analysis.
    - `:max`    — Maximum thinking, extended reasoning enabled.
  """

  @levels %{
    low: %{
      thinking_budget: 0,
      max_iterations: 30,
      max_response_tokens: 32_768,
      tool_budget: 18,
      temperature: 0.2,
      label: "low",
      description: "Fast path: full capability with speculative prefetch and lean routing"
    },
    medium: %{
      thinking_budget: 5_000,
      max_iterations: 30,
      max_response_tokens: 32_768,
      tool_budget: 24,
      temperature: 0.7,
      label: "medium",
      description: "Balanced depth and speed"
    },
    high: %{
      thinking_budget: 10_000,
      max_iterations: 50,
      max_response_tokens: 32_768,
      tool_budget: 32,
      temperature: 0.7,
      label: "high",
      description: "Deep reasoning, thorough analysis"
    },
    max: %{
      thinking_budget: 32_000,
      max_iterations: 100,
      max_response_tokens: 32_768,
      tool_budget: 40,
      temperature: 0.8,
      label: "max",
      description: "Maximum thinking, extended reasoning"
    }
  }

  @doc "Get config for an effort level."
  def get(level) when is_atom(level), do: Map.get(@levels, level, @levels[:medium])
  def get(_), do: @levels[:medium]

  @doc "List all available levels."
  def levels, do: [:low, :medium, :high, :max]

  @doc "Get the current global effort level."
  def current do
    # Settings cascade: session → local → project → user → app default
    OptimalSystemAgent.Settings.get(:effort_level) ||
      Application.get_env(:optimal_system_agent, :effort_level, :medium)
  end

  @doc "Set the global effort level."
  def set(level) when level in [:low, :medium, :high, :max] do
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
