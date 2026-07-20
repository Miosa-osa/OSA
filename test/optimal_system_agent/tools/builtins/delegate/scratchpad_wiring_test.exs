defmodule OptimalSystemAgent.Tools.Builtins.Delegate.ScratchpadWiringTest do
  @moduledoc """
  Verifies that `delegate` injects the SHARED scratchpad directory into a
  spawned worker's task, and that the worker resolves to the SAME directory as
  the coordinator — asserted via the config_dir + RunStore seams, without
  spawning a real LLM.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Scratchpad
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.Delegate.Handler

  setup do
    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_boot = Application.get_env(:optimal_system_agent, :bootstrap_dir)

    tmp =
      Path.join(System.tmp_dir!(), "osa_delegate_scratch_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    Application.delete_env(:optimal_system_agent, :bootstrap_dir)
    ConfigFile.reload()

    on_exit(fn ->
      restore(:config_dir, prev_dir)
      restore(:bootstrap_dir, prev_boot)
      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, v), do: Application.put_env(:optimal_system_agent, key, v)

  test "the worker's task carries the coordinator's shared scratchpad dir" do
    parent_id = "coord-#{System.unique_integer([:positive])}"

    injected = Handler.inject_scratchpad("Do the thing.", parent_id)
    parent_dir = Scratchpad.dir_for(Scratchpad.session_root(parent_id))

    assert injected =~ parent_dir
    assert injected =~ "shared scratchpad"
    # Original task is preserved.
    assert injected =~ "Do the thing."
    # The directory was actually created (CC scratchpadDir is a real dir).
    assert File.dir?(parent_dir)
  end

  test "a spawned worker resolves to the SAME dir as the parent" do
    parent_id = "coord-#{System.unique_integer([:positive])}"
    worker_id = "agent:#{parent_id}:1"

    # The delegate handler computes the shared dir from the parent id.
    parent_dir = Handler.scratchpad_dir_for(parent_id)

    # The spawned worker is recorded in RunStore with parent_session_id = parent.
    RunStore.start_run(%{
      agent_id: worker_id,
      parent_session_id: parent_id,
      role: "worker",
      task: "t"
    })

    # At runtime the worker's own scratchpad tool resolves via session_root →
    # the same directory the coordinator uses.
    worker_dir = Scratchpad.dir_for(Scratchpad.session_root(worker_id))

    assert worker_dir == parent_dir
  end

  test "a worker's write is visible to the coordinator" do
    parent_id = "coord-#{System.unique_integer([:positive])}"
    worker_id = "agent:#{parent_id}:2"

    RunStore.start_run(%{
      agent_id: worker_id,
      parent_session_id: parent_id,
      role: "worker",
      task: "t"
    })

    # Worker publishes findings under its resolved (shared) id.
    worker_root = Scratchpad.session_root(worker_id)
    assert {:ok, _} = Scratchpad.write(worker_root, "worker-findings.md", "found it")

    # Coordinator reads under its own resolved id — same directory.
    coord_root = Scratchpad.session_root(parent_id)
    assert {:ok, "found it"} = Scratchpad.read(coord_root, "worker-findings.md")
  end
end
