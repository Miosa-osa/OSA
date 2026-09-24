defmodule OptimalSystemAgent.Agent.Loop.AdvisorResolutionTest do
  @moduledoc """
  `Advisor.resolve_pair/1`'s auto-resolution order — "resolve one
  automatically from what the user can actually reach, in this order:
  claude-opus-5-5 if an Anthropic API key or the Claude subscription route
  is usable; else gpt-6-sol if an OpenAI key or the Codex route is usable;
  else the session's own strong model at high effort. Never error with
  `:advisor_not_configured` in the default path."

  `OSA_HOME` is redirected to an isolated temp dir for every test (same
  reasoning as `advisor_test.exs`'s setup): `Auth.SubscriptionStore` —
  `:claude_cli`/`:openai_codex`'s credential source — reads real disk state
  under it, and this suite must control that state precisely rather than
  inherit whatever the machine running it happens to have connected.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Advisor
  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    OptimalSystemAgent.Test.CredentialIsolation.isolate()

    prev = %{
      advisor_provider: Application.fetch_env(:optimal_system_agent, :advisor_provider),
      advisor_model: Application.fetch_env(:optimal_system_agent, :advisor_model),
      anthropic_api_key: Application.fetch_env(:optimal_system_agent, :anthropic_api_key),
      openai_api_key: Application.fetch_env(:optimal_system_agent, :openai_api_key)
    }

    prev_osa_home = System.get_env("OSA_HOME")

    tmp_home =
      Path.join(
        System.tmp_dir!(),
        "osa-advisor-resolution-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_home)
    System.put_env("OSA_HOME", tmp_home)

    Application.delete_env(:optimal_system_agent, :advisor_provider)
    Application.delete_env(:optimal_system_agent, :advisor_model)
    Application.delete_env(:optimal_system_agent, :anthropic_api_key)
    Application.delete_env(:optimal_system_agent, :openai_api_key)

    on_exit(fn ->
      for {key, val} <- prev do
        case val do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end

      if prev_osa_home,
        do: System.put_env("OSA_HOME", prev_osa_home),
        else: System.delete_env("OSA_HOME")

      File.rm_rf(tmp_home)
    end)

    :ok
  end

  defp connect(provider_id), do: SubscriptionStore.put(provider_id, %{"connected_at" => "test"})

  defp state(overrides \\ %{}), do: Map.merge(%{session_id: "advisor-resolution"}, overrides)

  describe "explicit configuration always wins" do
    test "an explicit pair is used even when auto-detected credentials are also present" do
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test")
      Application.put_env(:optimal_system_agent, :advisor_provider, :openai)
      Application.put_env(:optimal_system_agent, :advisor_model, "gpt-4o")

      assert Advisor.resolve_pair(state()) == {:openai, "gpt-4o", :configured}
    end
  end

  describe "tier 1 — Anthropic" do
    test "an Anthropic API key resolves to claude-opus-5-5 via :anthropic" do
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test")

      assert Advisor.resolve_pair(state()) == {:anthropic, "claude-opus-5-5", :anthropic_auto}
    end

    test "the Claude subscription route resolves to claude-opus-5-5 via :claude_cli" do
      connect("claude_cli")

      assert Advisor.resolve_pair(state()) == {:claude_cli, "claude-opus-5-5", :anthropic_auto}
    end

    test "a direct API key is preferred over the subscription route when both are usable" do
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test")
      connect("claude_cli")

      assert {:anthropic, "claude-opus-5-5", :anthropic_auto} = Advisor.resolve_pair(state())
    end

    test "Anthropic is checked before OpenAI even when both are usable" do
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test")
      Application.put_env(:optimal_system_agent, :openai_api_key, "sk-oai-test")

      assert {:anthropic, "claude-opus-5-5", :anthropic_auto} = Advisor.resolve_pair(state())
    end
  end

  describe "tier 2 — OpenAI, only once Anthropic is unusable" do
    test "an OpenAI API key resolves to gpt-6-sol via :openai" do
      Application.put_env(:optimal_system_agent, :openai_api_key, "sk-oai-test")

      assert Advisor.resolve_pair(state()) == {:openai, "gpt-6-sol", :openai_auto}
    end

    test "the Codex route resolves to gpt-6-sol via :openai_codex" do
      connect("openai_codex")

      assert Advisor.resolve_pair(state()) == {:openai_codex, "gpt-6-sol", :openai_auto}
    end

    test "a direct API key is preferred over the Codex route when both are usable" do
      Application.put_env(:optimal_system_agent, :openai_api_key, "sk-oai-test")
      connect("openai_codex")

      assert {:openai, "gpt-6-sol", :openai_auto} = Advisor.resolve_pair(state())
    end
  end

  describe "tier 3 — the session's own strong model" do
    test "falls back to the session's provider/model when nothing else is reachable" do
      assert Advisor.resolve_pair(state(%{provider: :ollama, model: "qwen3-next:80b"})) ==
               {:ollama, "qwen3-next:80b", :session_model_fallback}
    end

    test "resolve_pair/1 is NEVER nil as long as the session has a provider/model — no :advisor_not_configured in the default path" do
      refute is_nil(Advisor.resolve_pair(state(%{provider: :ollama, model: "local:latest"})))
    end
  end

  describe "the only genuinely unresolvable case" do
    test "nil when there is no configuration, no reachable credential, and no session model" do
      assert Advisor.resolve_pair(state()) == nil
    end
  end
end
