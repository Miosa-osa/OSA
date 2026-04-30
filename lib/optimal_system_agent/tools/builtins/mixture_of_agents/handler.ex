defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `mixture_of_agents`.

  Split mirrors the structured-layout pattern:
    * `validate/2`          — type-check input shape
    * `check_permissions/2` — always allow (MoA dispatches sub-agents internally)
    * `execute/2`           — fan-out to providers, collect, synthesize

  The fan-out uses `Task.Supervisor.async_nolink/2` under
  `OptimalSystemAgent.TaskSupervisor` so provider failures are isolated.
  Each provider has a `Constants.provider_timeout_ms/0` timeout.
  """

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Validate ─────────────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"query" => query} = input, _ctx) when is_binary(query) and query != "" do
    {:ok, input}
  end

  def validate(%{"query" => _}, _ctx),
    do: {:error, "query must be a non-empty string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: query", -32_602}

  # ── Stage 2: Permissions ──────────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"query" => query} = args, _ctx) do
    requested = Map.get(args, "providers")

    providers =
      if is_list(requested) and length(requested) > 0 do
        Enum.map(requested, &String.to_existing_atom/1)
      else
        available_providers()
      end

    if length(providers) < 2 do
      {:ok,
       "Mixture-of-Agents requires at least 2 providers. Only #{length(providers)} available. " <>
         "Configure additional providers or use the default model instead."}
    else
      fan_out_and_synthesize(query, providers)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp fan_out_and_synthesize(query, providers) do
    timeout = Constants.provider_timeout_ms()

    tasks =
      Enum.map(providers, fn provider ->
        Task.Supervisor.async_nolink(
          OptimalSystemAgent.TaskSupervisor,
          fn ->
            try do
              case Providers.chat(
                     [%{role: "user", content: query}],
                     provider: provider,
                     temperature: 0.7,
                     max_tokens: 2048
                   ) do
                {:ok, %{content: content}} -> {:ok, provider, content}
                {:error, reason} -> {:error, provider, reason}
              end
            rescue
              e -> {:error, provider, Exception.message(e)}
            end
          end
        )
      end)

    results =
      Enum.map(tasks, fn task ->
        try do
          Task.await(task, timeout)
        catch
          :exit, _ -> {:error, :unknown, "timeout"}
        end
      end)

    successful =
      Enum.filter(results, fn
        {:ok, _, _} -> true
        _ -> false
      end)

    if successful == [] do
      {:ok, "All providers failed. Try with different providers."}
    else
      synthesize(query, successful)
    end
  end

  defp synthesize(query, successful) do
    responses_text =
      successful
      |> Enum.with_index(1)
      |> Enum.map(fn {{:ok, provider, content}, idx} ->
        "## Response #{idx} (#{provider})\n#{content}"
      end)
      |> Enum.join("\n\n---\n\n")

    synthesis_prompt = """
    You received #{length(successful)} responses to the following query from different AI models:

    **Query:** #{query}

    #{responses_text}

    Synthesize the BEST answer by:
    1. Identifying points of agreement (high confidence)
    2. Noting unique insights from each response
    3. Resolving any contradictions with reasoning
    4. Producing a single, comprehensive answer

    Be concise but complete. Cite which model(s) contributed each point where relevant.
    """

    case Providers.chat([%{role: "user", content: synthesis_prompt}],
           max_tokens: Constants.synthesis_max_tokens()
         ) do
      {:ok, %{content: synthesis}} ->
        provider_list =
          successful
          |> Enum.map(fn {:ok, p, _} -> to_string(p) end)
          |> Enum.join(", ")

        {:ok,
         "**Mixture-of-Agents Synthesis** (#{length(successful)} models: #{provider_list})\n\n#{synthesis}"}

      {:error, reason} ->
        {:ok, "Synthesis failed (#{inspect(reason)}). Raw responses:\n\n#{responses_text}"}
    end
  end

  defp available_providers do
    Enum.filter(Constants.candidate_providers(), fn provider ->
      case provider do
        :anthropic -> System.get_env("ANTHROPIC_API_KEY") != nil
        :openai -> System.get_env("OPENAI_API_KEY") != nil
        :groq -> System.get_env("GROQ_API_KEY") != nil
        :together -> System.get_env("TOGETHER_API_KEY") != nil
        :openrouter -> System.get_env("OPENROUTER_API_KEY") != nil
        :google -> System.get_env("GOOGLE_API_KEY") != nil
        :cohere -> System.get_env("COHERE_API_KEY") != nil
        # Ollama is always available if running locally
        :ollama -> true
        _ -> false
      end
    end)
  end
end
