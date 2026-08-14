defmodule OptimalSystemAgent.Tools.Builtins.WebSearchTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.WebSearch.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-session"}

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "tool_name/0 returns web_search" do
      assert Constants.tool_name() == "web_search"
    end

    test "default_limit/0 is a positive integer" do
      assert is_integer(Constants.default_limit())
      assert Constants.default_limit() > 0
    end

    test "ddg_url/0 is the DuckDuckGo HTML endpoint" do
      assert Constants.ddg_url() =~ "duckduckgo.com"
    end
  end

  # ---------------------------------------------------------------------------
  # Tool declarations
  # ---------------------------------------------------------------------------

  describe "Tool declarations" do
    test "name/0 returns web_search" do
      assert Tool.name() == "web_search"
    end

    test "should_defer?/0 is false" do
      refute Tool.should_defer?()
    end

    test "always_load?/0 is true" do
      assert Tool.always_load?()
    end

    test "concurrency_safe?/2 is true" do
      assert Tool.concurrency_safe?(%{}, @ctx)
    end

    test "read_only?/2 is true" do
      assert Tool.read_only?(%{}, @ctx)
    end

    test "destructive?/2 is false" do
      refute Tool.destructive?(%{}, @ctx)
    end

    test "open_world?/2 is true" do
      assert Tool.open_world?(%{}, @ctx)
    end

    test "max_result_size_chars/0 is 50_000" do
      assert Tool.max_result_size_chars() == 50_000
    end

    test "safety/0 is :read_only" do
      assert Tool.safety() == :read_only
    end

    test "parameters/0 requires query" do
      params = Tool.parameters()
      assert params["required"] == ["query"]
      assert Map.has_key?(params["properties"], "query")
      assert Map.has_key?(params["properties"], "limit")
    end

    test "to_classifier_input/1 extracts query" do
      assert Tool.to_classifier_input(%{"query" => "elixir otp"}) ==
               %{query: "elixir otp"}
    end

    test "to_classifier_input/1 returns empty string for missing query" do
      assert Tool.to_classifier_input(%{}) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  describe "Prompt.render/1" do
    test "returns a non-empty string" do
      prompt = Prompt.render([])
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "mentions sources requirement" do
      assert Prompt.render([]) =~ "Sources"
    end

    test "references web_fetch for follow-up fetching" do
      assert Prompt.render([]) =~ "web_fetch"
    end

    # This description used to interpolate the current month and year, which
    # made a STATIC prompt-prefix span change once a month and guaranteed a
    # provider prompt-cache miss for a fact the session environment block
    # already carries to the day. The prompt now points AT that block instead.
    test "is byte-identical across renders and carries no interpolated date" do
      prompt = Prompt.render([])

      assert prompt == Prompt.render([])
      assert prompt == Prompt.render(current_date: "January 2030")
      refute prompt =~ Integer.to_string(Date.utc_today().year)
      assert prompt =~ "Today's date"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.validate/2
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "accepts a valid query string" do
      assert {:ok, %{"query" => "elixir otp"}} =
               Handler.validate(%{"query" => "elixir otp"}, @ctx)
    end

    test "rejects non-string query" do
      assert {:error, "query must be a string", -32_602} =
               Handler.validate(%{"query" => 42}, @ctx)
    end

    test "rejects missing query" do
      assert {:error, "Missing required parameter: query", -32_602} =
               Handler.validate(%{}, @ctx)
    end

    test "passes through limit param" do
      input = %{"query" => "beam vm", "limit" => 10}
      assert {:ok, ^input} = Handler.validate(input, @ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.check_permissions/2
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "always allows" do
      input = %{"query" => "anything"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.execute/2 — empty query guard
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2 — input guards" do
    test "returns error for blank query" do
      assert {:error, "query must not be empty"} =
               Handler.execute(%{"query" => "   "}, @ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # UI.render/3
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test ":tool_use returns kind web_search with query" do
      result = UI.render(:tool_use, %{"query" => "elixir genserver"}, [])
      assert result.kind == "web_search"
      assert result.query == "elixir genserver"
    end

    test ":tool_result returns kind web_search_result with bytes" do
      result = UI.render(:tool_result, "1. [Some Result](https://example.com)", [])
      assert result.kind == "web_search_result"
      assert is_integer(result.bytes)
    end

    test ":rejected returns kind web_search_rejected" do
      assert %{kind: "web_search_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind web_search_error with message" do
      result = UI.render(:error, "DuckDuckGo returned HTTP 429", [])
      assert result.kind == "web_search_error"
      assert result.message == "DuckDuckGo returned HTTP 429"
    end

    test "unknown stage returns nil" do
      assert nil == UI.render(:unknown_stage, %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Shim — flat module still compiles and delegates
  # ---------------------------------------------------------------------------

  describe "WebSearch shim" do
    test "name/0 delegates correctly" do
      assert OptimalSystemAgent.Tools.Builtins.WebSearch.name() == "web_search"
    end

    test "safety/0 delegates correctly" do
      assert OptimalSystemAgent.Tools.Builtins.WebSearch.safety() == :read_only
    end
  end
end
