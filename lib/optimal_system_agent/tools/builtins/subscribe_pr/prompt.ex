defmodule OptimalSystemAgent.Tools.Builtins.SubscribePr.Prompt do
  @moduledoc """
  Dynamic prompt for the `subscribe_pr` tool.

  Cross-references `cron` since PR subscriptions register periodic cron
  jobs via Agent.Scheduler to poll the GitHub API.
  """

  alias OptimalSystemAgent.Tools.Builtins.SubscribePr.Constants

  def render(_opts \\ []) do
    """
    Subscribe to GitHub Pull Request events and get notified when they occur.

    Registers a periodic poll job via the `cron` scheduler that checks the
    PR's state on GitHub's API at the requested interval. When a matching
    event fires (merge, close, review request, etc.) the agent is woken and
    can react — e.g. run CI, post a comment, or update a task.

    Use this when:
    - You want to know when a PR is merged so you can trigger a deployment
    - You need to react when a PR is closed or receives a review request
    - You're waiting on review approval before proceeding

    `pr_url` must be a full GitHub PR URL:
      https://github.com/owner/repo/pull/123

    `events` — list of events to watch. One or more of:
      #{Enum.join(Constants.valid_events(), ", ")}
    Default: #{Enum.join(Constants.default_events(), ", ")}

    `poll_interval_minutes` — how often to check. One of:
      #{Enum.join(Enum.map(Constants.valid_poll_intervals(), &to_string/1), ", ")} minutes
    Default: #{Constants.default_poll_interval_minutes()} minutes.

    The subscription is registered as a named cron job in CRONS.json.
    Call with the same `pr_url` again to update the events or interval.
    Maximum #{Constants.max_subscriptions()} active PR subscriptions.
    """
  end
end
