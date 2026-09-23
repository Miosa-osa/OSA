defmodule OptimalSystemAgent.Providers.ReasoningCapabilityTest do
  @moduledoc """
  "Thinking off" is only offered where the model can actually stop reasoning,
  and the answer comes from the provider catalogs — not from a name pattern.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
  alias OptimalSystemAgent.Providers.ReasoningCapability, as: RC

  describe "can_disable?/2 reads the catalogs" do
    test "Claude Opus 5.5 always reasons; other Claude models can turn it off" do
      refute RC.can_disable?(:anthropic, "claude-opus-5-5")
      refute RC.can_disable?("anthropic", "claude-opus-5.5")
      assert RC.can_disable?(:anthropic, "claude-opus-5")
      assert RC.can_disable?(:anthropic, "claude-haiku-4-5")
    end

    test "Z.ai: a ladder without \"none\" is always-on, on/off and none-capable models are not" do
      refute RC.can_disable?(:zhipu, "glm-5.3-flash")
      assert RC.can_disable?(:zhipu, "glm-5.2")
      assert RC.can_disable?(:zhipu, "glm-5.1")
    end

    test "Ollama Cloud GLM tags are always-on reasoners; other tags are not" do
      refute RC.can_disable?(:ollama, "glm-5.2:cloud")
      refute RC.can_disable?(:ollama, "glm-5.3-flash:cloud")
      assert RC.can_disable?(:ollama, "kimi-k3:cloud")
    end

    test "it is catalog data, not a name match: an uncatalogued glm-looking id is not hidden" do
      assert RC.can_disable?(:ollama, "glm-99-experimental:cloud")
      assert RC.can_disable?(:openai, "glm-anything")
    end

    test "unknown providers and missing models keep the control" do
      assert RC.can_disable?(:mystery, "x")
      assert RC.can_disable?(nil, nil)
    end
  end

  describe "/reasoning off on an always-on model" do
    setup do
      keys = [:require_auth, :default_provider, :default_model]
      prev = Map.new(keys, &{&1, Application.get_env(:optimal_system_agent, &1)})
      Application.put_env(:optimal_system_agent, :require_auth, false)

      on_exit(fn ->
        Enum.each(prev, fn
          {k, nil} -> Application.delete_env(:optimal_system_agent, k)
          {k, v} -> Application.put_env(:optimal_system_agent, k, v)
        end)
      end)

      :ok
    end

    defp execute(arg) do
      conn(:post, "/execute", Jason.encode!(%{command: "reasoning", arg: arg}))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      |> ToolRoutes.call(ToolRoutes.init([]))
    end

    test "is refused with a sentence instead of silently doing nothing" do
      body = ToolRoutes.reasoning_off_refusal(:anthropic, "claude-opus-5-5")
      assert body =~ "always reasons"
      assert body =~ "claude-opus-5-5"
      assert ToolRoutes.reasoning_off_refusal(:anthropic, "claude-opus-5") == nil
    end

    test "the route answers with the refusal for the session's model" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Application.put_env(:optimal_system_agent, :default_model, "claude-opus-5-5")

      conn = execute("off")
      assert conn.status == 200
      output = Jason.decode!(conn.resp_body)["output"]
      assert output =~ "can't be turned off"
    end
  end
end
