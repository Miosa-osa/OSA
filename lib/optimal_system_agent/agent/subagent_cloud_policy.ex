defmodule OptimalSystemAgent.Agent.SubagentCloudPolicy do
  @moduledoc """
  Operator opt-in cloud-only inference for delegated agents.

  Set OSA_SUBAGENT_CLOUD_ONLY=true in the service environment (or configure
  :subagent_cloud_only). Defaults to false. This is independent of the main
  session's provider and cannot be disabled through delegate arguments.
  """

  alias OptimalSystemAgent.Agent.RunStore

  @cloud_providers ~w(openai groq together fireworks deepseek perplexity mistral
    openrouter surplus openai_codex claude_cli copilot_cli bedrock anthropic
    google cohere replicate qwen moonshot zhipu volcengine baichuan miosa xai
    cerebras sambanova hyperbolic uncensored)a
  @known_providers @cloud_providers ++ [:ollama, :ollama_cloud, :lmstudio, :llamacpp]

  def enabled?,
    do: Application.get_env(:optimal_system_agent, :subagent_cloud_only, false) != false

  @doc "Validate a delegated selection; unknown routes fail closed when enabled."
  def check(provider, model, opts \\ []) do
    provider = normalize_provider(provider)

    if not enabled?() or cloud_route?(provider, model, opts) do
      :ok
    else
      {:error,
       "cloud-only delegation policy blocked #{inspect(provider)}/#{inspect(model)}; " <>
         "select a cloud provider or an Ollama model ending in :cloud or -cloud"}
    end
  end

  def blocked?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "cloud-only delegation policy blocked ")

  def blocked?(_), do: false

  @doc "Preserve the boundary on retries, fallbacks, and resumed child helper calls."
  def check_request(provider, model, opts) do
    if enabled?() and delegated_request?(opts), do: check(provider, model, opts), else: :ok
  end

  @doc "Annotate requests from the loop state; caller options cannot clear child identity."
  def request_opts(opts, state) do
    parent = Map.get(state, :parent_session_id)
    delegated = is_binary(parent) and parent != ""
    Keyword.put(opts, :delegated_agent, delegated or Keyword.get(opts, :delegated_agent, false))
  end

  defp delegated_request?(opts) do
    Keyword.get(opts, :delegated_agent) == true or child_session?(Keyword.get(opts, :session_id))
  end

  defp child_session?(id) when is_binary(id) and id != "" do
    case RunStore.get(id) do
      %{parent_session_id: parent} when is_binary(parent) and parent != "" -> true
      _ -> false
    end
  end

  defp child_session?(_), do: false

  defp cloud_route?(provider, model, _opts) when provider in [:ollama, :ollama_cloud] do
    # Ollama's exact terminal cloud tags route cloud inference even when the
    # authenticated local daemon is the transport. A bare provider name is
    # insufficient: that same daemon also serves downloaded local weights.
    is_binary(model) and String.trim(model) == model and
      Regex.match?(~r/^[^\s]+(?::cloud|-cloud)$/, model)
  end

  defp cloud_route?(provider, model, opts) when provider in @cloud_providers do
    is_binary(model) and String.trim(model) != "" and remote_overrides?(provider, opts)
  end

  defp cloud_route?(_, _, _), do: false

  defp remote_overrides?(provider, opts) do
    [
      Keyword.get(opts, :base_url),
      Keyword.get(opts, :url),
      Application.get_env(:optimal_system_agent, :"#{provider}_url"),
      Application.get_env(:optimal_system_agent, :"#{provider}_base_url")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.all?(&remote_url?/1)
  end

  defp remote_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(String.trim_trailing(host, "."))

        host not in ["localhost", "localhost.localdomain"] and
          not String.ends_with?(host, [".localhost", ".local", ".internal"]) and
          not local_address?(host)

      _ ->
        false
    end
  end

  defp remote_url?(_), do: false

  defp local_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {a, b, _, _}} ->
        a in [0, 10, 127, 169] or (a == 172 and b in 16..31) or (a == 192 and b == 168)

      {:ok, {_a, _b, _c, _d, _e, _f, _g, _h}} ->
        true

      _ ->
        not String.contains?(host, ".")
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider

  defp normalize_provider(provider) when is_binary(provider),
    do: Enum.find(@known_providers, &(Atom.to_string(&1) == provider))

  defp normalize_provider(_), do: nil
end
