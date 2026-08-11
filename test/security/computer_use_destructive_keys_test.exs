defmodule OptimalSystemAgent.Security.ComputerUseDestructiveKeysTest do
  @moduledoc """
  The computer-use `key` action synthesizes real keystrokes into the user's
  live desktop session.

  Its only gate was `Constants.key_combo_pattern/0` — `~r/^[a-zA-Z0-9+\\-_ ]+$/`.
  That is a *character-set* check: it proves the string cannot inject shell
  metacharacters when interpolated into an xdotool command line. It says
  nothing about whether the combo is safe to press, and `ctrl+alt+del`,
  `super+l` and `alt+F4` are all made entirely of permitted characters.

  These tests pin the denylist and its normalization, so the gate cannot be
  evaded by case, spacing, modifier order, or `cmd`/`win`/`meta` aliasing.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Constants
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Handler
  alias OptimalSystemAgent.Tools.UseContext

  defp validate(combo) do
    case Handler.validate(%{"action" => "key", "text" => combo}, UseContext.empty()) do
      {:ok, _} -> :ok
      {:error, msg, _code} -> {:error, msg}
    end
  end

  describe "the combos the character-class gate let straight through" do
    @tag :security
    test "ctrl+alt+del, super+l and alt+F4 all satisfy the old pattern" do
      # Establishes the premise: the pattern is not the thing stopping these.
      for combo <- ["ctrl+alt+del", "super+l", "alt+F4"] do
        assert Regex.match?(Constants.key_combo_pattern(), combo),
               "#{combo} is made only of permitted characters — the charset check cannot stop it"
      end
    end

    @tag :security
    test "and are now DENIED by the destructive-combo gate" do
      for combo <- ["ctrl+alt+del", "super+l", "alt+F4"] do
        assert {:error, msg} = validate(combo), "#{combo} must be refused"
        assert msg =~ "destructive", "refusal for #{combo} should name the reason: #{msg}"
      end
    end
  end

  describe "destructive_combo?/1 coverage" do
    @tag :security
    test "session-ending and login-manager combos" do
      for combo <- [
            "ctrl+alt+delete",
            "ctrl+alt+del",
            "ctrl+alt+backspace",
            "ctrl+alt+end",
            "super+l",
            "ctrl+alt+l",
            "super+shift+e",
            "super+shift+q"
          ] do
        assert Constants.destructive_combo?(combo), "#{combo} should be denied"
      end
    end

    @tag :security
    test "every virtual-terminal switch, ctrl+alt+F1 through F12" do
      for n <- 1..12 do
        combo = "ctrl+alt+F#{n}"
        assert Constants.destructive_combo?(combo), "#{combo} yanks away the graphical session"
      end
    end

    @tag :security
    test "force-quit and power combos, including the macOS spellings" do
      for combo <- [
            "alt+F4",
            "super+q",
            "cmd+q",
            "ctrl+q",
            "ctrl+alt+q",
            "cmd+option+escape",
            "ctrl+cmd+q",
            "ctrl+cmd+power",
            "power",
            "XF86PowerOff"
          ] do
        assert Constants.destructive_combo?(combo), "#{combo} should be denied"
      end
    end

    @tag :security
    test "magic SysRq" do
      assert Constants.destructive_combo?("alt+sysrq")
      assert Constants.destructive_combo?("alt+prtsc")
    end
  end

  describe "normalization — the denylist cannot be evaded by rewriting the combo" do
    @tag :security
    test "case, spacing and modifier order are all irrelevant" do
      for combo <- [
            "CTRL+ALT+DEL",
            "Ctrl+Alt+Delete",
            "ctrl + alt + del",
            "del+alt+ctrl",
            "alt+ctrl+delete",
            "  ctrl+alt+del  "
          ] do
        assert Constants.destructive_combo?(combo), "#{combo} is ctrl+alt+del in disguise"
      end
    end

    @tag :security
    test "modifier aliases collapse — cmd/win/meta/super are one key" do
      for combo <- ["super+l", "cmd+l", "win+l", "meta+l", "Windows+L", "mod4+l"] do
        assert Constants.destructive_combo?(combo), "#{combo} locks the screen"
      end
    end

    @tag :security
    test "normalize_combo/1 is order-independent and alias-resolved" do
      assert Constants.normalize_combo("Cmd+Shift+A") == ["a", "shift", "super"]
      assert Constants.normalize_combo("shift+cmd+a") == ["a", "shift", "super"]
      assert Constants.normalize_combo("ESC") == ["escape"]
      assert Constants.normalize_combo(nil) == []
    end
  end

  describe "ordinary combos are untouched" do
    @tag :security
    test "everyday editing and navigation combos still validate" do
      for combo <- [
            "ctrl+c",
            "ctrl+v",
            "ctrl+shift+t",
            "cmd+s",
            "alt+tab",
            "shift+F4",
            "super+space",
            "Return",
            "Tab",
            "ctrl+shift+F5",
            "F4"
          ] do
        refute Constants.destructive_combo?(combo), "#{combo} is ordinary and must still work"
        assert :ok = validate(combo), "#{combo} must still validate"
      end
    end

    @tag :security
    test "the charset and length checks still apply and still run first" do
      assert {:error, msg} = validate("ctrl+c; rm -rf /")
      assert msg =~ "invalid characters"

      assert {:error, msg} = validate("")
      assert msg =~ "must not be empty"

      assert {:error, msg} = validate(String.duplicate("a+", 200))
      assert msg =~ "too long"
    end
  end

  describe "hold_key shares the gate" do
    @tag :security
    test "a destructive combo cannot be smuggled in via hold_key" do
      assert {:error, msg, _} =
               Handler.validate(
                 %{"action" => "hold_key", "text" => "ctrl+alt+del", "duration" => 1},
                 UseContext.empty()
               )

      assert msg =~ "destructive"
    end
  end
end
