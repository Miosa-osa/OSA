defmodule OptimalSystemAgent.Providers.NullModelRequestTest do
  @moduledoc """
  A request must always be able to name its model.

  ## The defect

  `config/runtime.exs` sets every provider override from the environment
  (`xai_model: System.get_env("XAI_MODEL")`), so with the env var unset the key
  is **present with the value nil** — and `Application.get_env/3` substitutes
  its default only for an ABSENT key, never a present-and-nil one. The idiom
  every provider used,

      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :xai_model, default_model())

  therefore resolved to `nil`, and `OpenAICompat.do_chat/5` wrote that into the
  body as `"model": null`. MEASURED live on `grok-4.6`:

      HTTP 422: failed to deserialize the JSON body into the target type
      model: invalid type: null, expected a string at line 1, column 171659

  Turn requests never hit it — the Loop pins `state.model` and passes it as
  `opts[:model]`, short-circuiting the broken half of the `||`. Compaction
  always hit it: `Compactor.bounded_chat/2` is called with only
  `temperature:`/`max_tokens:`, so it is the one caller with no `:model` at
  all. That is why the symptom read as "compaction is broken" on both the
  `/compact` path and the automatic one.

  ## Why a test at this altitude

  This is the *third* instance of the same shape in this subsystem (a nil model
  disabling compaction on 37 of 40 sessions; `anthropic_prompt_cache?/2`
  requiring `is_binary(model)` against a `LLMClient` that only sets
  `opts[:model]` when `state.model` is set). Fixing instance number three at
  the call site would invite number four, so these assert the *class*: no
  configured-model lookup may return nil for an unset override, and no request
  may be built without a model — on any provider, from any entry point.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.ConfiguredModel
  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.OpenAICompatProvider

  # The providers whose `:<provider>_model` key `config/runtime.exs` sets from
  # `System.get_env/1` with no `config/config.exs` literal behind it. These are
  # exactly the ones that were exposed; `anthropic`/`openai`/`openrouter`/
  # `ollama` carry literals, which is why the same code was correct for them
  # and the defect stayed invisible until an exposed provider became default.
  @env_only_providers ~w(
    google deepseek mistral replicate cohere bedrock xai together fireworks
    perplexity qwen zhipu moonshot volcengine baichuan cerebras sambanova
    hyperbolic lmstudio llamacpp
  )a

  describe "ConfiguredModel.configured/1 — present-and-nil means ABSENT" do
    test "a key present with value nil resolves to nil, not to the nil itself" do
      # This is the exact state `runtime.exs` leaves behind for an unset env var.
      with_env(:xai_model, nil, fn ->
        assert {:ok, nil} = Application.fetch_env(:optimal_system_agent, :xai_model),
               "precondition: the key must be PRESENT and nil, not absent"

        assert ConfiguredModel.configured(:xai) == nil
      end)
    end

    test "blank and non-binary overrides are absent too" do
      for junk <- [nil, "", "   ", :grok, 42, []] do
        with_env(:xai_model, junk, fn ->
          assert ConfiguredModel.configured(:xai) == nil,
                 "#{inspect(junk)} is not a usable model name"
        end)
      end
    end

    test "a real override is honoured" do
      with_env(:xai_model, "grok-4.6-fast", fn ->
        assert ConfiguredModel.configured(:xai) == "grok-4.6-fast"
      end)
    end
  end

  describe "resolve/3 — the cascade never yields nil when a fallback exists" do
    test "regression: the exact call the compactor made on grok-4.6" do
      with_env(:xai_model, nil, fn ->
        # The old form. Kept literal so the test states the bug it prevents.
        old = Application.get_env(:optimal_system_agent, :xai_model, "grok-4.6")
        assert old == nil, "if this ever stops being nil, Elixir changed under us"

        # The new form.
        assert ConfiguredModel.resolve([], :xai, "grok-4.6") == "grok-4.6"
      end)
    end

    test "explicit opts win over the configured override" do
      with_env(:xai_model, "grok-4.5", fn ->
        assert ConfiguredModel.resolve([model: "grok-4.6"], :xai, "fb") == "grok-4.6"
      end)
    end

    test "a blank explicit opt falls through rather than winning" do
      with_env(:xai_model, nil, fn ->
        assert ConfiguredModel.resolve([model: nil], :xai, "grok-4.6") == "grok-4.6"
        assert ConfiguredModel.resolve([model: ""], :xai, "grok-4.6") == "grok-4.6"
      end)
    end

    test "the fallback may be a thunk and is only forced when needed" do
      with_env(:xai_model, "configured", fn ->
        assert ConfiguredModel.resolve([], :xai, fn -> raise "must not be forced" end) ==
                 "configured"
      end)
    end
  end

  describe "every routed provider resolves a model with nothing configured" do
    test "default_model/1 is non-empty for all of them, override unset" do
      for provider <- @env_only_providers,
          provider in OpenAICompatProvider.providers() do
        with_env(:"#{provider}_model", nil, fn ->
          model = OpenAICompatProvider.default_model(provider)

          assert is_binary(model) and model != "",
                 "#{provider} resolves no model with its override unset — " <>
                   "that is the null-model 422 waiting to happen"
        end)
      end
    end

    test "resolve/3 against each provider's own config never yields nil" do
      for provider <- OpenAICompatProvider.providers() do
        with_env(:"#{provider}_model", nil, fn ->
          fallback = OpenAICompatProvider.default_model(provider)
          resolved = ConfiguredModel.resolve([], provider, fallback)

          assert is_binary(resolved) and resolved != "",
                 "#{provider} would send model: null"
        end)
      end
    end
  end

  describe "ensure/2 — the loud gate" do
    test "refuses nil and names the provider and the env var that fixes it" do
      assert {:error, message} = ConfiguredModel.ensure(nil, :xai)
      assert message =~ "xai"
      assert message =~ "XAI_MODEL"
      assert message =~ "null model"
    end

    test "refuses blank and non-binary" do
      for junk <- [nil, "", "  ", :atom, 7] do
        assert {:error, _} = ConfiguredModel.ensure(junk, :xai), "accepted #{inspect(junk)}"
      end
    end

    test "passes a usable name through unchanged" do
      assert {:ok, "grok-4.6"} = ConfiguredModel.ensure("grok-4.6", :xai)
    end
  end

  describe "the wire refuses a null model instead of paying for the round-trip" do
    test "OpenAICompat.chat/5 errors before any HTTP call" do
      assert {:error, message} =
               OpenAICompat.chat(
                 "http://127.0.0.1:1/v1",
                 "sk-test",
                 nil,
                 [%{role: "user", content: "hi"}],
                 provider: :xai
               )

      assert message =~ "no model resolved"
      assert message =~ "XAI_MODEL"
    end

    test "OpenAICompat.chat_stream/6 errors before any HTTP call" do
      assert {:error, message} =
               OpenAICompat.chat_stream(
                 "http://127.0.0.1:1/v1",
                 "sk-test",
                 nil,
                 [%{role: "user", content: "hi"}],
                 fn _ -> :ok end,
                 provider: :xai
               )

      assert message =~ "no model resolved"
    end

    test "the refusal beats the missing-API-key check, so it is never masked" do
      # An unreachable URL and no key: if the model gate did not run first this
      # would report "API key not configured" and the real defect would stay
      # invisible behind a second, wrong diagnosis.
      assert {:error, message} =
               OpenAICompat.chat("http://127.0.0.1:1/v1", nil, nil, [], provider: :xai)

      assert message =~ "no model resolved"
    end
  end

  # `Application.put_env` with an explicit nil is what reproduces the runtime
  # state; `delete_env` would make the key absent, which is the case that
  # always worked.
  defp with_env(key, value, fun) do
    had = Application.fetch_env(:optimal_system_agent, key)
    Application.put_env(:optimal_system_agent, key, value)

    try do
      fun.()
    after
      case had do
        {:ok, prev} -> Application.put_env(:optimal_system_agent, key, prev)
        :error -> Application.delete_env(:optimal_system_agent, key)
      end
    end
  end
end
