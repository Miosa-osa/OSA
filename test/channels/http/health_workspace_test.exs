defmodule OptimalSystemAgent.Channels.HTTP.HealthWorkspaceTest do
  @moduledoc """
  `bin/osa` decides whether a listening daemon is THIS workspace's — and
  therefore whether it may adopt it or let `osa stop` kill it — by comparing
  `/health`'s `workspace` against its own launch directory (#245). When the
  field was absent, "a healthy daemon answers on the expected port" was the
  whole test, so one folder could attach to another folder's backend.

  `LauncherWorkspaceIsolationTest` pins the wiring by source-grep; this pins the
  behaviour: `/health` actually returns the boot-captured launch directory that
  `Workspace.Cwd.original_cwd/0` reports.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP
  alias OptimalSystemAgent.Workspace.Cwd

  @opts HTTP.init([])

  setup do
    # original_cwd/0 is boot-captured in :persistent_term; restore it after.
    original = Cwd.original_cwd()
    on_exit(fn -> Cwd.set_original_cwd(original) end)
    :ok
  end

  defp health_workspace do
    :get
    |> conn("/health")
    |> HTTP.call(@opts)
    |> then(& &1.resp_body)
    |> Jason.decode!()
    |> Map.get("workspace")
  end

  test "reports the boot-captured launch directory" do
    Cwd.set_original_cwd("/tmp")
    assert health_workspace() == "/tmp"
  end

  test "reports an expanded absolute path, since bin/osa compares absolutes" do
    Cwd.set_original_cwd(".")
    workspace = health_workspace()
    assert workspace == Path.expand(".")
    assert String.starts_with?(workspace, "/")
  end

  test "is always a non-nil string, so the launcher never has to defend against null" do
    Cwd.set_original_cwd("/tmp")
    workspace = health_workspace()
    assert is_binary(workspace)
    refute is_nil(workspace)
  end
end
