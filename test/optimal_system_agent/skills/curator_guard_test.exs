defmodule OptimalSystemAgent.Skills.CuratorGuardTest do
  @moduledoc """
  D1 — the curator used to switch hand-written skills OFF on a timer.

  It wrote `.archived` + `.disabled` (and `.disabled` is honoured by
  `Tools.Registry`, `Tools.Builtins.SkillManager` and `Agents.Registry`, so the
  skill genuinely stops working) with no eligibility check, no pin, no
  un-archive path, and nothing that told the user it had happened. A skill with
  NO usage record was treated as 999 days idle, so a skill you wrote yesterday
  and had not yet invoked was archivable on the curator's very first pass.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Skills.Curator

  @day 86_400

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "osa-curator-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    prev_dir = Application.get_env(:optimal_system_agent, :skills_dir)
    prev_mode = Application.get_env(:optimal_system_agent, :skill_curation)
    prev_pins = Application.get_env(:optimal_system_agent, :skill_curation_pins)

    Application.put_env(:optimal_system_agent, :skills_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      restore(:skills_dir, prev_dir)
      restore(:skill_curation, prev_mode)
      restore(:skill_curation_pins, prev_pins)
    end)

    {:ok, dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # Create a skill whose SKILL.md is `age_days` old and which has NO usage
  # record — i.e. exactly the shape of a hand-written skill the user has not
  # invoked recently.
  defp skill(dir, name, age_days) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)
    path = Path.join(skill_dir, "SKILL.md")
    File.write!(path, "---\nname: #{name}\n---\n\nDo the thing.\n")

    mtime = System.system_time(:second) - age_days * @day
    File.touch!(path, mtime)
    File.touch!(skill_dir, mtime)
    skill_dir
  end

  defp disabled?(skill_dir), do: File.exists?(Path.join(skill_dir, ".disabled"))
  defp archived?(skill_dir), do: File.exists?(Path.join(skill_dir, ".archived"))

  describe "curation is opt-in" do
    test "the DEFAULT run never disables a long-idle, never-used skill", %{dir: dir} do
      Application.delete_env(:optimal_system_agent, :skill_curation)
      skill_dir = skill(dir, "quarterly-report", 400)

      {stats, decisions} = Curator.do_curate()

      refute disabled?(skill_dir),
             "the default curator run wrote .disabled — a hand-written skill was switched off"

      refute archived?(skill_dir)

      # It still SAYS what it would have done — report-only, not blind.
      assert stats.mode == :report
      refute stats.applied
      assert %{action: :archive, applied: false} = decision(decisions, "quarterly-report")
    end

    test "opting in with :archive restores the destructive behaviour", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill_dir = skill(dir, "abandoned", 400)

      Curator.do_curate()

      assert archived?(skill_dir)
      assert disabled?(skill_dir)
    end
  end

  describe "pinning" do
    test "a pinned skill is never archived, even when opted in", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill_dir = skill(dir, "pinned-skill", 400)

      assert {:ok, "pinned-skill"} = Curator.pin("pinned-skill")
      assert Curator.pinned?("pinned-skill")

      Curator.do_curate()

      refute archived?(skill_dir), "a pinned skill was archived"
      refute disabled?(skill_dir)
    end

    test "`pinned: true` in SKILL.md frontmatter also pins", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill_dir = skill(dir, "fm-pinned", 400)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: fm-pinned\npinned: true\n---\n\nbody\n"
      )

      Curator.do_curate()

      refute disabled?(skill_dir)
    end

    test "unpin/1 makes a skill eligible again", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill_dir = skill(dir, "temp-pin", 400)

      Curator.pin("temp-pin")
      Curator.do_curate()
      refute disabled?(skill_dir)

      Curator.unpin("temp-pin")
      refute Curator.pinned?("temp-pin")
      Curator.do_curate()
      assert disabled?(skill_dir)
    end
  end

  describe "never-used skills are not 999 days idle" do
    test "a skill written today with no usage record is left alone", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill_dir = skill(dir, "written-today", 0)

      {_stats, decisions} = Curator.do_curate()

      refute disabled?(skill_dir),
             "a skill authored today was archived because it had never been invoked"

      assert %{action: :none} = decision(decisions, "written-today")
    end
  end

  describe "un-archive" do
    test "unarchive/1 brings an archived skill back", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill_dir = skill(dir, "gone", 400)

      Curator.do_curate()
      assert disabled?(skill_dir)
      assert "gone" in Curator.archived()

      assert {:ok, "gone"} = Curator.unarchive("gone")

      refute disabled?(skill_dir)
      refute archived?(skill_dir)
      refute "gone" in Curator.archived()
    end
  end

  describe "surfacing" do
    test "every run writes a machine-readable report next to the skills", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      skill(dir, "reported", 400)

      Curator.do_curate()

      report = Path.join(dir, ".curation-report.json")
      assert File.exists?(report)

      decoded = report |> File.read!() |> Jason.decode!()
      assert decoded["mode"] == "archive"
      assert decoded["applied"] == true

      assert Enum.any?(decoded["decisions"], fn d ->
               d["skill"] == "reported" and d["action"] == "archive" and d["applied"]
             end)
    end
  end

  defp decision(decisions, name), do: Enum.find(decisions, &(&1.name == name))
end
