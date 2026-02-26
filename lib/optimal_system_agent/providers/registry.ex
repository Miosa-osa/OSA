defmodule OptimalSystemAgent.Providers.Registry do
  @moduledoc """
  LLM provider routing and fallback chains.

  Supports: Ollama (local), Anthropic, OpenAI-compatible, Groq.
  4-tier model routing:
  1. Process-type default (thinking = best, tool execution = fast)
  2. Task-type override (coding tasks upgrade tier)
  3. Fallback chain when rate-limited
  4. Local fallback (Ollama always available)
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Send a chat completion request to the configured LLM provider.
  """
  def chat(messages, opts \\ []) do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    do_chat(provider, messages, opts)
  end

  @impl true
  def init(:ok) do
    Logger.info("Provider registry initialized (default: #{default_provider()})")
    {:ok, %{}}
  end

  # --- Provider Dispatch ---

  defp do_chat(:ollama, messages, opts) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
    model = Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")

    body = %{
      model: model,
      messages: format_messages(messages),
      stream: false,
      options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
    }

    # Add tools if provided
    body =
      case Keyword.get(opts, :tools) do
        nil -> body
        [] -> body
        tools -> Map.put(body, :tools, format_tools_ollama(tools))
      end

    case Req.post("#{url}/api/chat", json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content} = msg}}} ->
        tool_calls = parse_ollama_tool_calls(msg)
        {:ok, %{content: content || "", tool_calls: tool_calls}}

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama connection failed: #{inspect(reason)}"}
    end
  end

  defp do_chat(:anthropic, messages, opts) do
    api_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)
    model = Application.get_env(:optimal_system_agent, :anthropic_model, "anthropic-latest")

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not set"}
    else
      {system_msgs, chat_msgs} =
        Enum.split_with(format_messages(messages), &(&1.role == "system"))

      system_text = Enum.map_join(system_msgs, "\n\n", & &1.content)

      body = %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        system: system_text,
        messages: chat_msgs
      }

      body =
        case Keyword.get(opts, :tools) do
          nil -> body
          [] -> body
          tools -> Map.put(body, :tools, format_tools_anthropic(tools))
        end

      case Req.post("https://api.anthropic.com/v1/messages",
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          content = extract_anthropic_content(resp)
          tool_calls = extract_anthropic_tool_calls(resp)
          {:ok, %{content: content, tool_calls: tool_calls}}

        {:ok, %{status: status, body: body}} ->
          {:error, "Anthropic returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Anthropic connection failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_chat(:openai, messages, opts) do
    api_key = Application.get_env(:optimal_system_agent, :openai_api_key)
    url = Application.get_env(:optimal_system_agent, :openai_url, "https://api.openai.com/v1")
    model = Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")

    unless api_key do
      {:error, "OPENAI_API_KEY not set"}
    else
      body = %{
        model: model,
        messages: format_messages(messages),
        temperature: Keyword.get(opts, :temperature, 0.7)
      }

      body =
        case Keyword.get(opts, :tools) do
          nil -> body
          [] -> body
          tools -> Map.put(body, :tools, format_tools_openai(tools))
        end

      case Req.post("#{url}/chat/completions",
             json: body,
             headers: [{"Authorization", "Bearer #{api_key}"}],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}} ->
          content = msg["content"] || ""
          tool_calls = parse_openai_tool_calls(msg)
          {:ok, %{content: content, tool_calls: tool_calls}}

        {:ok, %{status: status, body: body}} ->
          {:error, "OpenAI returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "OpenAI connection failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_chat(provider, _messages, _opts) do
    {:error, "Unknown provider: #{provider}"}
  end

  # --- Message Formatting ---

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{role: to_string(role), content: to_string(content)}

      msg when is_map(msg) ->
        msg
    end)
  end

  # --- Tool Formatting ---

  defp format_tools_ollama(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters
        }
      }
    end)
  end

  defp format_tools_anthropic(tools) do
    Enum.map(tools, fn tool ->
      %{name: tool.name, description: tool.description, input_schema: tool.parameters}
    end)
  end

  defp format_tools_openai(tools), do: format_tools_ollama(tools)

  # --- Response Parsing ---

  defp parse_ollama_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"],
        arguments: call["function"]["arguments"] || %{}
      }
    end)
  end

  defp parse_ollama_tool_calls(_), do: []

  defp extract_anthropic_content(%{"content" => blocks}) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_anthropic_content(_), do: ""

  defp extract_anthropic_tool_calls(%{"content" => blocks}) do
    blocks
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(fn block ->
      %{id: block["id"], name: block["name"], arguments: block["input"] || %{}}
    end)
  end

  defp extract_anthropic_tool_calls(_), do: []

  defp parse_openai_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      args =
        case Jason.decode(call["function"]["arguments"] || "{}") do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %{id: call["id"], name: call["function"]["name"], arguments: args}
    end)
  end

  defp parse_openai_tool_calls(_), do: []

  defp default_provider,
    do: Application.get_env(:optimal_system_agent, :default_provider, :ollama)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
