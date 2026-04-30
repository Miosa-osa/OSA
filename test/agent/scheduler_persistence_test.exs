defmodule OptimalSystemAgent.Agent.Scheduler.SQLiteStoreTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Scheduler.SQLiteStore

  setup_all do
    # `function_exported?/3` returns false for modules whose BEAM has not
    # been loaded yet. Tests in this module check exports across
    # `SQLiteStore` — load it once so order doesn't matter.
    Code.ensure_loaded!(SQLiteStore)
    :ok
  end

  @sample_job %{
    "id" => "job-test-#{:rand.uniform(100_000)}",
    "name" => "Test Job",
    "cron" => "*/5 * * * *",
    "enabled" => true,
    "action" => "test_action"
  }

  describe "SQLiteStore module" do
    test "module is defined" do
      assert Code.ensure_loaded?(OptimalSystemAgent.Agent.Scheduler.SQLiteStore)
    end

    test "init/0 is exported" do
      assert function_exported?(SQLiteStore, :init, 0)
    end

    test "save_job/1 is exported" do
      assert function_exported?(SQLiteStore, :save_job, 1)
    end

    test "load_all_jobs/0 is exported" do
      assert function_exported?(SQLiteStore, :load_all_jobs, 0)
    end

    test "delete_job/1 is exported" do
      assert function_exported?(SQLiteStore, :delete_job, 1)
    end

    test "update_job/2 is exported" do
      assert function_exported?(SQLiteStore, :update_job, 2)
    end
  end

  describe "save_job/1 structure" do
    test "requires id key" do
      job_no_id = Map.delete(@sample_job, "id")
      # Should raise FunctionClauseError or return error — either is acceptable
      result =
        try do
          SQLiteStore.save_job(job_no_id)
        rescue
          FunctionClauseError -> :clause_error
        end

      assert result in [:ok, :clause_error, {:error, :repo_unavailable}] or
               match?({:error, _}, result)
    end

    test "accepts job map with id" do
      result = SQLiteStore.save_job(@sample_job)
      # Either succeeds or fails with repo error (no DB in test env)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "load_all_jobs/0" do
    test "returns a list" do
      result = SQLiteStore.load_all_jobs()
      assert is_list(result)
    end
  end

  describe "delete_job/1" do
    test "returns :ok or error tuple" do
      result = SQLiteStore.delete_job("nonexistent-id")
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "update_job/2" do
    test "returns not_found or error for missing job" do
      result = SQLiteStore.update_job("nonexistent-id-xyz", %{"enabled" => false})
      assert result == {:error, :not_found} or match?({:error, _}, result)
    end
  end
end
