defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11Test do
  # Tests in this module exercise pure command-building functions that return
  # {cmd, args} tuples — no actual process execution occurs.  However, the
  # module under test (LinuxX11) depends on Linux X11 tooling (xdotool, maim,
  # slop) for its runtime paths and is therefore only meaningful on Linux.
  # On macOS the tests are tagged :linux_only and excluded from the default
  # run to avoid spurious failures on developer machines.
  use ExUnit.Case, async: true

  @moduletag :linux_only

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11

  # ---------------------------------------------------------------------------
  # Shell escaping (security-critical)
  # ---------------------------------------------------------------------------

  describe "shell_escape/1" do
    test "normal text passes through in single quotes" do
      assert LinuxX11.shell_escape("hello world") == "'hello world'"
    end

    test "single quotes are properly escaped" do
      assert LinuxX11.shell_escape("it's here") == "'it'\\''s here'"
    end

    test "empty string returns empty single quotes" do
      assert LinuxX11.shell_escape("") == "''"
    end

    test "special shell characters are safely contained" do
      assert LinuxX11.shell_escape("$(rm -rf /)") == "'$(rm -rf /)'"
    end

    test "backticks are safely contained" do
      assert LinuxX11.shell_escape("`whoami`") == "'`whoami`'"
    end
  end

  # ---------------------------------------------------------------------------
  # Key combo translation (cmd → super)
  # ---------------------------------------------------------------------------

  describe "translate_key_combo/1" do
    test "translates cmd to super" do
      assert LinuxX11.translate_key_combo("cmd+c") == "super+c"
    end

    test "translates Cmd to super (case-insensitive)" do
      assert LinuxX11.translate_key_combo("Cmd+Shift+V") == "super+shift+v"
    end

    test "ctrl stays as ctrl" do
      assert LinuxX11.translate_key_combo("ctrl+a") == "ctrl+a"
    end

    test "simple key passes through" do
      assert LinuxX11.translate_key_combo("Return") == "Return"
    end

    test "multiple modifiers translated correctly" do
      assert LinuxX11.translate_key_combo("cmd+shift+alt+z") == "super+shift+alt+z"
    end
  end

  # ---------------------------------------------------------------------------
  # Screenshot command generation
  # ---------------------------------------------------------------------------

  describe "screenshot_cmd/1" do
    test "full screenshot uses maim" do
      {cmd, args} = LinuxX11.screenshot_cmd(%{path: "/tmp/test.png"})
      assert cmd == "maim"
      assert args == ["/tmp/test.png"]
    end

    test "region screenshot uses maim -g geometry" do
      {cmd, args} =
        LinuxX11.screenshot_cmd(%{
          path: "/tmp/test.png",
          region: %{"x" => 10, "y" => 20, "width" => 300, "height" => 200}
        })

      assert cmd == "maim"
      assert "-g" in args
      assert "300x200+10+20" in args
      assert "/tmp/test.png" in args
    end
  end

  # ---------------------------------------------------------------------------
  # Click command generation
  # ---------------------------------------------------------------------------

  describe "click_cmd/2" do
    test "generates xdotool click command" do
      {cmd, args} = LinuxX11.click_cmd(100, 200)
      assert cmd == "xdotool"
      assert args == ["mousemove", "--sync", "100", "200", "click", "1"]
    end
  end

  # ---------------------------------------------------------------------------
  # Double click command generation
  # ---------------------------------------------------------------------------

  describe "double_click_cmd/2" do
    test "generates xdotool double click command" do
      {cmd, args} = LinuxX11.double_click_cmd(100, 200)
      assert cmd == "xdotool"
      assert args == ["mousemove", "--sync", "100", "200", "click", "--repeat", "2", "1"]
    end
  end

  # ---------------------------------------------------------------------------
  # Type command generation
  # ---------------------------------------------------------------------------

  describe "type_cmd/1" do
    test "generates xdotool type command" do
      {cmd, args} = LinuxX11.type_cmd("hello world")
      assert cmd == "xdotool"
      assert args == ["type", "--clearmodifiers", "--", "hello world"]
    end
  end

  # ---------------------------------------------------------------------------
  # Key press command generation
  # ---------------------------------------------------------------------------

  describe "key_cmd/1" do
    test "generates xdotool key command with translation" do
      {cmd, args} = LinuxX11.key_cmd("cmd+c")
      assert cmd == "xdotool"
      assert args == ["key", "super+c"]
    end
  end

  # ---------------------------------------------------------------------------
  # Scroll command generation
  # ---------------------------------------------------------------------------

  describe "scroll_cmd/2" do
    test "scroll up uses button 4" do
      {cmd, args} = LinuxX11.scroll_cmd("up", 3)
      assert cmd == "xdotool"
      assert args == ["click", "--repeat", "3", "4"]
    end

    test "scroll down uses button 5" do
      {cmd, args} = LinuxX11.scroll_cmd("down", 3)
      assert cmd == "xdotool"
      assert args == ["click", "--repeat", "3", "5"]
    end

    test "scroll left uses button 6" do
      {cmd, args} = LinuxX11.scroll_cmd("left", 1)
      assert cmd == "xdotool"
      assert args == ["click", "--repeat", "1", "6"]
    end

    test "scroll right uses button 7" do
      {cmd, args} = LinuxX11.scroll_cmd("right", 1)
      assert cmd == "xdotool"
      assert args == ["click", "--repeat", "1", "7"]
    end
  end

  # ---------------------------------------------------------------------------
  # Move mouse command generation
  # ---------------------------------------------------------------------------

  describe "move_mouse_cmd/2" do
    test "generates xdotool mousemove command" do
      {cmd, args} = LinuxX11.move_mouse_cmd(500, 300)
      assert cmd == "xdotool"
      assert args == ["mousemove", "--sync", "500", "300"]
    end
  end

  # ---------------------------------------------------------------------------
  # Drag command generation
  # ---------------------------------------------------------------------------

  describe "drag_cmd/4" do
    test "generates xdotool drag sequence" do
      cmds = LinuxX11.drag_cmd(100, 200, 300, 400)
      assert is_list(cmds)
      assert length(cmds) == 4

      [{c1, a1}, {c2, a2}, {c3, a3}, {c4, a4}] = cmds
      assert {c1, a1} == {"xdotool", ["mousemove", "--sync", "100", "200"]}
      assert {c2, a2} == {"xdotool", ["mousedown", "1"]}
      assert {c3, a3} == {"xdotool", ["mousemove", "--sync", "300", "400"]}
      assert {c4, a4} == {"xdotool", ["mouseup", "1"]}
    end
  end
end
