defmodule OptimalSystemAgent.Tools.Builtins.SubscribePr.Constants do
  @moduledoc "Exported constants for the subscribe_pr tool."

  @tool_name "subscribe_pr"
  def tool_name, do: @tool_name

  # GitHub PR URL pattern for validation
  @github_pr_pattern ~r|^https://github\.com/[^/]+/[^/]+/pull/\d+$|
  def github_pr_pattern, do: @github_pr_pattern

  # Valid poll intervals (minutes)
  @valid_poll_intervals [1, 5, 10, 15, 30, 60]
  def valid_poll_intervals, do: @valid_poll_intervals

  @default_poll_interval_minutes 5
  def default_poll_interval_minutes, do: @default_poll_interval_minutes

  # Valid events to subscribe to
  @valid_events ~w(merged closed review_requested changes_requested approved)
  def valid_events, do: @valid_events

  @default_events ~w(merged closed)
  def default_events, do: @default_events

  # Max number of active PR subscriptions
  @max_subscriptions 10
  def max_subscriptions, do: @max_subscriptions
end
