defmodule OptimalSystemAgent.Agent.CompactionCarriesAModelTest do
  @moduledoc """
  Every compaction request names its model, on every entry point.

  ## What broke

  `Compactor.bounded_chat/2` is the single choke point for every provider call
  the compaction subsystem makes — `call_summary_llm/1`, `call_key_facts_llm/1`,
  `summarize_chunk/2`, and `Loop.ProactiveCompaction.summarize/2`. Its call
  sites pass `temperature:` and `max_tokens:` and nothing else, so compaction
  was the ONE request in the system that named no model and fell through to the
  provider's app-env fallback — which returns `nil`, not the default, because
  `:<provider>_model` is present-and-nil whenever its env var is unset (see
  `Providers.ConfiguredModel`).

  On xAI/`grok-4.6` that went out as `"model": null` and came back:

      HTTP 422: failed to deserialize the JSON body into the target type
      model: invalid type: null, expected a string at line 1, column 171659

  "compaction failed after 0 seconds, conversation unchanged."

  The cruel detail is that `Compactor.summarizer_model/1` had *always* resolved
  the right name — it was wired only into `Accounting.stage_side_spend/3`, so
  the compaction spend was priced against a model the request never carried.
  Billing and the wire disagreed, and only the wire was checked by the provider.

  ## Scope

  Both compaction entry points funnel through `bounded_chat/2`, so this failed
  identically for the manual `/compact` and for automatic threshold-triggered
  compaction. Any observation that "auto-compaction never fired" collected
  while this was live cannot distinguish "the threshold was never crossed" from
  "it fired and 422'd in under a second".
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Providers.ConfiguredModel
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    saved =
      for key <- [:default_provider, :mock_model, :xai_model, :compaction_summarizer_model],
          into: %{},
          do: {key, Application.fetch_env(:optimal_system_agent, key)}

    MockProvider.reset_last_opts()

    # `Registry.default_provider/0` consults OSA_DEFAULT_PROVIDER *before* the
    # app env, and it is set in the developer's own shell/`~/.osa/.env` — so
    # pinning only the app env let these tests dial the real Ollama.
    prev_env = System.get_env("OSA_DEFAULT_PROVIDER")
    System.put_env("OSA_DEFAULT_PROVIDER", "mock")

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, v}} -> Application.put_env(:optimal_system_agent, key, v)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)

      case prev_env do
        nil -> System.delete_env("OSA_DEFAULT_PROVIDER")
        v -> System.put_env("OSA_DEFAULT_PROVIDER", v)
      end
    end)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    :ok
  end

  defp compact_once(opts) do
    Compactor.bounded_chat([%{role: "user", content: "summarize this"}], opts)
    MockProvider.last_opts()
  end

  describe "the request the compaction subsystem actually sends" do
    test "carries a model string when the call site named none" do
      # Exactly how `call_summary_llm/1` calls it: no :model, no :provider.
      opts = compact_once(temperature: 0.2, max_tokens: 400)

      refute opts == nil, "the summarizer request never reached the provider"

      model = Keyword.get(opts, :model)

      assert is_binary(model) and model != "",
             "compaction sent model=#{inspect(model)} — this is the `\"model\": null` " <>
               "that xAI answered with HTTP 422 after 0 seconds"
    end

    test "regression: still carries one with the override present-and-nil" do
      # The precise runtime state behind the live failure: the key exists and
      # holds nil, which is what `System.get_env/1` leaves for an unset var.
      Application.put_env(:optimal_system_agent, :mock_model, nil)

      opts = compact_once(temperature: 0.2, max_tokens: 400)
      assert is_binary(Keyword.get(opts, :model))
    end

    test "an explicitly configured summarizer model is the one that goes out" do
      Application.put_env(:optimal_system_agent, :compaction_summarizer_model, "cheap-summarizer")

      opts = compact_once(model: "cheap-summarizer", temperature: 0.2, max_tokens: 400)
      assert Keyword.get(opts, :model) == "cheap-summarizer"
    end

    test "the model on the wire is the model compaction is billed for" do
      # These were computed by two different code paths and only one of them
      # was ever sent. They must now be the same value.
      opts = compact_once(temperature: 0.2, max_tokens: 400)
      sent = Keyword.get(opts, :model)

      assert is_binary(sent)

      assert sent ==
               ConfiguredModel.resolve(
                 opts,
                 Keyword.get(opts, :provider) || :mock,
                 sent
               )
    end

    test "the model survives the routing layer that strips :provider" do
      # `Registry.chat/2` consumes `:provider` to pick the module and deletes it
      # before dispatch, so its absence downstream is correct. `:model` must NOT
      # be consumed the same way — it has to reach the request body.
      opts = compact_once(temperature: 0.2, max_tokens: 400)

      assert Keyword.get(opts, :provider) == nil,
             "routing is expected to consume :provider"

      assert is_binary(Keyword.get(opts, :model)),
             ":model was consumed or never set — this is the null-model 422"
    end
  end

  describe "the class assertion" do
    test "no compaction opts shape reaches the provider without a model" do
      # The four shapes the compaction subsystem constructs across its call
      # sites. If a fifth is added and forgets the model, `bounded_chat/2` is
      # still the choke point that supplies it.
      shapes = [
        [temperature: 0.2, max_tokens: 400],
        [temperature: 0.1, max_tokens: 1024],
        [temperature: 0.1, max_tokens: 600],
        [temperature: 0.3, max_tokens: 2000, provider: :mock]
      ]

      for shape <- shapes do
        MockProvider.reset_last_opts()
        opts = compact_once(shape)

        assert is_binary(Keyword.get(opts || [], :model)),
               "opts #{inspect(shape)} reached the provider with no model"
      end
    end
  end
end
