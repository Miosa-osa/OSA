defmodule OptimalSystemAgent.Providers.Ollama do
  @moduledoc """
  Ollama local LLM provider.

  Connects to a locally-running Ollama instance. No API key required.
  Supports tool/function calling for models that expose it.

  Config keys:
    :ollama_url   — base URL (default: http://localhost:11434)
    :ollama_model — model name (default: llama3.2:latest)
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  @impl true
  def name, do: :ollama

  @impl true
  def default_model, do: "llama3.2:latest"

  @impl true
  def chat(messages, opts \\ []) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
    model = Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    body =
      %{
        model: model,
        messages: format_messages(messages),
        stream: false,
        options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
      }
      |> maybe_add_tools(opts)

    try do
      case Req.post("#{url}/api/chat", json: body, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => content} = msg}}} ->
          tool_calls = parse_tool_calls(msg)
          {:ok, %{content: content || "", tool_calls: tool_calls}}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("Ollama returned #{status}: #{inspect(resp_body)}")
          {:error, "Ollama returned #{status}: #{inspect(resp_body)}"}

        {:error, reason} ->
          Logger.error("Ollama connection failed: #{inspect(reason)}")
          {:error, "Ollama connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Ollama unexpected error: #{Exception.message(e)}")
        {:error, "Ollama unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private ---

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => to_string(content)}

      %{"role" => _} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, format_tools(tools))
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp parse_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"],
        arguments: call["function"]["arguments"] || %{}
      }
    end)
  end

  defp parse_tool_calls(_), do: []

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
