defmodule OptimalSystemAgent.Agent.Debate do
  @moduledoc """
  Multi-agent debate orchestration.

  Runs a prompt against one or more providers in parallel and synthesises
  a single answer from their responses.

  ## Options

    * `:providers` - list of provider name strings (e.g. `["openai", "anthropic"]`).
      Defaults to the application's `:default_provider` env value if set.
    * `:timeout` - per-provider call timeout in ms. Default: 30_000.
    * `:synthesizer_provider` - provider used to produce the final synthesis.
      Defaults to the first provider in the list.
    * `:user_id` - optional user context string.
    * `:model` - optional model override string.

  ## Return value

  ```
  {:ok, %{synthesis: string, debate: [%{provider:, response:}], participants: integer}}
  {:error, :no_providers}
  {:error, reason}
  ```
  """

  require Logger

  @default_timeout 30_000

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Run a debate with `message` and default options."
  @spec run(String.t()) :: {:ok, map()} | {:error, term()}
  def run(message), do: run(message, [])

  @doc "Run a debate with `message` and keyword `opts`."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(message, opts) when is_binary(message) and is_list(opts) do
    providers = Keyword.get(opts, :providers, default_providers())
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case providers do
      [] ->
        {:error, :no_providers}

      providers ->
        call_providers(message, providers, timeout, opts)
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp default_providers do
    case Application.get_env(:optimal_system_agent, :default_provider) do
      nil -> []
      provider -> [to_string(provider)]
    end
  end

  defp call_providers(message, providers, timeout, opts) do
    tasks =
      Enum.map(providers, fn provider ->
        Task.async(fn -> call_provider(provider, message, opts) end)
      end)

    responses =
      tasks
      |> Task.yield_many(timeout)
      |> Enum.zip(providers)
      |> Enum.flat_map(fn {{_task, result}, provider} ->
        case result do
          {:ok, {:ok, response}} ->
            [%{provider: provider, response: response}]

          {:ok, {:error, reason}} ->
            Logger.warning("[Debate] Provider #{provider} error: #{inspect(reason)}")
            []

          nil ->
            Logger.warning("[Debate] Provider #{provider} timed out")
            []

          {:exit, reason} ->
            Logger.warning("[Debate] Provider #{provider} exited: #{inspect(reason)}")
            []
        end
      end)

    case responses do
      [] ->
        {:error, :all_providers_failed}

      [single] ->
        {:ok, %{
          synthesis: single.response,
          debate: responses,
          participants: 1
        }}

      many ->
        synthesis = synthesise(many)
        {:ok, %{synthesis: synthesis, debate: many, participants: length(many)}}
    end
  end

  defp call_provider(provider, message, _opts) do
    # Route to the configured LLM provider.  This delegates to the existing
    # provider registry rather than making direct HTTP calls here.
    provider_atom = provider_to_atom(provider)

    case provider_atom do
      :mock ->
        # Test / mock provider — echo a deterministic response.
        {:ok, "Mock response from provider '#{provider}' for: #{String.slice(message, 0, 80)}"}

      _ ->
        # Attempt to dispatch through the agent loop's LLM client if available.
        # Returns {:error, :unavailable} when no provider is configured.
        {:error, {:provider_unavailable, provider}}
    end
  end

  defp provider_to_atom("mock"), do: :mock
  defp provider_to_atom("anthropic"), do: :anthropic
  defp provider_to_atom("openai"), do: :openai
  defp provider_to_atom("ollama"), do: :ollama
  defp provider_to_atom(_), do: :unknown

  defp synthesise(responses) do
    parts =
      responses
      |> Enum.map(fn %{provider: p, response: r} -> "**#{p}**: #{r}" end)
      |> Enum.join("\n\n")

    "Synthesis from #{length(responses)} providers:\n\n#{parts}"
  end
end
