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
    # Anthropic
    "claude-opus-4-6" => 64_000,
    "claude-sonnet-4-6" => 64_000,
    "claude-haiku-4-5" => 32_000,
    "claude-3-5-sonnet" => 8_192,
    "claude-3-5-haiku" => 8_192,
    "claude-3-opus" => 4_096,
    # OpenAI
    "gpt-4.1" => 32_768,
    "gpt-4o" => 16_384,
    "o3" => 100_000,
    "o4-mini" => 100_000,
    "o1" => 100_000,
    # Google
    "gemini-2.5-pro" => 65_536,
    "gemini-2.5-flash" => 65_536,
    "gemini-2.0-flash" => 8_192,
    # DeepSeek
    "deepseek-chat" => 8_192,
    "deepseek-reasoner" => 8_192,
    # Groq / Llama
    "llama-3.3-70b-versatile" => 32_768,
    "llama-3.1-8b-instant" => 8_192,
    # Mistral
    "mistral-large-latest" => 8_192,
    # zhipu / GLM
    "glm-5.2" => 128_000,
    "glm-4.6" => 128_000,
    "glm-4.5" => 96_000
  }

  @doc "Max output tokens for `model`, from the Catalog then a static table, or nil."
  @spec max_output(String.t() | nil) :: pos_integer() | nil
  def max_output(model) when is_binary(model) do
    catalog_max_output(model) || static_max_output(model)
  end

  def max_output(_), do: nil

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
      safe(fn -> Catalog.find(strip_tag(model)) end)
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
