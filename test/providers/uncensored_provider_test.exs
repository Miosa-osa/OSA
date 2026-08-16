defmodule OptimalSystemAgent.Providers.UncensoredProviderTest do
  @moduledoc """
  Locks in the `uncensored` provider wiring.

  The interesting property is the auth header. api.uncensored.com reads
  `x-api-key` and ignores `Authorization: Bearer` — and it ignores it
  *silently*, answering a Bearer-authenticated call exactly as it answers an
  unauthenticated one. A regression here would therefore not look like an auth
  bug, it would look like the user's key being invalid, so it is worth a test.

  The second property, and the more expensive one to get wrong, is PRICE. This
  gateway resells other vendors' models under the vendors' own ids, so the id
  alone does not name a rate — see `Providers.UncensoredModels`.

  > #### Nothing here has spoken to the gateway {: .warning}
  >
  > There are no `api.uncensored.com` credentials on this machine. Every test
  > below asserts what OSA builds and what OSA bills. No request has been sent
  > and no invoice has been reconciled against these rates.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.OpenAICompatProvider
  alias OptimalSystemAgent.Providers.Registry
  alias OptimalSystemAgent.Providers.Retirements
  alias OptimalSystemAgent.Providers.UncensoredModels
  alias OptimalSystemAgent.Runtime.SessionManager

  describe "build_headers/2 auth style" do
    test "defaults to the OpenAI Bearer convention" do
      headers = OpenAICompat.build_headers("sk-abc", [])

      assert {"Authorization", "Bearer sk-abc"} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "x-api-key" end)
    end

    test "an unknown auth style falls back to Bearer rather than sending nothing" do
      headers = OpenAICompat.build_headers("sk-abc", auth_style: :something_new)

      assert {"Authorization", "Bearer sk-abc"} in headers
    end

    test ":x_api_key sends x-api-key and no Authorization header at all" do
      headers = OpenAICompat.build_headers("sk-abc", auth_style: :x_api_key)

      assert {"x-api-key", "sk-abc"} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
    end

    test "content-type and extra_headers survive both auth styles" do
      for style <- [:bearer, :x_api_key] do
        headers =
          OpenAICompat.build_headers("sk-abc",
            auth_style: style,
            extra_headers: [{"X-Title", "OSA"}]
          )

        assert {"Content-Type", "application/json"} in headers
        assert {"X-Title", "OSA"} in headers
      end
    end
  end

  describe "provider config" do
    test "uncensored is registered and routes through the compat provider" do
      assert :uncensored in Registry.list_providers()
      assert :uncensored in OpenAICompatProvider.providers()
    end

    test "carries the x-api-key auth style and the /api/v1 base URL" do
      assert OpenAICompatProvider.auth_style(:uncensored) == :x_api_key
      assert OpenAICompatProvider.base_url(:uncensored) == "https://api.uncensored.com/api/v1"
    end

    test "the default model is one of the advertised models" do
      assert OpenAICompatProvider.default_model(:uncensored) in OpenAICompatProvider.available_models(
               :uncensored
             )
    end

    test "no other compat provider was switched off Bearer by this change" do
      for provider <- OpenAICompatProvider.providers(), provider != :uncensored do
        assert OpenAICompatProvider.auth_style(provider) == :bearer,
               "#{provider} unexpectedly changed auth style"
      end
    end

    test "every model the picker offers is one the rate card can price" do
      offered = MapSet.new(OpenAICompatProvider.available_models(:uncensored))
      priced = MapSet.new(UncensoredModels.gateway_ids())

      assert MapSet.subset?(offered, priced),
             "the picker and the rate card have drifted: " <>
               "#{inspect(MapSet.to_list(MapSet.difference(offered, priced)))} offered but " <>
               "unpriced. An offered-but-unpriced model bills at the upstream VENDOR's rate, " <>
               "which is the defect the namespaced catalog exists to prevent."
    end

    # The picker is the rate card minus retirements, and nothing else. A model
    # that fell off the picker for any OTHER reason is a drift the subset check
    # above cannot see.
    test "the only models priced but not offered are the ones near retirement" do
      offered = MapSet.new(OpenAICompatProvider.available_models(:uncensored))

      withheld = MapSet.difference(MapSet.new(UncensoredModels.gateway_ids()), offered)

      for id <- withheld do
        assert Retirements.retiring_soon?(id),
               "#{id} is priced but not offered, and is not near retirement — " <>
                 "the picker and the rate card have drifted for some other reason"
      end
    end

    test "the default model is not itself near retirement" do
      default = OpenAICompatProvider.default_model(:uncensored)

      refute Retirements.retiring_soon?(default),
             "#{default} is the default pick and retires " <>
               "#{Retirements.retirement_date(default)}"

      assert default in OpenAICompatProvider.available_models(:uncensored)
    end
  end

  describe "a reseller's price is not its upstream's price" do
    # The gateway relists vendor ids and charges its own margin. Pricing is
    # keyed by model id, so before `UncensoredModels` every one of these billed
    # the vendor's number at `:exact`. Rates are the gateway's own published
    # figures (GET /api/v1/models, 2026-08-16).
    @collisions [
      {"claude-opus-5", {5.0, 25.0}, {6.0, 30.0}},
      {"glm-5.2", {1.4, 4.4}, {1.68, 5.28}},
      {"deepseek-v4-pro", {0.435, 0.87}, {1.84, 3.66}}
    ]

    test "the same id prices differently on the gateway than on the vendor" do
      for {id, vendor_rate, gateway_rate} <- @collisions do
        assert Pricing.rates(id) == vendor_rate,
               "#{id}: the VENDOR's own rate moved — this test's premise is stale"

        qualified = Pricing.qualify(id, :uncensored)

        assert Pricing.rates(qualified) == gateway_rate,
               "#{id}: billed #{inspect(Pricing.rates(qualified))} on the gateway, which " <>
                 "charges #{inspect(gateway_rate)}"

        assert Pricing.confidence(qualified) == :exact,
               "#{id}: the gateway publishes this rate — it is not a guess"

        refute vendor_rate == gateway_rate,
               "#{id}: the two agree, so this row proves nothing — pick a colliding id " <>
                 "whose prices actually differ"
      end
    end

    test "qualifying for the gateway does not move the vendor's own price" do
      for {id, vendor_rate, _gateway} <- @collisions do
        assert Pricing.rates(id) == vendor_rate
        assert Pricing.confidence(id) == :exact
      end
    end

    test "qualify/2 is identity for every provider that is not a reseller" do
      for provider <- [:anthropic, :openai, :ollama, :xai, :zai, nil] do
        assert Pricing.qualify("claude-opus-5", provider) == "claude-opus-5"
      end

      assert Pricing.qualify(nil, :uncensored) == nil
    end

    # The hole the class ratchet found on its first run against this catalog:
    # `ZaiModels.resolve/1` strips a vendor prefix AND a routing suffix before
    # matching, so it read "uncensored/" as a vendor prefix and answered
    # `uncensored/glm-5.2:free` with Z.ai's own rate, at `:exact`.
    test "a routing suffix does not hand the turn back to the upstream vendor" do
      assert Pricing.rates("uncensored/glm-5.2:free") == {1.68, 5.28}
      assert Pricing.confidence("uncensored/glm-5.2:free") == :exact
    end

    # Same shape, one heuristic over: `ollama_local?/1` judges an id by SHAPE
    # and prices anything that looks locally hosted at {0.0, 0.0}, `:exact`.
    test "no model this gateway sells is mistaken for a free local one" do
      for id <- UncensoredModels.gateway_ids() do
        key = UncensoredModels.key(id)

        refute Pricing.rates(key) == {0.0, 0.0},
               "#{key} priced as a free local model — the gateway charges for it"
      end
    end

    test "the gateway's own cache-read column is what bills a cache read" do
      # It publishes one for 51 of its 82 models and it is not the flat 0.1x:
      # grok-4-6 reads at 0.25x input, qwen3-coder at 0.1x, glm-5.2 at 0.155x.
      assert Pricing.cache_read_rate("uncensored/grok-4-6") == {1.2, :published}
      assert Pricing.cache_read_confidence("uncensored/grok-4-6") == :published

      # And where it publishes none, the documented fallback stands and says so.
      assert Pricing.cache_read_confidence("uncensored/hermes-3-llama-3.1-405b") == :multiplier
    end

    # `Pricing.qualify/2` is only worth anything if billing actually calls it.
    # This is the wiring, and the wiring is what regresses.
    test "Accounting bills a gateway turn at the gateway's rate" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      norm = Accounting.normalize_usage(usage)

      on_vendor = Accounting.turn_cost(%{model: "claude-opus-5", provider: :anthropic}, norm, [])

      on_gateway =
        Accounting.turn_cost(%{model: "claude-opus-5", provider: :uncensored}, norm, [])

      assert_in_delta on_vendor, 30.0, 1.0e-6
      assert_in_delta on_gateway, 36.0, 1.0e-6

      assert on_gateway > on_vendor,
             "the gateway charges a margin over list; billing it at list under-states the bill"
    end
  end

  describe "/uncensored keeps its state per session" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :default_provider)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :default_provider, prev),
          else: Application.delete_env(:optimal_system_agent, :default_provider)
      end)

      :ok
    end

    defp live_session(tag) do
      id = "uncensored-#{tag}-#{System.unique_integer([:positive, :monotonic])}"
      :ok = SessionManager.track_session(id, %{user_id: "anonymous", channel: :cli})
      :ok = SessionManager.ensure_loop(id, user_id: "anonymous", channel: :cli)

      on_exit(fn ->
        SessionManager.cancel(id)
        SessionManager.untrack_session(id)
      end)

      id
    end

    # `dispatch/2` takes the command WITHOUT its leading slash — passing "/x"
    # dispatches "/x" and gets a did-you-mean.
    defp run("/" <> cmd, id), do: capture_io(fn -> Commands.dispatch(cmd, id) end)

    defp current(id) do
      case :ets.lookup(:osa_session_provider_overrides, id) do
        [{^id, provider, model}] -> {provider, model}
        _ -> nil
      end
    end

    # THE POINT. `:uncensored_previous` was a single node-global application
    # env key, so with two sessions on the gateway the first `/uncensored off`
    # consumed the only "previous" there was — and whichever session ran the
    # second `off` was told there was nothing to go back to, or worse, was
    # restored onto the OTHER session's model.
    test "two sessions each go back to their own model, not to each other's" do
      a = live_session("a")
      b = live_session("b")

      run("/model ollama alpha-model:8b", a)
      run("/model ollama beta-model:8b", b)

      assert current(a) == {:ollama, "alpha-model:8b"}
      assert current(b) == {:ollama, "beta-model:8b"}

      run("/uncensored claude-opus-5", a)
      run("/uncensored grok-4-6", b)

      assert current(a) == {:uncensored, "claude-opus-5"}
      assert current(b) == {:uncensored, "grok-4-6"}

      assert run("/uncensored off", a) =~ "alpha-model:8b"
      assert current(a) == {:ollama, "alpha-model:8b"}

      out = run("/uncensored off", b)

      assert current(b) == {:ollama, "beta-model:8b"},
             "session B was left on #{inspect(current(b))} — a's `off` consumed the only " <>
               "'previous' on the node. Output was: #{out}"
    end

    test "the origin is read from the session, not from the node default" do
      id = live_session("scoped")

      run("/model ollama session-own-model:8b", id)
      # The node default is something else entirely; a global read would return
      # THIS instead of the session's own model.
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

      run("/uncensored claude-opus-5", id)
      run("/uncensored off", id)

      assert current(id) == {:ollama, "session-own-model:8b"}
    end

    test "off with nothing to go back to says so and changes nothing" do
      id = live_session("virgin")
      run("/model ollama untouched:8b", id)

      assert run("/uncensored off", id) =~ "nothing to go back to"
      assert current(id) == {:ollama, "untouched:8b"}
    end

    test "no node-global previous survives anywhere" do
      refute Application.get_env(:optimal_system_agent, :uncensored_previous),
             "a node-global 'previous' is back — it is one session's history in a " <>
               "node-wide box"
    end
  end
end
