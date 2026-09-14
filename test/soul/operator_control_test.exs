defmodule OptimalSystemAgent.Soul.OperatorControlTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul

  setup do
    old_dir = Application.get_env(:optimal_system_agent, :bootstrap_dir)
    home = Path.join(System.tmp_dir!(), "osa_control_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    Application.put_env(:optimal_system_agent, :bootstrap_dir, home)

    on_exit(fn ->
      if old_dir do
        Application.put_env(:optimal_system_agent, :bootstrap_dir, old_dir)
      else
        Application.delete_env(:optimal_system_agent, :bootstrap_dir)
      end

      Soul.reload()
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  for template <- ["priv/prompts/SOUL.md", "examples/bootstrap/SOUL.md"] do
    @template template
    test "#{template} loads operator control into the actual system prompt", %{home: home} do
      source = Path.expand("../../#{@template}", __DIR__)
      File.cp!(source, Path.join(home, "SOUL.md"))
      Soul.reload()
      base = Soul.static_base(:native_tools)

      assert base =~ "## THE HARD BRAKE"
      assert base =~ "ZERO further tool"
      assert base =~ "Standing rules save on first statement"
      assert base =~ "Verify agent output immediately"
      assert base =~ "preference forbids local-model fallback"
      assert base =~ "Delegate bounded work"

      assert :binary.match(base, "## THE HARD BRAKE") <
               :binary.match(base, "## Your Inner Life")
    end
  end
end
