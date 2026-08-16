defmodule OptimalSystemAgent.Providers.ModelRetirementTest do
  @moduledoc """
  A retired model in the picker is worse than a missing one.

  A missing model is a visible gap. A retired one *resolves*: it appears in the
  `/model` dialog and in `osa setup`, the user selects it, OSA writes it to
  config — and then every single request 404s at the vendor. The failure lands
  on the user's next turn, long after the choice that caused it.

  Two ways that happened here, both covered below:

    1. A retired id sitting in `AnthropicModels.@models` itself.
    2. A retired id arriving from `Providers.Catalog`. The bundled
       `priv/catalog/models_dev.json` is a third-party snapshot on its own
       release cadence; it listed `claude-3-5-sonnet-20241022`, retired
       2025-10-28, and no Claude 5 model at all. Because
       `Onboarding.model_list/1` prefers the Catalog over
       `AnthropicModels.picker_models/0`, that snapshot — not the single source
       of truth — was what the picker actually offered.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Tier

  alias OptimalSystemAgent.Providers.{
    AnthropicModels,
    Catalog,
    DeepSeekModels,
    GoogleModels,
    MistralModels,
    OpenAICompatProvider,
    OpenAIModels,
    Retirements,
    XAIModels
  }

  # Every provider surface that can put a model id in front of a user. The
  # Anthropic-only guard below missed all of these, and all of them had rotted:
  # Google's default was shut down 2026-06-01, DeepSeek's default and both
  # reasoning tiers were retired 2026-07-24, Cohere's three tiers died
  # 2025-09-15, and Groq's Llamas die 2026-08-16.
  @tiered_providers [:google, :deepseek, :mistral, :cohere, :groq, :fireworks, :replicate]

  describe "cross-provider retirement schedule" do
    test "no model offered by any provider catalog is already retired" do
      today = Date.utc_today()

      for {mod, label} <- [
            {GoogleModels, "google"},
            {DeepSeekModels, "deepseek"},
            {XAIModels, "xai"},
            {MistralModels, "mistral"}
          ],
          id <- mod.ids() do
        refute Retirements.retired?(id, today),
               "#{label} offers #{id}, retired #{Retirements.retirement_date(id)} — requests to it fail"
      end
    end

    test "no model offered by any provider catalog retires within 90 days" do
      # The rule that matters: a model dying in ten weeks is not a safe fresh
      # pick. Google's gemini-2.5-* (2026-10-16) and Groq's Llamas (2026-08-16)
      # both trip this, which is exactly why they are no longer offered.
      for {mod, label} <- [
            {GoogleModels, "google"},
            {DeepSeekModels, "deepseek"},
            {XAIModels, "xai"},
            {MistralModels, "mistral"}
          ],
          m <- mod.ids() do
        refute Retirements.retiring_soon?(m),
               "#{label} offers #{m}, which retires #{Retirements.retirement_date(m)} — too soon"
      end
    end

    test "no tier default on any provider is retired or retiring within 90 days" do
      for provider <- @tiered_providers,
          tier <- [:elite, :specialist, :utility] do
        model = Tier.model_for(tier, provider)

        refute Retirements.retiring_soon?(model),
               "#{provider}/#{tier} = #{model}, retiring #{Retirements.retirement_date(model)}"
      end
    end

    test "no OpenAI-compatible provider default is retired or retiring within 90 days" do
      for provider <- OpenAICompatProvider.providers(),
          model <- OpenAICompatProvider.available_models(provider) do
        refute Retirements.retiring_soon?(model),
               "#{provider} offers #{model}, retiring #{Retirements.retirement_date(model)}"
      end
    end

    test "the concrete ids that were broken are all recorded as retired" do
      # Regression pins — each of these was live in OSA's config on 2026-08-01.
      for id <- [
            "gemini-2.0-flash",
            "deepseek-chat",
            "deepseek-reasoner",
            "grok-3",
            "command-r-plus",
            "mixtral-8x7b-32768",
            "llama-3.3-70b"
          ] do
        assert Retirements.retired?(id), "#{id} must be recorded as retired"
      end
    end

    test "the guard catches a model on both sides of its retirement date" do
      # Asserted against a FIXED date, not `Date.utc_today()`. The earlier
      # version of this test read the wall clock and asserted Groq's Llamas were
      # "still live today" — true when written, false on 2026-08-16, which is
      # their retirement date. It then failed for being right about the world.
      #
      # A test that expires is the same defect this suite exists to catch: an
      # assertion that agrees with you until the world moves under it. What is
      # worth pinning is the *mechanism* — that `retired?/2` flips at the date
      # and `retiring_soon?/2` warns before it — and neither of those depends on
      # when the suite runs.
      llama = "llama-3.3-70b-versatile"
      retires_on = Retirements.retirement_date(llama)

      day_before = Date.add(retires_on, -1)

      refute Retirements.retired?(llama, day_before),
             "must still be live the day before its retirement date"

      assert Retirements.retired?(llama, retires_on),
             "must be retired ON the date, not the day after"

      assert Retirements.retired?(llama, Date.add(retires_on, 1))

      # The forward-looking guard is what gives an operator warning, and it is
      # the half that has to work while the model still serves traffic.
      assert Retirements.retiring_soon?(llama)
      assert Retirements.retiring_soon?("llama-3.1-8b-instant")
      assert Retirements.retiring_soon?("gemini-2.5-pro")
      assert Retirements.retiring_soon?("gemini-2.5-flash")
    end

    test "a live dated model is not condemned by its retired undated alias" do
      # `command-r` was shut down 2025-09-15; `command-r-08-2024` still serves.
      # A naive bidirectional prefix match would kill the good one.
      assert Retirements.retired?("command-r")
      refute Retirements.retired?("command-r-08-2024")
    end

    test "retired?/2 is false for unknown ids rather than raising" do
      refute Retirements.retired?("some-model-nobody-has-heard-of")
      refute Retirements.retired?(nil)
      assert Retirements.retirement_date(nil) == nil
    end

    test "Retirements.retirement_date/1 also answers for Anthropic" do
      # One function for every provider, so a caller never has to know which
      # catalog owns a model.
      assert Retirements.retirement_date("claude-3-5-sonnet-20241022") == ~D[2025-10-28]
    end
  end

  describe "retirement schedule" do
    test "no offered Anthropic model is past its retirement date" do
      today = Date.utc_today()

      for m <- AnthropicModels.models() do
        refute AnthropicModels.retired?(m.id, today),
               "#{m.id} retired on #{AnthropicModels.retirement_date(m.id)} — requests to it 404"
      end
    end

    test "no offered Anthropic model retires within 90 days" do
      # A model that is about to be sunset should not be a fresh pick: the user
      # would choose it today and break in weeks.
      soon = Date.add(Date.utc_today(), 90)

      for m <- AnthropicModels.picker_models() do
        refute AnthropicModels.retired?(m.id, soon),
               "#{m.id} retires #{AnthropicModels.retirement_date(m.id)} — too soon to offer"
      end
    end

    test "retirement_date resolves both the alias and the dated snapshot id" do
      assert AnthropicModels.retirement_date("claude-opus-4-1") == ~D[2026-08-05]
      assert AnthropicModels.retirement_date("claude-opus-4-1-20250805") == ~D[2026-08-05]
      assert AnthropicModels.retirement_date("claude-3-5-sonnet-20241022") == ~D[2025-10-28]
    end

    test "a current model has no announced retirement" do
      assert AnthropicModels.retirement_date("claude-opus-5") == nil
      assert AnthropicModels.retirement_date("claude-sonnet-5") == nil
      assert AnthropicModels.retirement_date(nil) == nil
    end

    test "retired?/2 is false for unknown ids rather than raising" do
      refute AnthropicModels.retired?("some-model-nobody-has-heard-of")
      refute AnthropicModels.retired?(nil)
    end
  end

  describe "Catalog SoT overlay" do
    # `apply_sot_overlay/1` runs on EVERY catalog source — network, cache,
    # bundled file and baked snapshot — so a stale third-party artifact can
    # never reintroduce a retired id or hide a current one.

    test "overlay replaces a stale Anthropic section wholesale" do
      stale = %{
        "anthropic" => %{
          "id" => "anthropic",
          "name" => "Anthropic",
          "models" => %{
            # Retired 2025-10-28.
            "claude-3-5-sonnet-20241022" => %{
              "name" => "Claude 3.5 Sonnet",
              "limit" => %{"context" => 200_000, "output" => 8_192}
            }
          }
        }
      }

      models = stale |> Catalog.apply_sot_overlay() |> get_in(["anthropic", "models"])

      refute Map.has_key?(models, "claude-3-5-sonnet-20241022"),
             "a retired id must be REPLACED out, not merged around"

      assert Map.has_key?(models, "claude-opus-5")
      assert Enum.sort(Map.keys(models)) == Enum.sort(AnthropicModels.ids())
    end

    test "overlay replaces a stale OpenAI section wholesale" do
      stale = %{
        "openai" => %{
          "id" => "openai",
          "name" => "OpenAI",
          "models" => %{
            "gpt-4.1" => %{"name" => "GPT-4.1", "limit" => %{"context" => 1_047_576}}
          }
        }
      }

      models = stale |> Catalog.apply_sot_overlay() |> get_in(["openai", "models"])

      refute Map.has_key?(models, "gpt-4.1")
      assert Map.has_key?(models, "gpt-5.6-terra")
      assert Enum.sort(Map.keys(models)) == Enum.sort(OpenAIModels.ids())
    end

    test "overlay carries the SoT context window and output cap, not the snapshot's" do
      # The concrete drift this guards: the snapshot budgeted Sonnet 4.6 at
      # 200K when it is 1M, so every turn was budgeted against a wrong number.
      stale = %{
        "anthropic" => %{
          "models" => %{
            "claude-sonnet-4-6" => %{
              "name" => "Claude Sonnet 4.6",
              "limit" => %{"context" => 200_000, "output" => 8_192}
            }
          }
        }
      }

      limit =
        stale
        |> Catalog.apply_sot_overlay()
        |> get_in(["anthropic", "models", "claude-sonnet-4-6", "limit"])

      assert limit == %{"context" => 1_000_000, "output" => 128_000}
    end

    test "overlay creates the section when a source omits the provider entirely" do
      overlaid = Catalog.apply_sot_overlay(%{"groq" => %{"models" => %{}}})

      assert get_in(overlaid, ["anthropic", "models", "claude-opus-5"])
      assert get_in(overlaid, ["openai", "models", "gpt-5.6-terra"])
      # Unrelated providers pass through untouched.
      assert Map.has_key?(overlaid, "groq")
    end

    test "overlay preserves non-model provider metadata" do
      overlaid =
        Catalog.apply_sot_overlay(%{
          "anthropic" => %{"id" => "anthropic", "name" => "Anthropic", "doc" => "https://x"}
        })

      assert get_in(overlaid, ["anthropic", "doc"]) == "https://x"
    end

    test "overlay is idempotent" do
      once = Catalog.apply_sot_overlay(%{})
      assert Catalog.apply_sot_overlay(once) == once
    end
  end

  describe "the live Catalog offers no retired model" do
    test "Catalog.models(:anthropic) contains the current flagship and no retired id" do
      ids = Catalog.models("anthropic") |> Enum.map(& &1.model_id)

      assert "claude-opus-5" in ids, "the flagship must be offerable"

      for id <- ids do
        refute AnthropicModels.retired?(id), "Catalog offers retired #{id}"
      end
    end

    test "Catalog.models(:openai) contains the current default" do
      ids = Catalog.models("openai") |> Enum.map(& &1.model_id)
      assert OpenAIModels.default_model() in ids
    end
  end
end
