defmodule OptimalSystemAgent.Tools.Builtins.Cron.Prompt do
  @moduledoc """
  Dynamic prompt for the `cron` tool.

  Consolidates what the upstream agent CLI splits across CronCreateTool/CronListTool/
  into a single
  function, since OSA exposes all cron actions through one action-discriminated
  tool rather than three separate tools.

  Structured around the 4 actions: create / list / delete / trigger.
  """

  alias OptimalSystemAgent.Tools.Builtins.Cron.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    presets = Enum.join(Constants.schedule_presets(), ", ")

    """
    Manages scheduled recurring and one-time tasks via the OSA Scheduler.

    ## Actions

    ### create
    Schedule a new cron job.

    Required:
    - `task`     — Natural-language description of what the agent should do.
    - `schedule` — A standard 5-field cron expression or a named preset.

    Cron expression format: "M H DoM Mon DoW" (all fields in UTC)

    Examples:
    - `"*/30 * * * *"` — every 30 minutes
    - `"0 */6 * * *"`  — every 6 hours
    - `"0 9 * * 1-5"`  — 09:00 UTC on weekdays
    - `"0 0 1 * *"`    — midnight on the 1st of each month

    Named presets (shorthand aliases): #{presets}
    - `"hourly"` → `"0 * * * *"`
    - `"daily"`  → `"0 0 * * *"`
    - `"weekly"` → `"0 0 * * 0"`

    Returns the new job's `id`, `schedule`, and `task`. Keep the `id` — you
    need it to delete or trigger the job later.

    ### list
    List all currently loaded cron jobs with their schedule, task, enabled
    state, and circuit-breaker failure count. No arguments required.

    Returns an empty list when no jobs are configured.

    ### delete
    Remove a cron job permanently by its `job_id`. The job is removed from
    CRONS.json and will not fire again. This operation is irreversible — create
    a new job if you need the same schedule again.

    Required: `job_id` (returned by `create`).

    ### trigger
    Execute a job immediately, bypassing its schedule. Useful for testing a
    newly created job or running an ad-hoc execution without waiting for the
    next cron tick.

    Required: `job_id`.

    ## Notes
    - Jobs with 3 consecutive failures have their circuit breaker opened and
      are skipped on future ticks. Re-enable them by toggling the job or calling
      `reload_crons` after editing CRONS.json at `~/.osa/CRONS.json`.
    - Maximum #{Constants.max_jobs()} concurrent scheduled jobs.
    - The Scheduler GenServer serializes all writes — concurrent calls to
      `create`/`delete` are safe.
    """
  end
end
