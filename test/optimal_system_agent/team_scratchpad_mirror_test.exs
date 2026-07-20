defmodule OptimalSystemAgent.TeamScratchpadMirrorTest do
  @moduledoc """
  The ETS `Team` scratchpad optionally mirrors to the durable file scratchpad.
  The ETS path stays authoritative and unchanged; mirroring only ADDS a file.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Team
  alias OptimalSystemAgent.Scratchpad

  setup do
    Team.init_tables()

    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_boot = Application.get_env(:optimal_system_agent, :bootstrap_dir)

    tmp = Path.join(System.tmp_dir!(), "osa_team_mirror_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    Application.delete_env(:optimal_system_agent, :bootstrap_dir)
    ConfigFile.reload()

    team_id = "team-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Team.cleanup(team_id)
      restore(:config_dir, prev_dir)
      restore(:bootstrap_dir, prev_boot)
      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    {:ok, team_id: team_id}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, v), do: Application.put_env(:optimal_system_agent, key, v)

  test "default write_scratchpad keeps ETS behavior and writes no file", %{team_id: team_id} do
    assert :ok = Team.write_scratchpad(team_id, "agent-1", "ephemeral")
    assert Team.read_scratchpad(team_id, "agent-1") == "ephemeral"
    # No file mirror by default.
    assert Scratchpad.list(team_id) == []
  end

  test "mirror: true also writes a durable, inspectable file", %{team_id: team_id} do
    assert :ok = Team.write_scratchpad(team_id, "agent-1", "durable note", mirror: true)
    # ETS path still works.
    assert Team.read_scratchpad(team_id, "agent-1") == "durable note"
    # File scratchpad now holds a mirror keyed by agent id.
    assert {:ok, "durable note"} = Scratchpad.read(team_id, "agent-1.md")
  end
end
