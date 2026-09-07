defmodule OptimalSystemAgent.Providers.SurplusModels do
  @moduledoc """
  Curated Surplus Intelligence models for the normal provider picker.

  Surplus exposes a larger, changing catalog at `/v1/models`. This list is
  intentionally only the editorial shortlist used for defaults, tiers, and
  offline fallback. The onboarding picker prepends these models to the live
  catalog so users can still select any currently available model.
  """

  # Verified against Surplus' live catalog on 2026-09-07. Keep this list
  # deliberately small and frontier-only. It is not a dump of every model
  # Surplus sells; the live picker still exposes those on demand.
  @featured [
    {"claude-fable-5.1", "Claude Fable 5.1"},
    {"glm-5.3-flash", "GLM 5.3 Flash"},
    {"muse-spark-1.3-contributor", "Meta: Muse Spark 1.3 Contributor"},
    {"gpt-6-astra", "GPT-6 Astra"},
    {"gemini-3.8-flash", "Gemini 3.8 Flash"},
    {"kimi-k3", "Kimi K3"},
    {"kimi-k3-fast-api", "Kimi K3 Fast"},
    {"qwen3.8-flash", "Qwen3.8 Flash"},
    {"deepseek-v4-pro", "DeepSeek V4 Pro"},
    {"deepseek-v4-flash", "DeepSeek V4 Flash"},
    {"qwen3.8-2.4t-a95b", "Qwen3.8 2.4T A95B"},
    {"qwen3-coder-next", "Qwen3 Coder Next"},
    {"mistral-large-3", "Mistral Large 3"},
    {"deepseek-v3.1", "DeepSeek V3.1"},
    {"claude-opus-4.8", "Claude Opus 4.8"},
    {"gpt-5.6-sol-pro", "GPT-5.6 Sol Pro"},
    {"grok-4.6", "Grok 4.6"},
    {"glm-5.3", "GLM 5.3"},
    {"minimax-m2", "MiniMax M2"}
  ]

  @featured_ids Enum.map(@featured, &elem(&1, 0))

  @spec default_model() :: String.t()
  def default_model, do: "claude-fable-5.1"

  @spec ids() :: [String.t()]
  def ids, do: @featured_ids

  @spec picker_models() :: [map()]
  def picker_models do
    Enum.map(@featured, fn {id, name} ->
      %{id: id, name: name, ctx: 0, tools: true, recommended: true}
    end)
  end

  @spec featured?(String.t()) :: boolean()
  def featured?(id), do: id in @featured_ids

  @doc "Parse one model object returned by Surplus' OpenAI-compatible catalog."
  @spec parse(map()) :: map()
  def parse(model) when is_map(model) do
    supported_parameters = model["supported_parameters"] || []
    supported_features = model["supported_features"] || []
    pricing = model["pricing"] || %{}
    id = model["id"] || "unknown"

    %{
      id: id,
      name: model["name"] || id,
      ctx: model["context_length"] || model["context_window"] || 0,
      tools:
        "tools" in supported_parameters or "tool_choice" in supported_parameters or
          "tools" in supported_features,
      reasoning: "reasoning" in supported_features or "reasoning" in supported_parameters,
      owned_by: model["owned_by"],
      provider: model["provider"],
      modalities: model["modalities"],
      featured: featured?(id),
      cost: %{
        input: parse_price(pricing["prompt"] || pricing["input"]),
        output: parse_price(pricing["completion"] || pricing["output"])
      }
    }
  end

  @doc "Put the editorial shortlist first, then keep the remaining live catalog stable."
  @spec order_catalog([map()]) :: [map()]
  def order_catalog(models) do
    featured = Enum.filter(@featured_ids, fn id -> find_model(models, id) end)
    featured_models = Enum.map(featured, &Enum.find(models, fn model -> model.id == &1 end))
    remaining = Enum.reject(models, &featured?(&1.id)) |> Enum.sort_by(&String.downcase(&1.name))
    featured_models ++ remaining
  end

  defp find_model(models, id), do: Enum.any?(models, &(&1.id == id))

  defp parse_price(nil), do: nil
  defp parse_price(""), do: nil

  defp parse_price(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> Float.round(number * 1_000_000, 4)
      :error -> nil
    end
  end

  defp parse_price(value) when is_number(value), do: Float.round(value * 1_000_000, 4)
  defp parse_price(_), do: nil
end
