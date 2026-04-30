defmodule OptimalSystemAgent.Tools.Builtins.SendMessageTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.SendMessage
  alias OptimalSystemAgent.Tools.Builtins.SendMessage.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "test-session"}

  # ---------------------------------------------------------------------------
  # Shim delegation — flat module must expose the full behaviour surface
  # ---------------------------------------------------------------------------

  describe "shim delegation" do
    test "name/0 returns send_message" do
      assert SendMessage.name() == "send_message"
    end

    test "parameters/0 requires to and message" do
      params = SendMessage.parameters()
      assert params["type"] == "object"
      assert "to" in params["required"]
      assert "message" in params["required"]
      assert Map.has_key?(params["properties"], "to")
      assert Map.has_key?(params["properties"], "message")
    end

    test "should_defer? returns false" do
      assert SendMessage.should_defer?() == false
    end

    test "always_load? returns true" do
      assert SendMessage.always_load?() == true
    end

    test "safety returns :write_safe" do
      assert SendMessage.safety() == :write_safe
    end

    test "concurrency_safe? returns true" do
      assert SendMessage.concurrency_safe?(%{}, ctx()) == true
    end

    test "read_only? returns false" do
      assert SendMessage.read_only?(%{}, ctx()) == false
    end

    test "destructive? returns false" do
      assert SendMessage.destructive?(%{}, ctx()) == false
    end
  end

  # ---------------------------------------------------------------------------
  # Handler validation
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "accepts valid to and message" do
      input = %{"to" => "researcher", "message" => "start task 1"}
      assert {:ok, ^input} = Handler.validate(input, ctx())
    end

    test "rejects non-string to" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"to" => 42, "message" => "hi"}, ctx())

      assert msg =~ "string"
    end

    test "rejects non-string message" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"to" => "agent", "message" => 99}, ctx())

      assert msg =~ "string"
    end

    test "rejects missing to" do
      assert {:error, msg, -32_602} = Handler.validate(%{"message" => "hi"}, ctx())
      assert msg =~ "Missing"
    end

    test "rejects missing message" do
      assert {:error, msg, -32_602} = Handler.validate(%{"to" => "agent"}, ctx())
      assert msg =~ "Missing"
    end

    test "rejects empty input" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "Missing"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler check_permissions
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "always allows" do
      input = %{"to" => "x", "message" => "y"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # drain_pending_messages — delegated via shim
  # ---------------------------------------------------------------------------

  describe "drain_pending_messages/1" do
    test "returns empty list when no messages queued" do
      assert [] = SendMessage.drain_pending_messages("no-such-agent-#{:rand.uniform(9999)}")
    end

    test "shim delegates correctly" do
      # The function is accessible through the flat shim
      Code.ensure_loaded!(SendMessage)
      assert function_exported?(SendMessage, :drain_pending_messages, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool structured callbacks
  # ---------------------------------------------------------------------------

  describe "Tool structured callbacks" do
    test "validate_input delegates to Handler" do
      assert {:ok, _} = Tool.validate_input(%{"to" => "a", "message" => "b"}, ctx())
      assert {:error, _, _} = Tool.validate_input(%{}, ctx())
    end

    test "check_permissions always allows" do
      assert {:allow, _} = Tool.check_permissions(%{"to" => "x", "message" => "y"}, ctx())
    end

    test "aliases include message and msg" do
      aliases = Tool.aliases()
      assert "message" in aliases
      assert "msg" in aliases
    end
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  describe "Prompt.render/1" do
    test "returns a non-empty string" do
      result = Prompt.render([])
      assert is_binary(result)
      assert String.length(result) > 10
    end

    test "mentions agent communication" do
      result = Prompt.render([])
      assert result =~ "agent" or result =~ "message"
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "tool_name returns send_message" do
      assert Constants.tool_name() == "send_message"
    end

    test "pending_table is an atom" do
      assert is_atom(Constants.pending_table())
    end
  end

  # ---------------------------------------------------------------------------
  # UI render
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test "tool_use returns kind send_message with to and message" do
      result = UI.render(:tool_use, %{"to" => "researcher", "message" => "go"}, [])
      assert result.kind == "send_message"
      assert result.to == "researcher"
      assert result.message == "go"
    end

    test "tool_result returns kind send_message_result" do
      result = UI.render(:tool_result, "Message sent to researcher (session_abc)", [])
      assert result.kind == "send_message_result"
    end

    test "error returns kind send_message_error" do
      result = UI.render(:error, "agent not found", [])
      assert result.kind == "send_message_error"
      assert result.message == "agent not found"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, %{}, []) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # LegacyAdapter sees it as structured
  # ---------------------------------------------------------------------------

  describe "LegacyAdapter.structured?/1" do
    test "SendMessage is now structured" do
      assert OptimalSystemAgent.Tools.LegacyAdapter.structured?(SendMessage)
    end
  end
end
