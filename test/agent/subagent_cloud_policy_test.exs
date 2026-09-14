defmodule OptimalSystemAgent.Agent.SubagentCloudPolicyTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.{DelegationRouter, RunStore, SubagentCloudPolicy}
  alias OptimalSystemAgent.Providers.{FallbackChain, Registry}

  setup do
    keys = [:subagent_cloud_only, :ollama_model, :fallback_chain, :openai_url]
    saved = Map.new(keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})
    Application.put_env(:optimal_system_agent, :subagent_cloud_only, true)
    Application.put_env(:optimal_system_agent, :ollama_model, "qwen38-mythos:latest")
    Application.put_env(:optimal_system_agent, :fallback_chain, [:ollama])
    Application.delete_env(:optimal_system_agent, :openai_url)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:optimal_system_agent, key, value)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    :ok
  end

  @tag :routing_red
  test "explicit local model cannot override the operator policy" do
    routed =
      DelegationRouter.resolve("Review a function", %{
        provider: :ollama,
        model: "qwen38-mythos:latest"
      })

    assert routed[:routing_error] =~ "cloud-only"
  end

  @tag :routing_red
  test "candidate selection skips a local first choice even for loose priority" do
    routed =
      DelegationRouter.resolve("Review a function", %{provider: :ollama, priority: :loose},
        candidates: [:ollama, :openai],
        configured?: fn _ -> true end,
        model_for: fn
          _, :ollama -> "qwen38-mythos:latest"
          _, :openai -> "gpt-5"
        end,
        tool_call: fn _, _ -> true end,
        context_window: fn _ -> 200_000 end
      )

    assert routed.provider == :openai
  end

  test "allows official cloud routes and both Ollama cloud tag styles" do
    for {provider, model} <- [
          {:ollama, "glm-5.3:cloud"},
          {:ollama_cloud, "deepseek-v4.1-flash:cloud"},
          {:ollama, "qwen3-coder:480b-cloud"},
          {:openai, "gpt-5"}
        ] do
      assert :ok = SubagentCloudPolicy.check(provider, model)
    end

    for {provider, model} <- [
          {:ollama, "local:latest"},
          {:ollama_cloud, "local:latest"},
          {:lmstudio, "glm:cloud"},
          {:llamacpp, "local"},
          {:unknown, "cloud"},
          {:openai, nil},
          {"ollama", "local:latest"}
        ] do
      assert {:error, _} = SubagentCloudPolicy.check(provider, model)
    end
  end

  test "cloud-labelled compat provider cannot redirect to a local endpoint" do
    Application.put_env(:optimal_system_agent, :openai_url, "http://127.0.0.1:1234/v1")
    assert {:error, _} = SubagentCloudPolicy.check(:openai, "gpt-5")
  end

  test "no permitted candidate returns a routing error" do
    routed =
      DelegationRouter.resolve("Review a function", %{provider: :ollama},
        candidates: [:ollama],
        configured?: fn _ -> true end,
        model_for: fn _, _ -> "local:latest" end,
        tool_call: fn _, _ -> true end,
        context_window: fn _ -> 200_000 end
      )

    assert routed[:routing_error] =~ "cloud-only"
  end

  test "manual top-level requests and default-off installations remain unrestricted" do
    assert :ok = SubagentCloudPolicy.check_request(:ollama, "local:latest", session_id: "manual")
    Application.put_env(:optimal_system_agent, :subagent_cloud_only, false)
    assert :ok = SubagentCloudPolicy.check(:ollama, "local:latest")
    routed = DelegationRouter.resolve("Review", %{provider: :ollama, model: "local:latest"})
    refute Map.has_key?(routed, :routing_error)
  end

  test "delegated sync and streaming requests reject before any transport executes" do
    opts = [provider: :ollama, model: "local:latest", delegated_agent: true]
    assert {:error, reason} = Registry.chat([], opts)
    assert reason =~ "cloud-only"

    assert {:error, reason} =
             Registry.chat_stream([], fn _ -> flunk("transport callback must not run") end, opts)

    assert reason =~ "cloud-only"
  end

  test "model-dropping fallback hops preserve the delegation marker and block local defaults" do
    opts = [model: "gpt-5", delegated_agent: true]
    hop = Registry.cross_provider_opts(opts)
    assert hop[:delegated_agent]
    refute Keyword.has_key?(hop, :model)
    assert {:error, reason} = Registry.chat_with_fallback([], [:ollama], hop)
    assert reason =~ "cloud-only"

    assert {:error, reason} =
             FallbackChain.chat_stream_with_fallback(
               [],
               fn _ -> flunk("no local fallback") end,
               Keyword.put(hop, :provider, :ollama)
             )

    assert inspect(reason) =~ "cloud-only"
  end

  test "run metadata protects nested and resumed helper requests without a caller flag" do
    id = "cloud-policy-#{System.unique_integer([:positive])}"

    RunStore.start_run(%{
      agent_id: id,
      parent_session_id: "parent-child",
      role: "test",
      task: "fixture"
    })

    assert {:error, reason} =
             SubagentCloudPolicy.check_request(:ollama, "local:latest",
               session_id: id,
               delegated_agent: false
             )

    assert reason =~ "cloud-only"
  end

  test "direct and background orchestrator entry rejects before creating a child" do
    config = %{
      task: "fixture",
      parent_session_id: "cloud-parent",
      provider: :ollama,
      model: "local:latest"
    }

    assert {:error, {:no_capable_model, reason}} =
             OptimalSystemAgent.Orchestrator.run_subagent(config)

    assert reason =~ "cloud-only"

    assert {:error, {:no_capable_model, reason}} =
             OptimalSystemAgent.Orchestrator.run_background("cloud-parent", config)

    assert reason =~ "cloud-only"
  end

  test "policy rejection does not poison the provider circuit for manual sessions" do
    before = OptimalSystemAgent.Providers.HealthChecker.state()

    for _ <- 1..4 do
      assert {:error, _} =
               Registry.chat([], provider: :ollama, model: "local:latest", delegated_agent: true)
    end

    assert OptimalSystemAgent.Providers.HealthChecker.state() == before
  end

  test "both loop inference paths propagate child policy without caller flags" do
    state = %{
      provider: :ollama,
      model: "local:latest",
      session_id: "policy-loop",
      parent_session_id: "parent"
    }

    assert {:error, reason} = OptimalSystemAgent.Agent.Loop.LLMClient.llm_chat(state, [], [])
    assert inspect(reason) =~ "cloud-only"

    assert {:error, reason} =
             OptimalSystemAgent.Agent.Loop.LLMClient.llm_chat_stream(state, [], [])

    assert inspect(reason) =~ "cloud-only"
  end

  test "child request marker cannot be erased by caller options" do
    opts =
      SubagentCloudPolicy.request_opts([delegated_agent: false], %{parent_session_id: "parent"})

    assert opts[:delegated_agent]
    assert {:error, _} = SubagentCloudPolicy.check_request(:ollama, "local:latest", opts)
  end

  test "explicit stop fence blocks direct and background launches before registration" do
    root = "cloud-stop-parent-#{System.unique_integer([:positive])}"
    :ets.insert(:osa_cancel_flags, {{:all_work_stopped, root}, true})
    on_exit(fn -> :ets.delete(:osa_cancel_flags, {:all_work_stopped, root}) end)

    config = %{
      task: "fixture",
      parent_session_id: root,
      provider: :ollama,
      model: "glm-5.3:cloud"
    }

    assert {:error, :cancelled} = OptimalSystemAgent.Orchestrator.run_subagent(config)
    assert {:error, :cancelled} = OptimalSystemAgent.Orchestrator.run_background(root, config)
    refute Enum.any?(RunStore.list(limit: 100_000), &(&1.parent_session_id == root))
  end

  test "work admitted before STOP stays rejected after a new turn clears the fence" do
    root = "cloud-stop-ticket-#{System.unique_integer([:positive])}"
    old_ticket = OptimalSystemAgent.Agent.Cancellation.all_work_ticket(root)
    :ets.insert(:osa_cancel_flags, {{:all_work_epoch, root}, 1})
    on_exit(fn -> :ets.delete(:osa_cancel_flags, {:all_work_epoch, root}) end)

    config = %{
      task: "fixture",
      parent_session_id: root,
      provider: :ollama,
      model: "glm-5.3:cloud",
      stop_ticket: old_ticket
    }

    assert {:error, :cancelled} = OptimalSystemAgent.Orchestrator.run_subagent(config)
    assert {:error, :cancelled} = OptimalSystemAgent.Orchestrator.run_background(root, config)
    refute Enum.any?(RunStore.list(limit: 100_000), &(&1.parent_session_id == root))
  end
end
