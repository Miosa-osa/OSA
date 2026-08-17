defmodule OptimalSystemAgent.Providers.ModelLimits do
  @moduledoc """
  Per-model limit + capability resolution backed by `Providers.Catalog`
  (models.dev), with static fallbacks.

  A single place the provider modules consult so:

    * `num_predict` / `max_tokens` never exceed a model's REAL output ceiling
      (mirrors CC's `getModelMaxOutputTokens`, src/cost-tracker.ts), and
    * tool / reasoning gating prefers the Catalog's authoritative flags over the
      old name+size heuristics, falling back to those heuristics only when the
      Catalog has no entry for the model.

  Every lookup is best-effort — the Catalog reads a public ETS table and may be
  empty (offline / not-yet-loaded), so all functions degrade to `nil` (meaning
  "unknown — use your own fallback") rather than raising.
  """

  alias OptimalSystemAgent.Providers.Catalog

  # Static output ceilings — fallback when the Catalog has no entry (offline, or
  # a local model the catalog doesn't track). Values are the vendors' published
  # max output tokens. A prefix match applies when there's no exact key.
  @static_max_output %{
    # Anthropic / OpenAI current models are NOT listed here — they are merged in
    # below from Providers.AnthropicModels / Providers.OpenAIModels, which are
    # the single source of truth. Only older ids those catalogs no longer carry
    # are kept here.
    "claude-3-5-sonnet" => 8_192,
    "claude-3-5-haiku" => 8_192,
    "claude-3-opus" => 4_096,
    "gpt-4.1" => 32_768,
    "o4-mini" => 100_000,
    "o1" => 100_000,
    # Google, DeepSeek, xAI and Mistral are NOT listed here — they come from
    # their source-of-truth modules, merged in below.
    #
    # `deepseek-chat` / `deepseek-reasoner` (retired 2026-07-24) keep a row only
    # so an existing pinned config still clamps sanely while the user migrates.
    "deepseek-chat" => 8_192,
    "deepseek-reasoner" => 8_192,
    # Groq. Groq documents llama-3.1-8b-instant at 131,072 max completion
    # tokens, not the 8,192 recorded here previously.
    "openai/gpt-oss-120b" => 65_536,
    "openai/gpt-oss-20b" => 65_536,
    "llama-3.3-70b-versatile" => 32_768,
    "llama-3.1-8b-instant" => 131_072,
    # Cohere
    "command-a-plus-05-2026" => 64_000,
    "command-a-03-2025" => 8_000,
    "command-r-plus-08-2024" => 4_000,
    "command-r-08-2024" => 4_000,
    # Mistral has NO row. The 8_192 that used to sit here was never a Mistral
    # number — Mistral publishes no max output for any model, stating only that
    # prompt + max_tokens must fit the context window. A fabricated ceiling
    # silently truncated long answers, so the correct value is "unknown".
    # xAI likewise publishes no max output; its 128,000 `max_completion_tokens`
    # is a request DEFAULT, not a ceiling, and is not recorded as one.
    # zhipu / GLM
    "glm-5.2" => 128_000,
    "glm-4.6" => 128_000,
    "glm-4.5" => 96_000
  }

  @doc """
  Max output tokens for `model`, or `nil` when genuinely unknown.

  `nil` means "unknown — apply your own fallback", and callers such as
  `OpenAICompat.cap_max_output/2` treat it as "do not clamp". That is a real
  answer, not a failure: for xAI and Mistral it is the *correct* one.
  """
  @spec max_output(String.t() | nil) :: pos_integer() | nil
  def max_output(model) when is_binary(model) do
    cond do
      # Vendors that publish NO output ceiling at all. This must short-circuit
      # BEFORE the catalog: models.dev carries invented figures for both (the
      # 8,192 Mistral number OSA used to ship came from exactly that kind of
      # third-party guess), and a fabricated ceiling silently truncates long
      # answers. "Unknown" is the honest and safer result.
      unpublished_ceiling?(model) ->
        nil

      # The provider catalogs are the SINGLE SOURCE OF TRUTH for their own
      # models, so they are consulted BEFORE the bundled snapshot. That
      # snapshot is third-party data that lags: it still lists Haiku 4.5 at 32k
      # output when the published cap is 64k, and knows nothing about the
      # Claude 5 or GPT-5.6 families at all. Letting it win would silently
      # halve the output ceiling of a model we ship in the picker.
      true ->
        ssot_max_output(model) || catalog_max_output(model) || static_max_output(model)
    end
  end

  def max_output(_), do: nil

  defp unpublished_ceiling?(model) do
    OptimalSystemAgent.Providers.XAIModels.resolve(model) != nil or
      OptimalSystemAgent.Providers.MistralModels.resolve(model) != nil
  end

  # Every provider catalog that owns its own models, consulted before the
  # third-party snapshot. `Enum.find_value` stops at the first module that both
  # resolves the id AND carries an integer ceiling — so xAI and Mistral, whose
  # models resolve but whose `max_output` is deliberately nil (neither vendor
  # publishes one), correctly fall through to "unknown" rather than to a stale
  # catalog guess.
  @ssot_modules [
    OptimalSystemAgent.Providers.AnthropicModels,
    OptimalSystemAgent.Providers.OpenAIModels,
    OptimalSystemAgent.Providers.GoogleModels,
    OptimalSystemAgent.Providers.DeepSeekModels,
    # GLM. The `@static_max_output` rows below only ever covered three bare
    # ids, so `glm-5.2:cloud` — OSA's default — matched none of them and was
    # clamped by whatever fallback the caller happened to hold. `ZaiModels`
    # resolves the tagged and vendor-prefixed spellings too.
    OptimalSystemAgent.Providers.ZaiModels
  ]

  defp ssot_max_output(model) do
    Enum.find_value(@ssot_modules, fn mod ->
      case mod.resolve(model) do
        %{max_output: n} when is_integer(n) and n > 0 -> n
        _ -> nil
      end
    end)
  end

  defp catalog_max_output(model) do
    case safe(fn -> Catalog.max_output(model) end) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp static_max_output(model) do
    case Map.get(@static_max_output, model) do
      n when is_integer(n) ->
        n

      _ ->
        Enum.find_value(@static_max_output, fn {k, v} ->
          if String.starts_with?(model, k), do: v
        end)
    end
  end

  @doc """
  Authoritative tool-calling support for `model` on `provider`, or `nil` when the
  Catalog has no entry (callers then apply their own name/size heuristic).
  """
  @spec tool_call(atom() | String.t(), String.t()) :: boolean() | nil
  def tool_call(provider, model), do: flag(provider, model, :tool_call)

  @doc """
  Authoritative reasoning-model flag for `model` on `provider`, or `nil` when the
  Catalog has no entry (callers then apply their own name heuristic).
  """
  @spec reasoning(atom() | String.t(), String.t()) :: boolean() | nil
  def reasoning(provider, model), do: flag(provider, model, :reasoning)

  defp flag(provider, model, field) when is_binary(model) do
    case find_model(provider, model) do
      %Catalog.Model{} = m -> Map.get(m, field)
      _ -> nil
    end
  end

  defp flag(_provider, _model, _field), do: nil

  # Try the provider-scoped entry, then a cross-provider match on the exact id,
  # then a cross-provider match on the id with any ":tag" suffix stripped (so an
  # Ollama-cloud "glm-4.6:cloud" resolves to the catalog's "glm-4.6").
  defp find_model(provider, model) do
    safe(fn -> Catalog.model(to_string(provider), model) end) ||
      safe(fn -> Catalog.find(model) end) ||
      safe(fn -> find_gateway_model(model) end) ||
      safe(fn -> Catalog.find(strip_tag(model)) end)
  end

  # OpenRouter names models as `vendor/model`. models.dev stores the native
  # model id under that vendor, so an exact gateway id lookup often misses even
  # though the capability is known. Preserve both halves and perform a scoped
  # vendor lookup so equal native ids from different vendors cannot collide.
  defp find_gateway_model(model) do
    case String.split(model, "/", parts: 2) do
      [vendor, native_id] when vendor != "" and native_id != "" ->
        Catalog.model(vendor, native_id)

      _ ->
        nil
    end
  end

  defp strip_tag(model) do
    case String.split(model, ":", parts: 2) do
      [base, _tag] -> base
      _ -> model
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
