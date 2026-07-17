defmodule OptimalSystemAgent.Tools.Builtins.SubscribePr.Handler do
  @moduledoc """
  Validation, permission, and execution for `subscribe_pr`.

  Registers a named cron job via `Agent.Scheduler.add_job/1` that polls
  the GitHub PR API on the requested interval. When a watched event occurs
  the cron job emits an agent task that processes the reaction.

  The job ID is derived from the PR URL so re-calling with the same URL
  replaces (idempotent upsert) the existing subscription.
  """

  alias OptimalSystemAgent.Tools.Builtins.SubscribePr.Constants
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Events.Bus
  require Logger

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"pr_url" => url} = input, _ctx) when is_binary(url) do
    events = Map.get(input, "events", Constants.default_events())
    interval = Map.get(input, "poll_interval_minutes", Constants.default_poll_interval_minutes())

    invalid_events =
      if is_list(events), do: Enum.reject(events, &(&1 in Constants.valid_events())), else: []

    cond do
      not Regex.match?(Constants.github_pr_pattern(), url) ->
        {:error, "pr_url must be a full GitHub PR URL: https://github.com/owner/repo/pull/N",
         -32_602}

      not is_list(events) or events == [] ->
        {:error, "events must be a non-empty list", -32_602}

      invalid_events != [] ->
        {:error,
         "Invalid events: #{Enum.join(invalid_events, ", ")}. " <>
           "Valid: #{Enum.join(Constants.valid_events(), ", ")}", -32_602}

      not (is_integer(interval) and interval in Constants.valid_poll_intervals()) ->
        {:error,
         "poll_interval_minutes must be one of: #{Enum.join(Enum.map(Constants.valid_poll_intervals(), &to_string/1), ", ")}",
         -32_602}

      true ->
        normalised =
          input
          |> Map.put_new("events", Constants.default_events())
          |> Map.put_new("poll_interval_minutes", Constants.default_poll_interval_minutes())

        {:ok, normalised}
    end
  end

  def validate(%{"pr_url" => _}, _ctx),
    do: {:error, "pr_url must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: pr_url", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"pr_url" => url} = input, _ctx) do
    # Allow only github.com — block SSRF to internal URLs
    case URI.parse(url) do
      %URI{host: "github.com"} ->
        {:allow, input}

      _ ->
        {:deny, "Access denied: subscribe_pr only supports github.com PR URLs"}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{"pr_url" => url} = input, ctx) do
    events = Map.get(input, "events", Constants.default_events())

    interval_min =
      Map.get(input, "poll_interval_minutes", Constants.default_poll_interval_minutes())

    job_id = pr_job_id(url)
    cron_expr = minutes_to_cron(interval_min)

    task_description =
      "Check GitHub PR #{url} for events: #{Enum.join(events, ", ")}. " <>
        "If any of these events occurred, notify the user via push_notification " <>
        "and mark this check as completed."

    job = %{
      "id" => job_id,
      "type" => "agent",
      "cron" => cron_expr,
      "task" => task_description,
      "enabled" => true,
      "metadata" => %{
        "pr_url" => url,
        "events" => events,
        "poll_interval_minutes" => interval_min,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    case register_job(job) do
      {:ok, _registered} ->
        # Surface the registration in the TUI. The TuiForwarder allowlists
        # `subscribe_pr_registered` and bridges this Bus :system_event onto the
        # session topic the TUI streams.
        maybe_emit_registered(ctx, url, events, job_id, interval_min)

        {:ok,
         "PR subscription registered (job_id=#{job_id}): " <>
           "watching #{url} for #{Enum.join(events, ", ")} " <>
           "every #{interval_min}m via cron #{cron_expr}"}

      {:error, reason} ->
        {:error, "Failed to register PR subscription: #{inspect(reason)}"}
    end
  end

  defp maybe_emit_registered(ctx, url, events, job_id, interval_min) do
    session_id = ctx && Map.get(ctx, :session_id)

    if is_binary(session_id) do
      Bus.emit(:system_event, %{
        event: :subscribe_pr_registered,
        session_id: session_id,
        pr_url: url,
        events: events,
        job_id: job_id,
        poll_interval_minutes: interval_min
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Derive a stable job ID from the PR URL
  defp pr_job_id(url) do
    "pr_sub_" <> (url |> :erlang.md5() |> Base.encode16(case: :lower) |> String.slice(0, 8))
  end

  # Convert an interval in minutes to a cron expression that runs every N minutes
  defp minutes_to_cron(1), do: "* * * * *"
  defp minutes_to_cron(n), do: "*/#{n} * * * *"

  defp register_job(job) do
    if function_exported?(Scheduler, :add_job, 1) do
      Scheduler.add_job(job)
    else
      Logger.warning("[SubscribePr] Scheduler not available — job not persisted: #{job["id"]}")
      {:ok, job}
    end
  rescue
    e ->
      Logger.warning("[SubscribePr] Scheduler.add_job raised: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
