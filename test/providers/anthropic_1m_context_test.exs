defmodule OptimalSystemAgent.Providers.Anthropic1MContextTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Anthropic

  defp beta_header(headers) do
    Enum.find_value(headers, fn
      {"anthropic-beta", v} -> v
      _ -> nil
    end)
  end

  describe "supports_1m?/1" do
    test "true for 1M-capable Claude models by default" do
      assert Anthropic.supports_1m?("claude-sonnet-4-6")
      assert Anthropic.supports_1m?("claude-opus-4-6")
    end

    test "false for non-1M Claude models" do
      refute Anthropic.supports_1m?("claude-haiku-4-5")
    end

    test "false when disabled via config" do
      Application.put_env(:optimal_system_agent, :disable_1m_context, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :disable_1m_context) end)
      refute Anthropic.supports_1m?("claude-sonnet-4-6")
    end

    test "false when disabled via DISABLE_1M_CONTEXT env" do
      System.put_env("DISABLE_1M_CONTEXT", "1")
      on_exit(fn -> System.delete_env("DISABLE_1M_CONTEXT") end)
      refute Anthropic.supports_1m?("claude-sonnet-4-6")
    end
  end

  describe "build_headers/3 context-1m beta" do
    test "adds the context-1m beta for a 1M-capable model" do
      headers = Anthropic.build_headers({:api_key, "k"}, nil, "claude-sonnet-4-6")
      assert beta_header(headers) =~ "context-1m-2025-08-07"
    end

    test "omits the context-1m beta for a non-1M model" do
      headers = Anthropic.build_headers({:api_key, "k"}, nil, "claude-haiku-4-5")
      refute (beta_header(headers) || "") =~ "context-1m"
    end

    test "build_headers/2 (no model) omits the context-1m beta" do
      headers = Anthropic.build_headers({:api_key, "k"}, nil)
      refute (beta_header(headers) || "") =~ "context-1m"
    end
  end
end
