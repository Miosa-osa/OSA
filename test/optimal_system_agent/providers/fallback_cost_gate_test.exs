defmodule OptimalSystemAgent.Providers.FallbackCostGateTest do
  @moduledoc """
  A silent fallback must not be a silent purchase.

  `@default_chain` is `[:anthropic, :openai, :groq, :ollama]` — three metered
  providers ahead of the one free one — and `chain/0` hands that back whenever
  the user has configured nothing. The moduledoc promised the chain "falls back
  silently — the agent continues working without interruption", and there was
  no cost predicate anywhere in the module. A user running `:ollama` locally
  because they want nothing billed and nothing leaving the machine was moved
  onto Anthropic by the first 5xx, purely because an `ANTHROPIC_API_KEY` was
  exported in their environment.

  The gate is narrow on purpose: it fires only where the user made no choice.
  An explicitly configured `:fallback_chain` is still honoured — but the first
  paid hop from a free primary announces itself.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.FallbackChain

  @builtin [:anthropic, :openai, :groq, :ollama]

  setup do
    prev_chain = Application.fetch_env(:optimal_system_agent, :fallback_chain)
    prev_allow = Application.fetch_env(:optimal_system_agent, :fallback_allow_paid)
    Application.delete_env(:optimal_system_agent, :fallback_chain)
    Application.delete_env(:optimal_system_agent, :fallback_allow_paid)

    # `warn_once/2` is per-VM; clear it so warning assertions are not eaten by
    # a sibling test that ran first.
    for case_key <- [:paid_allowed, :paid_configured, :paid_blocked],
        primary <- [:ollama, :lmstudio, :anthropic] do
      :persistent_term.erase({FallbackChain, :warned, {case_key, primary}})
    end

    on_exit(fn ->
      restore(:fallback_chain, prev_chain)
      restore(:fallback_allow_paid, prev_allow)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:optimal_system_agent, key, v)
  defp restore(key, :error), do: Application.delete_env(:optimal_system_agent, key)

  describe "free primary, built-in (unchosen) chain" do
    test "metered providers are dropped" do
      permitted = FallbackChain.cost_gated_chain(@builtin -- [:ollama], :ollama)

      assert permitted == [],
             "the built-in chain is OSA's default, not the user's decision — it must not " <>
               "spend their money: #{inspect(permitted)}"
    end

    test "a free hop is still permitted" do
      assert FallbackChain.cost_gated_chain([:lmstudio, :anthropic], :ollama) == [:lmstudio]
    end
  end

  describe "explicit opt-in" do
    test "config :fallback_allow_paid lets the built-in chain bill" do
      Application.put_env(:optimal_system_agent, :fallback_allow_paid, true)
      candidates = @builtin -- [:ollama]
      assert FallbackChain.cost_gated_chain(candidates, :ollama) == candidates
    end
  end

  describe "a chain the user actually configured" do
    test "is honoured as written" do
      Application.put_env(:optimal_system_agent, :fallback_chain, [:ollama, :anthropic])
      assert FallbackChain.cost_gated_chain([:anthropic], :ollama) == [:anthropic]
    end
  end

  describe "paid primary" do
    test "is unaffected — the user already chose to spend" do
      candidates = [:openai, :groq, :ollama]
      assert FallbackChain.cost_gated_chain(candidates, :anthropic) == candidates
    end
  end

  describe "the warning is one the user can actually see" do
    test "a blocked paid fallback emits a bus event, not only a log line" do
      test_pid = self()

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
          send(test_pid, {:bus, Map.get(payload, :data)})
        end)

      on_exit(fn -> OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref) end)

      # `warn_once/2` is per-VM by design. Clear it here, immediately before the
      # call, so nothing that ran earlier in this VM can swallow the emission
      # this test is about.
      :persistent_term.erase({FallbackChain, :warned, {:paid_blocked, :ollama}})

      FallbackChain.cost_gated_chain(@builtin -- [:ollama], :ollama)

      assert_receive {:bus, %{event: :provider_cost_warning, message: message}}, 2_000
      assert message =~ "fallback_allow_paid"
    end
  end

  describe "free?/1" do
    test "ollama_cloud is not free — the prompt leaves the machine" do
      assert FallbackChain.free?(:ollama)
      assert FallbackChain.free?(:lmstudio)
      refute FallbackChain.free?(:ollama_cloud)
      refute FallbackChain.free?(:anthropic)
    end
  end
end
