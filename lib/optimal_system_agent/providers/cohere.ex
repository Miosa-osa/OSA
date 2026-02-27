defmodule OptimalSystemAgent.Providers.Cohere do
  @moduledoc """
  Cohere provider — Command R+ and Command A models.

  Uses the Cohere v2 Chat API. Cohere has unique role naming:
  "USER", "CHATBOT", and "SYSTEM" (uppercase). Also uses a distinct
  tool definition format with parameter_definitions instead of JSON Schema.

  Config keys:
    :cohere_api_key — required (COHERE_API_KEY)
    :cohere_model   — (default: command-r-plus)
    :cohere_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  @default_url "https://api.cohere.com/v2"

  @impl true
  def name, do: :cohere

  @impl true
  def default_model, do: "command-r-plus"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :cohere_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :cohere_model, default_model())

    base_url = Application.get_env(:optimal_system_agent, :cohere_url, @default_url)

    unless api_key do
      {:error, "COHERE_API_KEY not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    body =
      %{
        model: model,
        messages: format_messages(messages)
      }
      |> maybe_add_tools(opts)
      |> maybe_add_temperature(opts)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    try do
      case Req.post("#{base_url}/chat",
             json: body,
             headers: headers,
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          content = extract_content(resp)
          tool_calls = extract_tool_calls(resp)
          {:ok, %{content: content, tool_calls: tool_calls}}

        {:ok, %{status: status, body: resp_body}} ->
          error_msg = extract_error(resp_body)
          Logger.warning("Cohere returned #{status}: #{error_msg}")
          {:error, "Cohere returned #{status}: #{error_msg}"}

        {:error, reason} ->
          Logger.error("Cohere connection failed: #{inspect(reason)}")
          {:error, "Cohere connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Cohere unexpected error: #{Exception.message(e)}")
        {:error, "Cohere unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private ---

  # Cohere v2 uses lowercase roles: "user", "assistant", "system", "tool"
  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        cohere_role = normalize_role(to_string(role))
        %{"role" => cohere_role, "content" => to_string(content)}

      %{"role" => role} = msg ->
        Map.put(msg, "role", normalize_role(role))

      msg when is_map(msg) ->
        msg
    end)
  end

  # Cohere v2 API uses lowercase roles
  defp normalize_role("USER"), do: "user"
  defp normalize_role("CHATBOT"), do: "assistant"
  defp normalize_role("SYSTEM"), do: "system"
  defp normalize_role("assistant"), do: "assistant"
  defp normalize_role(role), do: String.downcase(role)

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, format_tools(tools))
    end
  end

  # Cohere v2 uses a similar tool format to OpenAI but with some differences
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

  defp maybe_add_temperature(body, opts) do
    case Keyword.get(opts, :temperature) do
      nil -> body
      temp -> Map.put(body, :temperature, temp)
    end
  end

  defp extract_content(%{"message" => %{"content" => [%{"text" => text} | _]}}), do: text

  defp extract_content(%{"message" => %{"content" => content}}) when is_binary(content),
    do: content

  defp extract_content(%{"text" => text}), do: text

  defp extract_content(%{"message" => %{"tool_calls" => _calls}}), do: ""
  defp extract_content(_), do: ""

  defp extract_tool_calls(%{"message" => %{"tool_calls" => calls}}) when is_list(calls) do
    Enum.map(calls, fn call ->
      args =
        case call["function"]["arguments"] do
          args when is_map(args) ->
            args

          args when is_binary(args) ->
            case Jason.decode(args) do
              {:ok, parsed} -> parsed
              _ -> %{}
            end

          _ ->
            %{}
        end

      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"],
        arguments: args
      }
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(body), do: inspect(body)

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
