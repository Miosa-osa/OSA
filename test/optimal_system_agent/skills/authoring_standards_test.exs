defmodule OptimalSystemAgent.Skills.AuthoringStandardsTest do
  @moduledoc """
  CI enforcement of the SKILL.md authoring standard.

  Modelled on hermes-agent's `tests/skills/test_authoring_standards.py`: rather
  than a bespoke lint job, the standard is a test that globs every shipped
  `SKILL.md` and asserts it is clean. That gives per-skill failure output on the
  normal `mix test` gate, so a malformed skill cannot be merged.

  `@grandfathered` is the debt ledger for pre-existing violations. It must only
  ever SHRINK — `grandfather entries are still needed` fails when an entry is no
  longer violating anything, so the ledger cannot go stale.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Skills.Lint
  alias OptimalSystemAgent.Skills.Validator

  # %{"skill-dir-name" => [allowed rule atoms]}. Currently empty: every bundled
  # skill is clean. Do not add to this without a reason in the PR.
  @grandfathered %{}

  defp skills_root, do: Path.join([File.cwd!(), "priv", "skills"])

  defp bundled_paths, do: skills_root() |> Path.join("*/SKILL.md") |> Path.wildcard()

  defp skill_name(path), do: path |> Path.dirname() |> Path.basename()

  defp allowed?(finding),
    do: finding.rule in Map.get(@grandfathered, skill_name(finding.path), [])

  test "priv/skills contains skills to check" do
    assert bundled_paths() != [], "expected bundled SKILL.md files under priv/skills"
  end

  test "every bundled SKILL.md passes the authoring standard" do
    findings =
      bundled_paths()
      |> Enum.flat_map(&Validator.validate_file/1)
      |> Enum.reject(&allowed?/1)

    assert findings == [],
           "bundled skills violate the authoring standard:\n\n" <> Validator.format(findings)
  end

  test "grandfather entries are still needed" do
    live_rules =
      bundled_paths()
      |> Enum.flat_map(&Validator.validate_file/1)
      |> Enum.group_by(&skill_name(&1.path), & &1.rule)

    for {skill, rules} <- @grandfathered, rule <- rules do
      assert rule in Map.get(live_rules, skill, []),
             "grandfathered #{skill}/#{rule} no longer violates anything — remove it from @grandfathered"
    end
  end

  test "the lint surface reports the same bundled tree as clean" do
    report = Lint.run(roots: [skills_root()], include_bundled: false)

    assert report.errors == 0, Lint.format(report)
    assert length(report.scanned) == length(bundled_paths())
  end

  describe "the merge-reconciler skill is wired for discovery" do
    test "it declares the triggers the finalizer's conflict message uses" do
      path = Path.join([skills_root(), "merge-reconciler", "SKILL.md"])
      assert File.exists?(path)
      assert Validator.validate_file(path) == []

      {:ok, meta} =
        path
        |> File.read!()
        |> String.split("---", parts: 3)
        |> Enum.at(1)
        |> YamlElixir.read_from_string()

      assert meta["name"] == "merge-reconciler"
      assert "conflict_briefs" in meta["triggers"]

      # The skill must actually tell the agent how to reach the skipped work.
      body = File.read!(path)
      assert body =~ "worktree_ref"
      assert body =~ "git show"
    end
  end
end
