defmodule OptimalSystemAgent.Skills.CuratorProvenanceTest do
  @moduledoc """
  The curator walks a directory written by three different populations —
  `SkillManager` create, `SkillGenerator` auto-generation, and the user by
  hand — and applied one idleness rule to all of them without ever asking
  which was which. It also assumed a FLAT layout everywhere, so a nested skill
  had no pin, no un-archive and no `skill_dir/1` at all.

  Chosen fix: record provenance on every decision, and REFUSE to act
  destructively on a skill the curator cannot classify. Plus make the nested
  layout work.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Skills.Curator

  @day 86_400

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-curator-prov-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_dir = Application.get_env(:optimal_system_agent, :skills_dir)
    prev_mode = Application.get_env(:optimal_system_agent, :skill_curation)
    Application.put_env(:optimal_system_agent, :skills_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      restore(:skills_dir, prev_dir)
      restore(:skill_curation, prev_mode)
    end)

    {:ok, dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp skill(dir, rel_path, frontmatter, age_days) do
    skill_dir = Path.join(dir, rel_path)
    File.mkdir_p!(skill_dir)
    path = Path.join(skill_dir, "SKILL.md")
    File.write!(path, frontmatter)

    mtime = System.system_time(:second) - age_days * @day
    File.touch!(path, mtime)
    File.touch!(skill_dir, mtime)
    skill_dir
  end

  defp disabled?(d), do: File.exists?(Path.join(d, ".disabled"))
  defp decision(decisions, name), do: Enum.find(decisions, &(&1.name == name))

  describe "provenance" do
    test "classifies the three writer populations", %{dir: dir} do
      gen = skill(dir, "gen", "---\nname: gen\nsource: auto:pattern-7\n---\n\nbody\n", 0)
      man = skill(dir, "man", "---\nname: man\nsource: skill_manager\n---\n\nbody\n", 0)
      hand = skill(dir, "hand", "---\nname: hand\n---\n\nbody\n", 0)
      opaque = skill(dir, "opaque", "---\nname: opaque\nno closing delimiter\n", 0)

      assert Curator.provenance(gen) == :generated
      assert Curator.provenance(man) == :managed
      assert Curator.provenance(hand) == :authored
      assert Curator.provenance(opaque) == :unclassifiable
    end

    test "every decision records provenance", %{dir: dir} do
      skill(dir, "gen", "---\nname: gen\nsource: auto:p1\n---\n\nbody\n", 400)

      {_stats, decisions} = Curator.do_curate()
      assert %{provenance: :generated} = decision(decisions, "gen")
    end
  end

  describe "refuses to act on a population it cannot classify" do
    test "a skill with unparseable frontmatter is never archived, even opted in", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      opaque = skill(dir, "opaque", "---\nname: opaque\nnever closes\n", 400)

      {stats, decisions} = Curator.do_curate()

      refute disabled?(opaque),
             "the curator switched off a skill whose SKILL.md it could not even parse"

      assert %{action: :none, provenance: :unclassifiable} = decision(decisions, "opaque")
      assert stats.unclassifiable == 1
    end

    test "a classifiable long-idle skill is still archived when opted in", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      gen = skill(dir, "gen", "---\nname: gen\nsource: auto:p1\n---\n\nbody\n", 400)

      Curator.do_curate()
      assert disabled?(gen)
    end
  end

  describe "nested layout" do
    test "a nested skill can be pinned, curated and un-archived by name", %{dir: dir} do
      Application.put_env(:optimal_system_agent, :skill_curation, :archive)
      nested = skill(dir, "reasoning/deep", "---\nname: deep\n---\n\nbody\n", 400)

      assert {:ok, "deep"} = Curator.pin("deep"),
             "pin/1 could not find a nested skill (skill_dir/1 assumed a flat layout)"

      assert Curator.pinned?("deep")

      Curator.do_curate()
      refute disabled?(nested), "a pinned nested skill was archived"

      Curator.unpin("deep")
      Curator.do_curate()
      assert disabled?(nested)
      assert "deep" in Curator.archived()

      assert {:ok, "deep"} = Curator.unarchive("deep")
      refute disabled?(nested)
    end

    test "a nested skill appears in the curation pass at all", %{dir: dir} do
      skill(dir, "core/buried", "---\nname: buried\n---\n\nbody\n", 400)

      {stats, decisions} = Curator.do_curate()

      assert stats.total >= 1
      assert %{action: :archive} = decision(decisions, "buried")
    end
  end
end
