defmodule OptimalSystemAgent.Skills.Curator do
  @moduledoc """
  Periodic skill lifecycle curator.

  Runs every 24h. Transitions:
    - No usage in 14+ days -> :stale (marks .stale file)
    - No usage in 30+ days AND <3 total uses -> :archived (marks .archived + .disabled)
    - Never deletes. Active skills: removes .stale marker if present.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Registry.SkillUsage

  @interval_ms 24 * 60 * 60 * 1000
  @stale_days 14
  @archive_days 30
  @archive_min_uses 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def curate_now, do: GenServer.cast(__MODULE__, :curate)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :curate, 5 * 60 * 1000)
    {:ok, %{last_run: nil, stats: %{}}}
  end

  @impl true
  def handle_info(:curate, state) do
    stats = do_curate()
    Process.send_after(self(), :curate, @interval_ms)
    {:noreply, %{state | last_run: DateTime.utc_now(), stats: stats}}
  end

  @impl true
  def handle_cast(:curate, state) do
    stats = do_curate()
    {:noreply, %{state | last_run: DateTime.utc_now(), stats: stats}}
  end

  defp do_curate do
    skills_dir =
      Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))

    now = DateTime.utc_now()

    skill_dirs =
      if File.dir?(skills_dir) do
        skills_dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(skills_dir, &1)))
        |> Enum.filter(&File.exists?(Path.join([skills_dir, &1, "SKILL.md"])))
      else
        []
      end

    stats = %{staled: 0, archived: 0, reactivated: 0, total: length(skill_dirs)}

    stats =
      Enum.reduce(skill_dirs, stats, fn name, acc ->
        usage = SkillUsage.get_usage(name)
        days_idle = days_since(usage.last_used_at, now)
        skill_dir = Path.join(skills_dir, name)
        stale_path = Path.join(skill_dir, ".stale")
        archived_path = Path.join(skill_dir, ".archived")

        cond do
          File.exists?(archived_path) ->
            acc

          days_idle >= @archive_days and usage.use_count < @archive_min_uses ->
            File.write(archived_path, "archived at #{DateTime.to_iso8601(now)}")

            File.write(
              Path.join(skill_dir, ".disabled"),
              "archived at #{DateTime.to_iso8601(now)}"
            )

            Logger.info(
              "[Curator] Archived skill '#{name}' (#{usage.use_count} uses, #{days_idle}d idle)"
            )

            %{acc | archived: acc.archived + 1}

          days_idle >= @stale_days ->
            unless File.exists?(stale_path) do
              File.write(stale_path, "stale at #{DateTime.to_iso8601(now)}")

              Logger.info(
                "[Curator] Marked skill '#{name}' as stale (#{days_idle}d idle)"
              )
            end

            %{acc | staled: acc.staled + 1}

          true ->
            if File.exists?(stale_path) do
              File.rm(stale_path)
              Logger.info("[Curator] Reactivated skill '#{name}'")
              %{acc | reactivated: acc.reactivated + 1}
            else
              acc
            end
        end
      end)

    if stats.staled > 0 or stats.archived > 0 or stats.reactivated > 0 do
      Logger.info(
        "[Curator] Run complete: #{stats.total} skills — #{stats.staled} stale, #{stats.archived} archived, #{stats.reactivated} reactivated"
      )
    end

    stats
  end

  defp days_since(nil, _now), do: 999
  defp days_since(last, now), do: DateTime.diff(now, last, :second) |> div(86400)
end
