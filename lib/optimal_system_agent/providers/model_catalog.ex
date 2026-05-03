defmodule OptimalSystemAgent.Providers.ModelCatalog do
  @moduledoc """
  Curated model metadata used by the model switcher and context accounting.

  Live Ollama remains the source of truth for locally installed models. This
  catalog fills in cloud/provider models that are not reliably discoverable
  without credentials and gives the TUI enough metadata to group, sort, and
  filter model choices by provider and capability.
  """

  @type entry :: %{
          name: String.t(),
          provider: String.t(),
          context_window: pos_integer(),
          capabilities: [String.t()],
          source: String.t(),
          size: non_neg_integer()
        }

  @entries [
    # Ollama Cloud / Ollama library models.
    %{
      provider: "ollama",
      name: "deepseek-v4-pro",
      context_window: 1_000_000,
      capabilities: ~w(cloud agent reasoning tools coding),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "deepseek-v4-pro:cloud",
      context_window: 1_000_000,
      capabilities: ~w(cloud agent reasoning tools coding),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "deepseek-v4-flash",
      context_window: 1_000_000,
      capabilities: ~w(cloud fast reasoning tools coding),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "deepseek-v4-flash:cloud",
      context_window: 1_000_000,
      capabilities: ~w(cloud fast reasoning tools coding),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "gemini-3-flash-preview",
      context_window: 1_000_000,
      capabilities: ~w(cloud fast reasoning),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "gemini-3-flash-preview:cloud",
      context_window: 1_000_000,
      capabilities: ~w(cloud fast reasoning),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "kimi-k2.6:cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent coding vision),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "kimi-k2-thinking:cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent coding reasoning tools),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "kimi-k2:1t-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent coding),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "qwen3-coder:480b-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent coding tools),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "qwen3-coder-next",
      context_window: 256_000,
      capabilities: ~w(agent coding tools),
      source: "ollama-library",
      size: 52_000_000_000
    },
    %{
      provider: "ollama",
      name: "qwen3-coder-next:cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent coding tools),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "qwen3-next:80b-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent tools),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "qwen3.5:397b",
      context_window: 256_000,
      capabilities: ~w(agent reasoning tools),
      source: "ollama-library",
      size: 0
    },
    %{
      provider: "ollama",
      name: "mistral-large-3:675b-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent tools vision),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "ministral-3:3b-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent tools vision),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "ministral-3:8b-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent tools vision),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "ministral-3:14b-cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent tools vision),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "nemotron-3-super:cloud",
      context_window: 256_000,
      capabilities: ~w(cloud agent reasoning tools),
      source: "ollama-cloud",
      size: 0
    },
    %{
      provider: "ollama",
      name: "deepseek-v3.1:671b-cloud",
      context_window: 160_000,
      capabilities: ~w(cloud agent reasoning tools),
      source: "ollama-cloud",
      size: 0
    },

    # OpenAI current API models.
    %{
      provider: "openai",
      name: "gpt-5.5",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools vision),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.5-pro",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools vision),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.4",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools vision),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.4-mini",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.4-nano",
      context_window: 1_050_000,
      capabilities: ~w(fast tools),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.3-codex",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.2",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools vision),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.2-pro",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools vision),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-5.2-codex",
      context_window: 1_050_000,
      capabilities: ~w(agent coding reasoning tools),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-4.1",
      context_window: 1_047_576,
      capabilities: ~w(tools vision),
      source: "openai",
      size: 0
    },
    %{
      provider: "openai",
      name: "gpt-4.1-mini",
      context_window: 1_047_576,
      capabilities: ~w(fast tools vision),
      source: "openai",
      size: 0
    },

    # Anthropic current Claude API models.
    %{
      provider: "anthropic",
      name: "claude-opus-4-7",
      context_window: 1_000_000,
      capabilities: ~w(agent coding reasoning vision),
      source: "anthropic",
      size: 0
    },
    %{
      provider: "anthropic",
      name: "claude-sonnet-4-6",
      context_window: 1_000_000,
      capabilities: ~w(agent coding reasoning vision),
      source: "anthropic",
      size: 0
    },
    %{
      provider: "anthropic",
      name: "claude-haiku-4-5",
      context_window: 200_000,
      capabilities: ~w(fast vision),
      source: "anthropic",
      size: 0
    },

    # Native / OpenAI-compatible provider models.
    %{
      provider: "deepseek",
      name: "deepseek-v4-pro",
      context_window: 1_000_000,
      capabilities: ~w(agent reasoning coding tools),
      source: "provider",
      size: 0
    },
    %{
      provider: "deepseek",
      name: "deepseek-v4-flash",
      context_window: 1_000_000,
      capabilities: ~w(fast reasoning coding tools),
      source: "provider",
      size: 0
    },
    %{
      provider: "deepseek",
      name: "deepseek-chat",
      context_window: 128_000,
      capabilities: ~w(coding tools),
      source: "provider",
      size: 0
    },
    %{
      provider: "deepseek",
      name: "deepseek-reasoner",
      context_window: 128_000,
      capabilities: ~w(reasoning coding),
      source: "provider",
      size: 0
    },
    %{
      provider: "google",
      name: "gemini-3-flash-preview",
      context_window: 1_000_000,
      capabilities: ~w(fast reasoning),
      source: "provider",
      size: 0
    },
    %{
      provider: "google",
      name: "gemini-2.5-pro",
      context_window: 1_048_576,
      capabilities: ~w(agent coding reasoning vision),
      source: "provider",
      size: 0
    },
    %{
      provider: "google",
      name: "gemini-2.5-flash",
      context_window: 1_048_576,
      capabilities: ~w(fast tools vision),
      source: "provider",
      size: 0
    },
    %{
      provider: "groq",
      name: "llama-3.3-70b-versatile",
      context_window: 128_000,
      capabilities: ~w(fast tools),
      source: "provider",
      size: 0
    },
    %{
      provider: "mistral",
      name: "mistral-large-3",
      context_window: 256_000,
      capabilities: ~w(agent tools vision),
      source: "provider",
      size: 0
    },
    %{
      provider: "mistral",
      name: "mistral-large-latest",
      context_window: 128_000,
      capabilities: ~w(coding tools),
      source: "provider",
      size: 0
    }
  ]

  @spec entries() :: [entry()]
  def entries, do: @entries

  @spec entries_for(atom() | String.t()) :: [entry()]
  def entries_for(provider) do
    provider = to_string(provider)
    Enum.filter(@entries, &(&1.provider == provider))
  end

  @spec names_for(atom() | String.t()) :: [String.t()]
  def names_for(provider), do: Enum.map(entries_for(provider), & &1.name)

  @spec context_window(String.t()) :: {:ok, pos_integer()} | :error
  def context_window(model) when is_binary(model) do
    case Enum.find(@entries, &(&1.name == model)) do
      %{context_window: ctx} -> {:ok, ctx}
      nil -> context_window_by_prefix(model)
    end
  end

  def context_window(_), do: :error

  defp context_window_by_prefix(model) do
    @entries
    |> Enum.filter(&String.starts_with?(model, &1.name))
    |> Enum.max_by(&String.length(&1.name), fn -> nil end)
    |> case do
      %{context_window: ctx} -> {:ok, ctx}
      nil -> :error
    end
  end
end
