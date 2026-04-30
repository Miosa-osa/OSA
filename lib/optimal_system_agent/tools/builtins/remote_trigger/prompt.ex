defmodule OptimalSystemAgent.Tools.Builtins.RemoteTrigger.Prompt do
  @moduledoc """
  Dynamic prompt for `remote_trigger`.

  Mirrors upstream from the the upstream contract,
  adapted to OSA's existing trigger infrastructure in `Agent.Scheduler`.
  """

  alias OptimalSystemAgent.Tools.Builtins.Cron.Constants, as: CronConst

  def render(_opts \\ []) do
    cron_name = safe_ref(CronConst, :tool_name, "cron")

    """
    Manage external triggers — webhooks, signals, and cross-process firings
    that wake scheduled jobs from outside the agent.

    Actions:
    - `create` — register a new trigger (`type` + `payload_schema`)
    - `list`   — list all registered triggers
    - `remove` — delete a trigger by id
    - `fire`   — fire a trigger by id with a payload (executes the linked job)

    Pairs with `#{cron_name}` (which schedules recurring jobs) — a trigger is the
    one-shot/external-event counterpart. Use `create` + a webhook URL to let an
    external system fire your scheduled work; use `fire` to test or manually
    invoke it.

    Trigger payloads are passed through to the job's task body as a map.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
