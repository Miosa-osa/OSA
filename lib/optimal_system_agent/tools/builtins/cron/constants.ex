defmodule OptimalSystemAgent.Tools.Builtins.Cron.Constants do
  @moduledoc """
  Exported constants for the `cron` tool.

  Mirrors the role of upstream constant exports
  (CRON_CREATE_TOOL_NAME, CRON_LIST_TOOL_NAME, CRON_DELETE_TOOL_NAME) but
  condensed to one name since OSA exposes all actions through a single
  action-discriminated tool.
  """

  @tool_name "cron"
  def tool_name, do: @tool_name

  @actions [:create, :list, :delete, :trigger]
  def actions, do: @actions

  # Action atoms as strings — used in parameter enum and handler dispatch.
  @action_strings Enum.map(@actions, &Atom.to_string/1)
  def action_strings, do: @action_strings

  # Schedule presets accepted by the Scheduler in addition to raw cron expressions.
  @schedule_presets ["hourly", "daily", "weekly"]
  def schedule_presets, do: @schedule_presets

  # Cap matching the the upstream contract (CronCreateTool.ts:25).
  @max_jobs 50
  def max_jobs, do: @max_jobs
end
