defmodule OptimalSystemAgent.Tools.Builtins.AskUserTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.AskUser
  alias OptimalSystemAgent.Tools.Builtins.AskUser.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "test-session"}

  # ---------------------------------------------------------------------------
  # Shim delegation — flat module must expose the full behaviour surface
  # ---------------------------------------------------------------------------

  describe "shim delegation" do
    test "name/0 returns ask_user" do
      assert AskUser.name() == "ask_user"
    end

    test "parameters/0 returns valid JSON schema with required question" do
      params = AskUser.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "question")
      assert Map.has_key?(params["properties"], "options")
      assert params["required"] == ["question"]
    end

    test "should_defer? returns false" do
      assert AskUser.should_defer?() == false
    end

    test "always_load? returns true" do
      assert AskUser.always_load?() == true
    end

    test "safety returns :read_only" do
      assert AskUser.safety() == :read_only
    end

    test "concurrency_safe? returns false" do
      assert AskUser.concurrency_safe?(%{}, ctx()) == false
    end

    test "read_only? returns true" do
      assert AskUser.read_only?(%{}, ctx()) == true
    end

    test "destructive? returns false" do
      assert AskUser.destructive?(%{}, ctx()) == false
    end

    test "interrupt_behavior returns :block" do
      assert AskUser.interrupt_behavior() == :block
    end
  end

  # ---------------------------------------------------------------------------
  # Handler validation — structured layout
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "accepts valid question" do
      assert {:ok, %{"question" => "what?"}} =
               Handler.validate(%{"question" => "what?"}, ctx())
    end

    test "rejects empty question" do
      assert {:error, msg, -32_602} = Handler.validate(%{"question" => ""}, ctx())
      assert msg =~ "non-empty"
    end

    test "rejects non-string question" do
      assert {:error, msg, -32_602} = Handler.validate(%{"question" => 42}, ctx())
      assert msg =~ "string"
    end

    test "rejects missing question" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "Missing"
    end

    test "accepts question with options" do
      input = %{"question" => "pick one", "options" => ["a", "b"]}
      assert {:ok, ^input} = Handler.validate(input, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Handler check_permissions — always allow
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "always allows" do
      input = %{"question" => "hi"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Tool module — structured callbacks
  # ---------------------------------------------------------------------------

  describe "Tool structured callbacks" do
    test "validate_input delegates to Handler" do
      assert {:ok, _} = Tool.validate_input(%{"question" => "hello?"}, ctx())
      assert {:error, _, _} = Tool.validate_input(%{}, ctx())
    end

    test "check_permissions always allows" do
      assert {:allow, _} = Tool.check_permissions(%{"question" => "q"}, ctx())
    end

    test "aliases include ask and question" do
      aliases = Tool.aliases()
      assert "ask" in aliases
      assert "question" in aliases
    end

    test "description is non-empty string" do
      desc = Tool.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
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

    test "mentions ask_user concepts" do
      result = Prompt.render([])
      assert result =~ "question" or result =~ "user"
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "tool_name returns ask_user" do
      assert Constants.tool_name() == "ask_user"
    end

    test "timeout_ms is positive" do
      assert Constants.timeout_ms() > 0
    end

    test "pending_questions_table is an atom" do
      assert is_atom(Constants.pending_questions_table())
    end
  end

  # ---------------------------------------------------------------------------
  # UI render
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test "tool_use returns kind ask_user with question" do
      result = UI.render(:tool_use, %{"question" => "hello?", "options" => []}, [])
      assert result.kind == "ask_user"
      assert result.question == "hello?"
    end

    test "tool_use defaults options to empty list" do
      result = UI.render(:tool_use, %{"question" => "q"}, [])
      assert result.options == []
    end

    test "tool_result returns kind ask_user_result" do
      result = UI.render(:tool_result, "yes", [])
      assert result.kind == "ask_user_result"
      assert result.answer == "yes"
    end

    test "error returns kind ask_user_error" do
      result = UI.render(:error, "timeout", [])
      assert result.kind == "ask_user_error"
      assert result.message == "timeout"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, %{}, []) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # LegacyAdapter sees it as structured
  # ---------------------------------------------------------------------------

  describe "LegacyAdapter.structured?/1" do
    test "AskUser is now structured (has execute/2)" do
      assert OptimalSystemAgent.Tools.LegacyAdapter.structured?(AskUser)
    end

    test "Tool submodule is also structured" do
      assert OptimalSystemAgent.Tools.LegacyAdapter.structured?(Tool)
    end
  end
end
