defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.AccessibilityTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Accessibility

  @sample_tree [
    %{role: "button", name: "Save", x: 500, y: 300, width: 80, height: 30},
    %{role: "textfield", name: "Email", x: 200, y: 150, width: 200, height: 25},
    %{role: "link", name: "Help", x: 100, y: 50, width: 40, height: 20},
    %{role: "statictext", name: "Welcome to the app", x: 10, y: 10, width: 300, height: 20},
    %{role: "image", name: "logo.png", x: 10, y: 40, width: 64, height: 64},
    %{role: "checkbox", name: "Remember me", x: 200, y: 200, width: 20, height: 20},
    %{role: "menuitem", name: "File", x: 0, y: 0, width: 40, height: 20}
  ]

  # ---------------------------------------------------------------------------
  # parse_tree — normalize raw data
  # ---------------------------------------------------------------------------

  describe "parse_tree/1" do
    test "normalizes string keys to atom keys" do
      raw = [%{"role" => "button", "name" => "OK", "x" => 10, "y" => 20}]
      [elem] = Accessibility.parse_tree(raw)
      assert elem.role == "button"
      assert elem.name == "OK"
      assert elem.x == 10
    end

    test "preserves atom keys" do
      raw = [%{role: "link", name: "Home", x: 0, y: 0}]
      [elem] = Accessibility.parse_tree(raw)
      assert elem.role == "link"
    end

    test "defaults missing fields" do
      raw = [%{role: "button"}]
      [elem] = Accessibility.parse_tree(raw)
      assert elem.name == ""
      assert elem.x == 0
      assert elem.y == 0
    end

    test "preserves native locator metadata behind semantic refs" do
      raw = [
        %{
          "role" => "button",
          "name" => "Close",
          "pid" => 42,
          "path" => [0, 2, 1],
          "identifier" => "close-button",
          "actions" => ["AXPress"]
        }
      ]

      [parsed] = Accessibility.parse_tree(raw)
      {_text, %{"e0" => ref}} = Accessibility.assign_refs([parsed])

      assert ref.pid == 42
      assert ref.path == [0, 2, 1]
      assert ref.identifier == "close-button"
      assert ref.actions == ["AXPress"]
    end
  end

  # ---------------------------------------------------------------------------
  # assign_refs — only interactive elements get refs
  # ---------------------------------------------------------------------------

  describe "assign_refs/1" do
    test "interactive elements get sequential refs" do
      parsed = Accessibility.parse_tree(@sample_tree)
      {_text, refs} = Accessibility.assign_refs(parsed)

      # button, textfield, link, checkbox, menuitem = 5 interactive
      assert map_size(refs) == 5
      # button Save
      assert Map.has_key?(refs, "e0")
      # textfield Email
      assert Map.has_key?(refs, "e1")
      # link Help
      assert Map.has_key?(refs, "e2")
      # checkbox Remember me
      assert Map.has_key?(refs, "e3")
      # menuitem File
      assert Map.has_key?(refs, "e4")
    end

    test "non-interactive elements are excluded from refs" do
      parsed = Accessibility.parse_tree(@sample_tree)
      {_text, refs} = Accessibility.assign_refs(parsed)

      ref_roles = refs |> Map.values() |> Enum.map(& &1.role)
      refute "statictext" in ref_roles
      refute "image" in ref_roles
    end

    test "ref map contains coordinates and metadata" do
      parsed = Accessibility.parse_tree(@sample_tree)
      {_text, refs} = Accessibility.assign_refs(parsed)

      save_btn = refs["e0"]
      assert save_btn.role == "button"
      assert save_btn.name == "Save"
      assert save_btn.x == 500
      assert save_btn.y == 300
    end
  end

  # ---------------------------------------------------------------------------
  # format_tree — compact text output
  # ---------------------------------------------------------------------------

  describe "format_tree/1" do
    test "produces compact text with refs" do
      parsed = Accessibility.parse_tree(@sample_tree)
      {text, _refs} = Accessibility.assign_refs(parsed)

      assert text =~ "[e0] button \"Save\" (500,300)"
      assert text =~ "[e1] textfield \"Email\" (200,150)"
      assert text =~ "[e2] link \"Help\" (100,50)"
    end

    test "non-interactive elements shown without refs" do
      parsed = Accessibility.parse_tree(@sample_tree)
      {text, _refs} = Accessibility.assign_refs(parsed)

      assert text =~ "statictext \"Welcome to the app\""
      assert text =~ "image \"logo.png\""
      # But they should NOT have [eN] refs
      refute Regex.match?(~r/\[e\d+\] statictext/, text)
      refute Regex.match?(~r/\[e\d+\] image/, text)
    end

    test "20-element tree under 1000 tokens" do
      # Generate 20 elements
      elements =
        for i <- 0..19 do
          %{role: "button", name: "Button #{i}", x: i * 50, y: i * 30, width: 40, height: 20}
        end

      parsed = Accessibility.parse_tree(elements)
      {text, _refs} = Accessibility.assign_refs(parsed)

      # Rough token estimate: 1 token ≈ 4 chars
      estimated_tokens = div(byte_size(text), 4)
      assert estimated_tokens < 1000
    end
  end

  # ---------------------------------------------------------------------------
  # diff_trees — temporal pruning
  # ---------------------------------------------------------------------------

  describe "diff_trees/2" do
    test "identical trees produce empty diff" do
      parsed = Accessibility.parse_tree(@sample_tree)
      {_text, refs_old} = Accessibility.assign_refs(parsed)
      {_text, refs_new} = Accessibility.assign_refs(parsed)

      diff = Accessibility.diff_trees(refs_old, refs_new)
      assert diff == ""
    end

    test "added element shows +" do
      old = %{
        "e0" => %{role: "button", name: "Save", x: 500, y: 300}
      }

      new = %{
        "e0" => %{role: "button", name: "Save", x: 500, y: 300},
        "e1" => %{role: "button", name: "Cancel", x: 600, y: 300}
      }

      diff = Accessibility.diff_trees(old, new)
      assert diff =~ "+ [e1]"
      assert diff =~ "Cancel"
    end

    test "removed element shows -" do
      old = %{
        "e0" => %{role: "button", name: "Save", x: 500, y: 300},
        "e1" => %{role: "link", name: "Help", x: 100, y: 50}
      }

      new = %{
        "e0" => %{role: "button", name: "Save", x: 500, y: 300}
      }

      diff = Accessibility.diff_trees(old, new)
      assert diff =~ "- [e1]"
      assert diff =~ "Help"
    end

    test "moved element shows ~" do
      old = %{
        "e0" => %{role: "textfield", name: "Email", x: 200, y: 150}
      }

      new = %{
        "e0" => %{role: "textfield", name: "Email", x: 200, y: 180}
      }

      diff = Accessibility.diff_trees(old, new)
      assert diff =~ "~ [e0]"
      assert diff =~ "(200,150)"
      assert diff =~ "(200,180)"
    end

    test "diff is compact — only changes" do
      old = %{
        "e0" => %{role: "button", name: "Save", x: 500, y: 300},
        "e1" => %{role: "textfield", name: "Email", x: 200, y: 150},
        "e2" => %{role: "link", name: "Help", x: 100, y: 50}
      }

      new = %{
        "e0" => %{role: "button", name: "Save", x: 500, y: 300},
        "e1" => %{role: "textfield", name: "Email", x: 200, y: 150},
        "e3" => %{role: "button", name: "New", x: 300, y: 200}
      }

      diff = Accessibility.diff_trees(old, new)
      # e0, e1 unchanged — not in diff
      refute diff =~ "[e0]"
      refute diff =~ "[e1]"
      # e2 removed, e3 added
      assert diff =~ "- [e2]"
      assert diff =~ "+ [e3]"
    end
  end
end
