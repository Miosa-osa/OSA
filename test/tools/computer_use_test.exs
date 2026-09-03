defmodule OptimalSystemAgent.Tools.Builtins.ComputerUseTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.MacOS, as: MacOSAdapter
  alias OptimalSystemAgent.Tools.UseContext

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------

  test "macOS adapter implements the universal desktop action surface" do
    callbacks = [
      {:get_tree, 0},
      {:list_apps, 0},
      {:list_windows, 0},
      {:focus_window, 1},
      {:close_window, 1},
      {:list_tabs, 1},
      {:close_tabs, 1},
      {:launch, 1},
      {:cursor, 0},
      {:right_click, 1},
      {:triple_click, 1},
      {:middle_click, 2},
      {:left_mouse_down, 2},
      {:left_mouse_up, 2},
      {:perform_element, 3},
      {:clipboard_get, 0},
      {:clipboard_set, 1},
      {:clipboard_clear, 0},
      {:snapshot, 1},
      {:list_surfaces, 1},
      {:set_value, 1},
      {:scroll_to, 1},
      {:resize_window, 1},
      {:move_window, 1},
      {:hold_key, 2},
      {:wait, 1}
    ]

    Enum.each(callbacks, fn {name, arity} ->
      assert function_exported?(MacOSAdapter, name, arity), "missing #{name}/#{arity}"
    end)
  end

  describe "tool metadata" do
    test "name returns computer_use" do
      assert ComputerUse.name() == "computer_use"
    end

    test "description is a non-empty string" do
      desc = ComputerUse.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
      assert desc =~ "screenshot"
    end

    test "safety returns :write_destructive" do
      assert ComputerUse.safety() == :write_destructive
    end

    test "parameters returns valid JSON schema" do
      params = ComputerUse.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "action")
      assert "action" in params["required"]
    end

    test "parameters includes all action types" do
      params = ComputerUse.parameters()
      action_enum = params["properties"]["action"]["enum"]
      assert "screenshot" in action_enum
      assert "click" in action_enum
      assert "double_click" in action_enum
      assert "type" in action_enum
      assert "key" in action_enum
      assert "scroll" in action_enum
      assert "move_mouse" in action_enum
      assert "drag" in action_enum
      assert "list_tabs" in action_enum
      assert "close_tabs" in action_enum
    end

    test "perception actions are read-only but closing tabs is not" do
      assert ComputerUse.read_only?(%{"action" => "list_tabs"}, UseContext.empty())
      assert ComputerUse.read_only?(%{"action" => "get_tree"}, UseContext.empty())
      refute ComputerUse.read_only?(%{"action" => "close_tabs"}, UseContext.empty())
    end
  end

  # ---------------------------------------------------------------------------
  # Availability gating
  # ---------------------------------------------------------------------------

  describe "available?/0" do
    test "returns false by default" do
      # Ensure the config is not set (default state)
      original = Application.get_env(:optimal_system_agent, :computer_use_enabled)
      Application.delete_env(:optimal_system_agent, :computer_use_enabled)

      assert ComputerUse.available?() == false

      # Restore
      if original != nil do
        Application.put_env(:optimal_system_agent, :computer_use_enabled, original)
      end
    end

    test "returns true when config flag is true" do
      original = Application.get_env(:optimal_system_agent, :computer_use_enabled)
      Application.put_env(:optimal_system_agent, :computer_use_enabled, true)

      assert ComputerUse.available?() == true

      # Restore
      Application.delete_env(:optimal_system_agent, :computer_use_enabled)

      if original != nil do
        Application.put_env(:optimal_system_agent, :computer_use_enabled, original)
      end
    end

    test "returns false when config flag is false" do
      Application.put_env(:optimal_system_agent, :computer_use_enabled, false)
      assert ComputerUse.available?() == false
      Application.delete_env(:optimal_system_agent, :computer_use_enabled)
    end

    test "returns false when config flag is a truthy non-boolean" do
      Application.put_env(:optimal_system_agent, :computer_use_enabled, "yes")
      assert ComputerUse.available?() == false
      Application.delete_env(:optimal_system_agent, :computer_use_enabled)
    end
  end

  # ---------------------------------------------------------------------------
  # Action validation
  # ---------------------------------------------------------------------------

  describe "action validation" do
    test "missing action returns error" do
      assert {:error, msg} = ComputerUse.execute(%{})
      assert msg =~ "action"
    end

    test "invalid action returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "explode"})
      assert msg =~ "Invalid action"
      assert msg =~ "explode"
    end
  end

  # ---------------------------------------------------------------------------
  # Screenshot parameter validation
  # ---------------------------------------------------------------------------

  describe "screenshot validation" do
    test "screenshot with no region is valid (passes validation)" do
      assert {:ok, _} =
               ComputerUse.validate_input(%{"action" => "screenshot"}, UseContext.empty())
    end

    test "screenshot with valid region passes validation" do
      assert {:ok, _} =
               ComputerUse.validate_input(
                 %{
                   "action" => "screenshot",
                   "region" => %{"x" => 0, "y" => 0, "width" => 100, "height" => 100}
                 },
                 UseContext.empty()
               )
    end

    test "screenshot with invalid region returns error" do
      assert {:error, msg} =
               ComputerUse.execute(%{
                 "action" => "screenshot",
                 "region" => %{"x" => 0, "y" => 0, "width" => -1, "height" => 100}
               })

      assert msg =~ "Region"
    end

    test "screenshot with incomplete region returns error" do
      assert {:error, msg} =
               ComputerUse.execute(%{
                 "action" => "screenshot",
                 "region" => %{"x" => 0, "y" => 0}
               })

      assert msg =~ "Region"
    end

    test "screenshot with zero-width region returns error" do
      assert {:error, msg} =
               ComputerUse.execute(%{
                 "action" => "screenshot",
                 "region" => %{"x" => 0, "y" => 0, "width" => 0, "height" => 100}
               })

      assert msg =~ "Region"
    end

    test "provider-generated empty 0x0 region is treated as omitted" do
      assert {:ok, normalized} =
               ComputerUse.validate_input(
                 %{
                   "action" => "screenshot",
                   "region" => %{"x" => 0, "y" => 0, "width" => 0, "height" => 0}
                 },
                 UseContext.empty()
               )

      refute Map.has_key?(normalized, "region")
    end
  end

  # ---------------------------------------------------------------------------
  # Click parameter validation
  # ---------------------------------------------------------------------------

  describe "click validation" do
    test "click without coordinates or target returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "click"})
      assert msg =~ "click requires either coordinates"
    end

    test "click with only x returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "click", "x" => 100})
      assert msg =~ "click requires either coordinates"
    end

    test "click with negative coordinate returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "click", "x" => -1, "y" => 100})
      assert msg =~ "non-negative"
    end

    test "click with non-integer coordinate returns error" do
      assert {:error, msg} =
               ComputerUse.execute(%{"action" => "click", "x" => "abc", "y" => 100})

      assert msg =~ "must be an integer"
    end

    test "double_click without coordinates returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "double_click"})
      assert msg =~ "Missing required parameter: x"
    end

    test "blank target does not override valid coordinates" do
      assert {:ok, normalized} =
               ComputerUse.validate_input(
                 %{"action" => "click", "target" => "", "x" => 65, "y" => 195},
                 UseContext.empty()
               )

      refute Map.has_key?(normalized, "target")
      assert normalized["x"] == 65
      assert normalized["y"] == 195
    end

    test "blank target without coordinates is rejected" do
      assert {:error, message, _code} =
               ComputerUse.validate_input(
                 %{"action" => "left_click", "target" => ""},
                 UseContext.empty()
               )

      assert message =~ "coordinates"
    end
  end

  describe "browser tab validation" do
    test "close_tabs requires a narrow matcher" do
      assert {:error, message, _code} =
               ComputerUse.validate_input(
                 %{"action" => "close_tabs", "app" => "Arc"},
                 UseContext.empty()
               )

      assert message =~ "url_contains or title_contains"
    end

    test "close_tabs accepts an app and URL matcher" do
      assert {:ok, _} =
               ComputerUse.validate_input(
                 %{"action" => "close_tabs", "app" => "Arc", "url_contains" => "auth.openai.com"},
                 UseContext.empty()
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Type parameter validation
  # ---------------------------------------------------------------------------

  describe "type validation" do
    test "type without text returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "type"})
      assert msg =~ "Missing required parameter: text"
    end

    test "type with empty text returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "type", "text" => ""})
      assert msg =~ "must not be empty"
    end

    test "type with non-string text returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "type", "text" => 123})
      assert msg =~ "must be a string"
    end

    test "type with excessively long text returns error" do
      long_text = String.duplicate("a", 5000)
      assert {:error, msg} = ComputerUse.execute(%{"action" => "type", "text" => long_text})
      assert msg =~ "exceeds maximum length"
    end
  end

  # ---------------------------------------------------------------------------
  # Key combo parameter validation
  # ---------------------------------------------------------------------------

  describe "key validation" do
    test "key without text returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "key"})
      assert msg =~ "Missing required parameter: text"
    end

    test "key with empty combo returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "key", "text" => ""})
      assert msg =~ "must not be empty"
    end

    test "key combo rejects injection characters" do
      assert {:error, msg} =
               ComputerUse.execute(%{"action" => "key", "text" => "cmd+c; rm -rf /"})

      assert msg =~ "invalid characters"
    end

    test "key combo rejects quotes" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "key", "text" => ~s(cmd+"c")})
      assert msg =~ "invalid characters"
    end

    test "key combo rejects backticks" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "key", "text" => "cmd+`whoami`"})
      assert msg =~ "invalid characters"
    end

    test "key combo rejects dollar sign" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "key", "text" => "cmd+$HOME"})
      assert msg =~ "invalid characters"
    end

    test "key combo rejects excessively long input" do
      long_combo = String.duplicate("a+", 60)
      assert {:error, msg} = ComputerUse.execute(%{"action" => "key", "text" => long_combo})
      assert msg =~ "too long"
    end

    test "valid key combos pass validation" do
      for combo <- ~w(enter tab space cmd+c cmd+shift+v f1 up down) do
        assert {:ok, _} =
                 ComputerUse.validate_input(
                   %{"action" => "key", "text" => combo},
                   UseContext.empty()
                 )
      end
    end

    test "destructive system key combos are refused" do
      assert {:error, message, -32_602} =
               ComputerUse.validate_input(
                 %{"action" => "key", "text" => "ctrl+alt+delete"},
                 UseContext.empty()
               )

      assert message =~ "Refusing destructive key combo"
    end
  end

  # ---------------------------------------------------------------------------
  # Scroll parameter validation
  # ---------------------------------------------------------------------------

  describe "scroll validation" do
    test "scroll without direction returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "scroll"})
      assert msg =~ "Missing required parameter: direction"
    end

    test "scroll with invalid direction returns error" do
      assert {:error, msg} =
               ComputerUse.execute(%{"action" => "scroll", "direction" => "diagonal"})

      assert msg =~ "Invalid direction"
    end

    test "valid scroll directions pass validation" do
      for dir <- ~w(up down left right) do
        assert {:ok, _} =
                 ComputerUse.validate_input(
                   %{"action" => "scroll", "direction" => dir},
                   UseContext.empty()
                 )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Move mouse parameter validation
  # ---------------------------------------------------------------------------

  describe "move_mouse validation" do
    test "move_mouse without coordinates returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "move_mouse"})
      assert msg =~ "Missing required parameter: x"
    end

    test "move_mouse with only x returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "move_mouse", "x" => 100})
      assert msg =~ "Missing required parameter: y"
    end
  end

  # ---------------------------------------------------------------------------
  # Drag parameter validation
  # ---------------------------------------------------------------------------

  describe "drag validation" do
    test "drag without coordinates returns error" do
      assert {:error, msg} = ComputerUse.execute(%{"action" => "drag"})
      assert msg =~ "Missing required parameter: x"
    end
  end

  # ---------------------------------------------------------------------------
  # AppleScript sanitization (security)
  # ---------------------------------------------------------------------------

  describe "AppleScript sanitization" do
    test "double quotes are escaped" do
      sanitized = MacOSAdapter.sanitize_for_applescript(~s(hello "world"))
      assert sanitized == ~s(hello \\"world\\")
    end

    test "backslashes are escaped" do
      sanitized = MacOSAdapter.sanitize_for_applescript("path\\to\\file")
      assert sanitized == "path\\\\to\\\\file"
    end

    test "combined escaping works" do
      sanitized = MacOSAdapter.sanitize_for_applescript(~s(a\\b"c))
      assert sanitized == ~s(a\\\\b\\"c)
    end

    test "normal text passes through unchanged" do
      assert MacOSAdapter.sanitize_for_applescript("hello world") == "hello world"
    end
  end

  # ---------------------------------------------------------------------------
  # Key combo parsing
  # ---------------------------------------------------------------------------

  describe "key combo parsing" do
    test "parses simple key" do
      assert {[], "enter"} = MacOSAdapter.parse_key_combo("enter")
    end

    test "parses modifier+key" do
      {mods, key} = MacOSAdapter.parse_key_combo("cmd+c")
      assert mods == ["cmd"]
      assert key == "c"
    end

    test "parses multiple modifiers" do
      {mods, key} = MacOSAdapter.parse_key_combo("cmd+shift+v")
      assert "cmd" in mods
      assert "shift" in mods
      assert key == "v"
    end

    test "handles ctrl alias" do
      {mods, key} = MacOSAdapter.parse_key_combo("ctrl+a")
      assert "ctrl" in mods
      assert key == "a"
    end

    test "is case-insensitive" do
      {mods, key} = MacOSAdapter.parse_key_combo("CMD+SHIFT+Z")
      assert "cmd" in mods
      assert "shift" in mods
      assert key == "z"
    end
  end

  # ---------------------------------------------------------------------------
  # Screenshot command generation
  # ---------------------------------------------------------------------------

  describe "screenshot command generation" do
    test "full screenshot creates file in screenshots dir" do
      # Run the actual screenshot — on macOS CI this will work,
      # on non-macOS it will fail gracefully
      result = ComputerUse.execute(%{"action" => "screenshot"})

      case result do
        {:ok, {:image, %{media_type: "image/png", data: b64, path: path}}} ->
          assert is_binary(b64)
          assert byte_size(b64) > 0
          assert path =~ "screenshot_"
          assert path =~ ".png"
          assert File.exists?(path)
          # Clean up
          File.rm(path)

        {:ok, msg} when is_binary(msg) ->
          # Fallback if file couldn't be read
          assert msg =~ "Screenshot saved to"

        {:error, _} ->
          # Acceptable on non-macOS or headless environments
          :ok
      end
    end
  end
end
