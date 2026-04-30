defmodule OptimalSystemAgent.Tools.Builtins.CronTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Tools.Builtins.Cron.Handler
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    config_dir =
      Path.join(System.tmp_dir!(), "osa-cron-handler-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)

    previous = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, config_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :config_dir, previous)
      else
        Application.delete_env(:optimal_system_agent, :config_dir)
      end

      File.rm_rf(config_dir)
    end)

    {:ok, ctx: UseContext.new(%{permission_tier: :full})}
  end

  test "create stores an agent job with normalized preset schedule", %{ctx: ctx} do
    input = %{
      "action" => "create",
      "task" => "send a concise morning planning note",
      "schedule" => "hourly"
    }

    assert {:ok, job} = Handler.execute(input, ctx)
    assert job["type"] == "agent"
    assert job["job"] == "send a concise morning planning note"
    assert job["schedule"] == "0 * * * *"

    assert :ok = Scheduler.remove_job(job["id"])
  end
end
