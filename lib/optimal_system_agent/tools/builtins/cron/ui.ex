defmodule OptimalSystemAgent.Tools.Builtins.Cron.UI do
  @moduledoc """
  Render maps for the Rust TUI cron panel.

  Mirrors the role of upstream but on the Elixir
  side. Each `render/3` returns a structured payload that the TUI consumes via
  PubSub. The `kind` field maps to a TUI component — the cron panel renderer
  is not yet implemented in Rust but the payload shape is forward-locked here
  so the Rust side can be added without touching this module.

  ## Forward-looking payload fields (for the Rust cron panel)

  `:tool_result` for `list` emits `%{kind: "cron_list", jobs: [...]}` where
  each job map includes:
    - `id`          — opaque job ID
    - `schedule`    — raw cron expression or preset string
    - `task`        — natural-language task description
    - `enabled?`    — boolean (derived from the `"enabled"` string/bool field)
    - `next_run_at` — placeholder nil until the Scheduler exposes next-fire
    - `failure_count` — consecutive failure count (circuit breaker state)
    - `circuit_open`  — boolean, true = skipped until re-enabled

  `:tool_result` for `create` emits `%{kind: "cron_created", job: %{...}}`.
  `:tool_result` for `delete` emits `%{kind: "cron_deleted", job_id: id}`.
  `:tool_result` for `trigger` emits `%{kind: "cron_triggered", job_id: id}`.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  # ── tool_use (before execution) ───────────────────────────────────────

  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "cron_use",
      action: action,
      task: input["task"],
      schedule: input["schedule"],
      job_id: input["job_id"]
    }
  end

  # ── tool_result: list ─────────────────────────────────────────────────

  def render(:tool_result, jobs, _opts) when is_list(jobs) do
    %{
      kind: "cron_list",
      jobs: Enum.map(jobs, &normalize_job/1)
    }
  end

  # ── tool_result: create ───────────────────────────────────────────────

  def render(:tool_result, %{"id" => _} = job, _opts) do
    %{kind: "cron_created", job: normalize_job(job)}
  end

  # ── tool_result: delete ───────────────────────────────────────────────

  def render(:tool_result, %{"deleted" => true, "job_id" => job_id}, _opts) do
    %{kind: "cron_deleted", job_id: job_id}
  end

  # ── tool_result: trigger ──────────────────────────────────────────────

  def render(:tool_result, %{"triggered" => true, "job_id" => job_id} = result, _opts) do
    %{
      kind: "cron_triggered",
      job_id: job_id,
      result: result["result"]
    }
  end

  # ── rejected ──────────────────────────────────────────────────────────

  def render(:rejected, input, _opts) do
    %{
      kind: "cron_rejected",
      action: (is_map(input) && input["action"]) || nil
    }
  end

  # ── error ─────────────────────────────────────────────────────────────

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "cron_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil

  # ── Private ───────────────────────────────────────────────────────────

  # Normalizes a raw Scheduler job map (string-keyed) to the forward-locked
  # payload shape expected by the future Rust cron panel component.
  defp normalize_job(job) when is_map(job) do
    %{
      id: job["id"],
      schedule: job["schedule"],
      task: job["task"] || job["name"],
      # Scheduler stores "enabled" as boolean or string; normalize to bool.
      enabled?: normalize_bool(job["enabled"]),
      # next_run_at: nil until Scheduler.next_run_for/1 is exposed.
      next_run_at: nil,
      failure_count: job["failure_count"] || 0,
      circuit_open: normalize_bool(job["circuit_open"])
    }
  end

  defp normalize_bool(true), do: true
  defp normalize_bool("true"), do: true
  defp normalize_bool(false), do: false
  defp normalize_bool("false"), do: false
  defp normalize_bool(nil), do: false
  defp normalize_bool(_), do: false
end
