defmodule OptimalSystemAgent.Tools.Builtins.WebFetchTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.WebFetch.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-session"}

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "tool_name/0 returns web_fetch" do
      assert Constants.tool_name() == "web_fetch"
    end

    test "default_max_length/0 is a positive integer" do
      assert is_integer(Constants.default_max_length())
      assert Constants.default_max_length() > 0
    end

    test "max_redirects/0 is a positive integer" do
      assert is_integer(Constants.max_redirects())
      assert Constants.max_redirects() > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Tool declarations
  # ---------------------------------------------------------------------------

  describe "Tool declarations" do
    test "name/0 returns web_fetch" do
      assert Tool.name() == "web_fetch"
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

    test "parameters/0 requires url" do
      params = Tool.parameters()
      assert params["required"] == ["url"]
      assert Map.has_key?(params["properties"], "url")
      assert Map.has_key?(params["properties"], "max_length")
    end

    test "to_classifier_input/1 extracts url" do
      assert Tool.to_classifier_input(%{"url" => "https://example.com"}) ==
               %{url: "https://example.com"}
    end

    test "to_classifier_input/1 returns empty string for missing url" do
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

    test "mentions HTTPS requirement" do
      assert Prompt.render([]) =~ "HTTPS"
    end

    test "mentions web_search for discovery" do
      assert Prompt.render([]) =~ "web_search"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.validate/2
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "accepts a valid url string" do
      assert {:ok, %{"url" => "https://example.com"}} =
               Handler.validate(%{"url" => "https://example.com"}, @ctx)
    end

    test "rejects non-string url" do
      assert {:error, "url must be a string", -32_602} =
               Handler.validate(%{"url" => 42}, @ctx)
    end

    test "rejects missing url" do
      assert {:error, "Missing required parameter: url", -32_602} =
               Handler.validate(%{}, @ctx)
    end

    test "passes through additional params" do
      input = %{"url" => "https://example.com", "max_length" => 500}
      assert {:ok, ^input} = Handler.validate(input, @ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.check_permissions/2 — URL validation
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "allows a valid https URL" do
      input = %{"url" => "https://example.com"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end

    test "allows localhost http URL" do
      input = %{"url" => "http://localhost:4000/api"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end

    test "allows 127.0.0.1 http URL" do
      input = %{"url" => "http://127.0.0.1:8080/health"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end

    test "denies plain http URL" do
      assert {:deny, "Access denied: " <> _reason} =
               Handler.check_permissions(%{"url" => "http://example.com"}, @ctx)
    end

    test "denies ftp:// scheme" do
      assert {:deny, "Access denied: " <> _reason} =
               Handler.check_permissions(%{"url" => "ftp://example.com/file"}, @ctx)
    end

    test "denies file:// scheme" do
      assert {:deny, "Access denied: " <> _reason} =
               Handler.check_permissions(%{"url" => "file:///etc/passwd"}, @ctx)
    end

    test "deny reason starts with 'Access denied:'" do
      {:deny, reason} = Handler.check_permissions(%{"url" => "http://example.com"}, @ctx)
      assert String.starts_with?(reason, "Access denied:")
    end
  end

  # ---------------------------------------------------------------------------
  # UI.render/3
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test ":tool_use returns kind web_fetch with url" do
      result = UI.render(:tool_use, %{"url" => "https://example.com"}, [])
      assert result.kind == "web_fetch"
      assert result.url == "https://example.com"
    end

    test ":tool_result returns kind web_fetch_result with bytes" do
      result = UI.render(:tool_result, "some content", [])
      assert result.kind == "web_fetch_result"
      assert is_integer(result.bytes)
    end

    test ":rejected returns kind web_fetch_rejected" do
      assert %{kind: "web_fetch_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind web_fetch_error with message" do
      result = UI.render(:error, "something went wrong", [])
      assert result.kind == "web_fetch_error"
      assert result.message == "something went wrong"
    end

    test "unknown stage returns nil" do
      assert nil == UI.render(:unknown_stage, %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Shim — flat module still compiles and delegates
  # ---------------------------------------------------------------------------

  describe "WebFetch shim" do
    test "name/0 delegates correctly" do
      assert OptimalSystemAgent.Tools.Builtins.WebFetch.name() == "web_fetch"
    end

    test "safety/0 delegates correctly" do
      assert OptimalSystemAgent.Tools.Builtins.WebFetch.safety() == :read_only
    end
  end
end
