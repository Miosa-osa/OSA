defmodule OptimalSystemAgent.Providers.Anthropic do
  @moduledoc """
  Anthropic provider.

  Uses the Anthropic Messages API. Handles system message extraction,
  tool use (input_schema format), and multi-block content responses.

  Config keys:
    :anthropic_api_key — required
    :anthropic_model   — (default: anthropic-latest)
    :anthropic_url     — override base URL (default: https://api.anthropic.com/v1)
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  @default_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @impl true
  def name, do: :anthropic

  @impl true
  def default_model, do: "anthropic-latest"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)
    model = Application.get_env(:optimal_system_agent, :anthropic_model, default_model())
    base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    formatted = format_messages(messages)
    {system_msgs, chat_msgs} = Enum.split_with(formatted, &(&1["role"] == "system"))
    system_text = Enum.map_join(system_msgs, "\n\n", & &1["content"])

    body =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        messages: chat_msgs
      }
      |> maybe_add_system(system_text)
      |> maybe_add_tools(opts)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    try do
      case Req.post("#{base_url}/messages",
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
          Logger.warning("Anthropic returned #{status}: #{error_msg}")
          {:error, "Anthropic returned #{status}: #{error_msg}"}

        {:error, reason} ->
          Logger.error("Anthropic connection failed: #{inspect(reason)}")
          {:error, "Anthropic connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Anthropic unexpected error: #{Exception.message(e)}")
        {:error, "Anthropic unexpected error: #{Exception.message(e)}"}
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

  defp maybe_add_system(body, ""), do: body
  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system_text), do: Map.put(body, :system, system_text)

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
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => tool.parameters
      }
    end)
  end

  defp extract_content(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_content(_), do: ""

  defp extract_tool_calls(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(fn block ->
      %{
        id: block["id"] || generate_id(),
        name: block["name"],
        arguments: block["input"] || %{}
      }
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body), do: inspect(body)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
