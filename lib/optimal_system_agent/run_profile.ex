defmodule OptimalSystemAgent.RunProfile do
  @moduledoc """
  What kind of OSA process this is: the long-lived `:daemon` (the backend the
  TUI attaches to, `osagent serve`, a channel host) or a `:headless` run
  (`osa run`): one agent session, driven over stdin/stdout, then exit.

  A headless run uses the same session engine as the daemon (the same
  `Agent.Loop`, context assembly, compaction and persistence), but it must not
  take over anything a daemon owns, because a daemon is often running beside
  it on the same machine (MIOSA desktops run `osagent serve` as a service):

    * the HTTP port (binding it would fail, or worse, answer TUI traffic);
    * messaging channels (a second Telegram/Slack poller steals updates);
    * the OpenComputers host connection and the OTA updater;
    * the scheduler's cron jobs and heartbeats, background memory dreaming,
      and boot-time fleet re-dispatch, all of which would run twice.

  The profile is set before the application starts (`put/1`) and read by those
  boot paths. Unset means `:daemon`, so every existing entry point is unchanged.
  """

  @key :run_profile

  @type t :: :daemon | :headless

  @doc "The current profile. `:daemon` unless a headless run set it."
  @spec current() :: t()
  def current do
    case Application.get_env(:optimal_system_agent, @key) do
      :headless -> :headless
      _ -> :daemon
    end
  end

  @doc "True in a headless `osa run` process."
  @spec headless?() :: boolean()
  def headless?, do: current() == :headless

  @doc "Set the profile. Call before the application starts."
  @spec put(t()) :: :ok
  def put(profile) when profile in [:daemon, :headless] do
    Application.put_env(:optimal_system_agent, @key, profile)
  end
end
