defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @impl true
  def name, do: "mixture_of_agents"

  @impl true
  def deferred?, do: true

  @impl true
  def description do
    "Fan out a query to multiple LLM providers in parallel and synthesize the best response. " <>
      "Use for critical decisions, complex analysis, or problems requiring high confidence. " <>
      "Returns a synthesized answer combining insights from all models."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["query"],
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The question or problem to send to multiple models"
        },
        "providers" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "List of providers to query (e.g., ['anthropic', 'openai', 'groq']). Defaults to all available."
        }
      }
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    requested = Map.get(args, "providers")

    # Resolve which providers to use
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
      # Fan out to all providers in parallel
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

      # Collect results (30s timeout per provider)
      results =
        tasks
        |> Enum.map(fn task ->
          try do
            Task.await(task, 30_000)
          catch
            :exit, _ -> {:error, :unknown, "timeout"}
          end
        end)

      successful =
        results
        |> Enum.filter(fn
          {:ok, _, _} -> true
          _ -> false
        end)

      if successful == [] do
        {:ok, "All providers failed. Try with different providers."}
      else
        # Synthesize responses using the primary model
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

        case Providers.chat([%{role: "user", content: synthesis_prompt}], max_tokens: 4096) do
          {:ok, %{content: synthesis}} ->
            provider_list =
              Enum.map(successful, fn {:ok, p, _} -> to_string(p) end) |> Enum.join(", ")

            {:ok,
             "**Mixture-of-Agents Synthesis** (#{length(successful)} models: #{provider_list})\n\n#{synthesis}"}

          {:error, reason} ->
            # If synthesis fails, return the raw responses
            {:ok, "Synthesis failed (#{inspect(reason)}). Raw responses:\n\n#{responses_text}"}
        end
      end
    end
  end

  def execute(_), do: {:error, "Missing required parameter: query"}

  defp available_providers do
    # Check which providers have API keys configured
    candidates = [:anthropic, :openai, :groq, :together, :openrouter, :google, :cohere, :ollama]

    Enum.filter(candidates, fn provider ->
      case provider do
        :anthropic -> System.get_env("ANTHROPIC_API_KEY") != nil
        :openai -> System.get_env("OPENAI_API_KEY") != nil
        :groq -> System.get_env("GROQ_API_KEY") != nil
        :together -> System.get_env("TOGETHER_API_KEY") != nil
        :openrouter -> System.get_env("OPENROUTER_API_KEY") != nil
        :google -> System.get_env("GOOGLE_API_KEY") != nil
        :cohere -> System.get_env("COHERE_API_KEY") != nil
        # Ollama is always available if running
        :ollama -> true
        _ -> false
      end
    end)
  end
end
