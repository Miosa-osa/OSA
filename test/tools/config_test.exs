defmodule OptimalSystemAgent.Tools.Builtins.ConfigTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Config
  alias OptimalSystemAgent.Tools.Builtins.Config.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "test-session"}

  # ---------------------------------------------------------------------------
  # Shim delegation — flat module must expose the full behaviour surface
  # ---------------------------------------------------------------------------

  describe "shim delegation" do
    test "name/0 returns config" do
      assert Config.name() == "config"
    end

    test "parameters/0 requires action" do
      params = Config.parameters()
      assert params["type"] == "object"
      assert "action" in params["required"]
      assert Map.has_key?(params["properties"], "action")
      assert Map.has_key?(params["properties"], "key")
      assert Map.has_key?(params["properties"], "value")
      assert Map.has_key?(params["properties"], "layer")
    end

    test "should_defer? returns true (rarely used)" do
      assert Config.should_defer?() == true
    end

    test "always_load? returns false" do
      assert Config.always_load?() == false
    end

    test "safety returns :write_safe" do
      assert Config.safety() == :write_safe
    end

    test "destructive? returns false" do
      assert Config.destructive?(%{"action" => "set"}, ctx()) == false
    end
  end

  # ---------------------------------------------------------------------------
  # Per-action execution semantics
  # ---------------------------------------------------------------------------

  describe "per-action read_only? / concurrency_safe?" do
    test "get action is read_only" do
      assert Config.read_only?(%{"action" => "get"}, ctx()) == true
    end

    test "list action is read_only" do
      assert Config.read_only?(%{"action" => "list"}, ctx()) == true
    end

    test "set action is not read_only" do
      assert Config.read_only?(%{"action" => "set"}, ctx()) == false
    end

    test "get action is concurrency_safe" do
      assert Config.concurrency_safe?(%{"action" => "get"}, ctx()) == true
    end

    test "list action is concurrency_safe" do
      assert Config.concurrency_safe?(%{"action" => "list"}, ctx()) == true
    end

    test "set action is not concurrency_safe" do
      assert Config.concurrency_safe?(%{"action" => "set"}, ctx()) == false
    end
  end

  # ---------------------------------------------------------------------------
  # Handler validation
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "accepts get action" do
      assert {:ok, _} = Handler.validate(%{"action" => "get", "key" => "x"}, ctx())
    end

    test "accepts list action" do
      assert {:ok, _} = Handler.validate(%{"action" => "list"}, ctx())
    end

    test "accepts set action with key and value" do
      input = %{"action" => "set", "key" => "k", "value" => "v"}
      assert {:ok, ^input} = Handler.validate(input, ctx())
    end

    test "rejects set without key" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "set", "value" => "v"}, ctx())

      assert msg =~ "key" or msg =~ "value"
    end

    test "rejects set without value" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "set", "key" => "k"}, ctx())

      assert msg =~ "key" or msg =~ "value"
    end

    test "rejects unknown action" do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "explode"}, ctx())
      assert msg =~ "Unknown"
    end

    test "rejects missing action" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "Missing"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler check_permissions
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "always allows" do
      input = %{"action" => "list"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Handler execute — functional tests
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2 for get" do
    test "returns not-set message for unknown key" do
      {:ok, msg} =
        Handler.execute(%{"action" => "get", "key" => "totally_unknown_key_xyz"}, ctx())

      assert msg =~ "not set" or msg =~ "Setting not found"
    end
  end

  describe "Handler.execute/2 for list" do
    test "returns a string response" do
      {:ok, msg} = Handler.execute(%{"action" => "list"}, ctx())
      assert is_binary(msg)
    end
  end

  describe "Handler.execute/2 for set" do
    test "set session layer returns success message" do
      {:ok, msg} =
        Handler.execute(
          %{"action" => "set", "key" => "test_key_#{:rand.uniform(9999)}", "value" => "42"},
          ctx()
        )

      assert msg =~ "session-level"
    end

    test "set unknown layer returns error" do
      {:error, msg} =
        Handler.execute(
          %{
            "action" => "set",
            "key" => "k",
            "value" => "v",
            "layer" => "galactic"
          },
          ctx()
        )

      assert msg =~ "Unknown layer"
    end
  end

  # ---------------------------------------------------------------------------
  # Tool structured callbacks
  # ---------------------------------------------------------------------------

  describe "Tool structured callbacks" do
    test "validate_input delegates to Handler" do
      assert {:ok, _} = Tool.validate_input(%{"action" => "list"}, ctx())
      assert {:error, _, _} = Tool.validate_input(%{}, ctx())
    end

    test "check_permissions always allows" do
      assert {:allow, _} = Tool.check_permissions(%{"action" => "list"}, ctx())
    end

    test "aliases include settings and cfg" do
      aliases = Tool.aliases()
      assert "settings" in aliases
      assert "cfg" in aliases
    end

    test "to_classifier_input extracts action and key" do
      result = Tool.to_classifier_input(%{"action" => "get", "key" => "foo"})
      assert result.action == "get"
      assert result.key == "foo"
    end
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  describe "Prompt.render/1" do
    test "returns a non-empty string" do
      result = Prompt.render([])
      assert is_binary(result)
      assert String.length(result) > 20
    end

    test "mentions get set list" do
      result = Prompt.render([])
      assert result =~ "get"
      assert result =~ "set"
      assert result =~ "list"
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "tool_name returns config" do
      assert Constants.tool_name() == "config"
    end

    test "read_actions includes get and list" do
      assert "get" in Constants.read_actions()
      assert "list" in Constants.read_actions()
    end

    test "write_actions includes set" do
      assert "set" in Constants.write_actions()
    end
  end

  # ---------------------------------------------------------------------------
  # UI render
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test "tool_use returns kind config with action" do
      result = UI.render(:tool_use, %{"action" => "get", "key" => "provider"}, [])
      assert result.kind == "config"
      assert result.action == "get"
      assert result.key == "provider"
    end

    test "tool_result returns kind config_result" do
      result = UI.render(:tool_result, "provider = anthropic", [])
      assert result.kind == "config_result"
    end

    test "error returns kind config_error" do
      result = UI.render(:error, "bad action", [])
      assert result.kind == "config_error"
      assert result.message == "bad action"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, %{}, []) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # LegacyAdapter sees it as structured
  # ---------------------------------------------------------------------------

  describe "LegacyAdapter.structured?/1" do
    test "Config is now structured" do
      assert OptimalSystemAgent.Tools.LegacyAdapter.structured?(Config)
    end
  end
end
