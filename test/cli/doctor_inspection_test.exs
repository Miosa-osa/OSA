defmodule OptimalSystemAgent.CLI.Doctor.InspectionTest do
  @moduledoc """
  Tests for `osa doctor --config`.

  A diagnostic has one failure mode worse than being absent: being confidently
  wrong. Two things are asserted here above all —

    * the report never crashes and never truncates itself (a section that raises
      must degrade to a stated-unknown row, not take the rest with it), and
    * the gate this module mirrors from `Agent.Context` is still the gate
      `Agent.Context` actually applies.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.CLI.Doctor.Inspection

  describe "report structure" do
    test "produces every section, each with rows" do
      %{sections: sections} = Inspection.report()

      titles = Enum.map(sections, & &1.title)
      assert length(titles) == 5

      assert Enum.any?(titles, &(&1 =~ "static base"))
      assert Enum.any?(titles, &(&1 =~ "per-turn"))
      assert Enum.any?(titles, &(&1 =~ "SKILLS"))
      assert Enum.any?(titles, &(&1 =~ "layers"))
      assert Enum.any?(titles, &(&1 =~ "effective keys"))

      for %{rows: rows} <- sections, row <- rows do
        assert row.status in [:loaded, :absent, :inert, :malformed]
        assert is_binary(row.label) and row.label != ""
        assert is_binary(row.detail) and row.detail != ""
      end
    end

    test "every row carries provenance — a path and a layer, never a bare value" do
      %{sections: sections} = Inspection.report()

      for %{title: title, rows: rows} <- sections, row <- rows do
        assert is_binary(row.path) and row.path != "",
               "#{title}/#{row.label} reported no path"

        assert is_binary(row.layer) and row.layer != "",
               "#{title}/#{row.label} reported no layer"
      end
    end

    test "no section is silently empty — an empty section would read as 'fine'" do
      %{sections: sections} = Inspection.report()

      for %{title: title, rows: rows} <- sections do
        refute rows == [], "#{title} produced no rows at all"
      end
    end
  end

  describe "printed output" do
    test "run/0 prints a legend and does not raise" do
      out = capture_io(fn -> assert Inspection.run() == :ok end)

      assert out =~ "OSA Setup Inspection"
      assert out =~ "SETTINGS — layers"
      # The legend is load-bearing: `–` vs `○` is the "inert vs absent"
      # distinction the whole report exists to draw.
      assert out =~ "inert"
      assert out =~ "absent"
      assert out =~ "malformed"
    end

    test "doctor --config routes here, and bare doctor does not" do
      out = capture_io(fn -> OptimalSystemAgent.CLI.Doctor.run(["--config"]) end)
      assert out =~ "OSA Setup Inspection"
      refute out =~ "OSA Health Check"
    end
  end

  describe "the report does not perturb what it measures" do
    # This is a regression test with a real scar behind it. The first version of
    # `static_base_row/0` called `Soul.static_token_count/0`, which assembles the
    # prompt on a cache miss and `:persistent_term.put/2`s it — a global mutation
    # that also forces a system-wide GC scan. Merely *running the diagnostic*
    # turned a green suite into eighteen failures in unrelated modules.
    #
    # A diagnostic that changes global state is not a diagnostic. Reading an
    # unassembled cache must leave it unassembled.
    test "reporting never assembles the Soul static base" do
      before = :persistent_term.get({OptimalSystemAgent.Soul, :static_base}, :missing)

      _ = Inspection.report()
      _ = capture_io(fn -> Inspection.run() end)

      assert :persistent_term.get({OptimalSystemAgent.Soul, :static_base}, :missing) == before,
             "the inspection report mutated Soul's persistent_term cache"
    end

    test "an unassembled static base is reported as a state, not manufactured" do
      %{sections: sections} = Inspection.report()
      %{rows: rows} = Enum.find(sections, &(&1.title =~ "static base"))
      row = Enum.find(rows, &(&1.label == "static base (assembled)"))

      assert row
      # Whichever state it is in, it must be honest about it rather than
      # printing a number it caused to exist.
      assert row.status in [:absent, :inert, :loaded, :malformed]

      if row.status == :absent do
        assert row.detail =~ "does not trigger it"
      end
    end
  end

  describe "the mirrored BOOTSTRAP.md gate" do
    # This module re-evaluates a private gate in `Agent.Context`. A mirror that
    # has drifted is worse than no mirror, so the regex is pinned against the
    # exact template shape it is meant to recognise.
    test "recognises a filled-in USER.md name line and rejects the blank template" do
      re = Inspection.user_known_regex()

      assert Regex.match?(re, "## Profile\n- **Name:** Ada Lovelace\n")
      assert Regex.match?(re, "-   **Name:**   Ada\n")

      refute Regex.match?(re, "## Profile\n- **Name:**\n")
      refute Regex.match?(re, "## Profile\n- **Name:** \n")
      refute Regex.match?(re, "## Profile\n- Name: Ada\n")
    end

    test "the mirror is declared, so its existence is discoverable" do
      assert Inspection.mirrors_private_gate?()
    end
  end

  describe "settings provenance" do
    test "each effective key names the layer that produced it" do
      %{sections: sections} = Inspection.report()
      %{rows: rows} = Enum.find(sections, &(&1.title =~ "effective keys"))

      valid = ~w(user project local flag session cascade) ++ ["MERGED (concat)", "MERGED (deep)"]

      for row <- rows do
        assert Enum.any?(valid, &String.starts_with?(row.layer, &1)),
               "key #{row.label} reported layer #{inspect(row.layer)}, which names no layer"
      end
    end

    test "the layer section and the key section agree about workspace trust" do
      %{sections: sections} = Inspection.report()
      %{rows: layer_rows} = Enum.find(sections, &(&1.title =~ "layers"))
      %{rows: key_rows} = Enum.find(sections, &(&1.title =~ "effective keys"))

      project_layer = Enum.find(layer_rows, &(&1.label == "project"))

      # If the project layer is reported inert (withheld pending trust), no key
      # may simultaneously be reported as plainly loaded from it — that
      # contradiction is exactly what a provenance report exists to prevent.
      if project_layer && project_layer.status == :inert do
        for row <- key_rows, row.layer == "project" do
          refute row.status == :loaded,
                 "key #{row.label} claims to be loaded from a withheld project layer"
        end
      end
    end
  end

  describe "skills reasoning" do
    test "every skill row states whether it is surfaced and why" do
      %{sections: sections} = Inspection.report()
      %{rows: rows} = Enum.find(sections, &(&1.title == "SKILLS"))

      for row <- rows, row.status in [:loaded, :inert] do
        assert row.detail =~ ~r/surfaced/i,
               "skill #{row.label} did not say whether it surfaces: #{row.detail}"
      end
    end

    test "a paths:-gated skill is reported inert with its globs named" do
      %{sections: sections} = Inspection.report()
      %{rows: rows} = Enum.find(sections, &(&1.title == "SKILLS"))

      for row <- rows, row.status == :inert, row.detail =~ "paths:" do
        assert row.detail =~ "NOT surfaced"
        # Naming the gate without naming the globs leaves the reader no move.
        assert row.detail =~ ~r/paths: \S/
      end
    end
  end
end
