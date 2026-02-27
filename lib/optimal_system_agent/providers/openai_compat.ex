defmodule OptimalSystemAgent.Providers.OpenAICompat do
  @moduledoc """
  Shared chat completion logic for all OpenAI-compatible APIs.

  Providers that use this module only need to supply:
  - base URL
  - API key
  - model name

  The wire format (POST /chat/completions), tool call formatting, and
  response parsing are identical across all OpenAI-compatible endpoints.
  """

  require Logger

  @doc """
  Execute a chat completion against any OpenAI-compatible endpoint.

  Returns `{:ok, %{content: String.t(), tool_calls: list()}}` or `{:error, reason}`.
  """
  @spec chat(String.t(), String.t() | nil, String.t(), list(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def chat(base_url, api_key, model, messages, opts) do
    unless api_key do
      {:error, "API key not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    body =
      %{
        model: model,
        messages: format_messages(messages),
        temperature: Keyword.get(opts, :temperature, 0.7)
      }
      |> maybe_add_tools(opts)
      |> maybe_add_max_tokens(opts)

    extra_headers = Keyword.get(opts, :extra_headers, [])

    headers =
      [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ] ++ extra_headers

    url = "#{base_url}/chat/completions"

    try do
      case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]} = resp}} ->
          content = msg["content"] || ""
          tool_calls = parse_tool_calls(msg)
          usage = parse_usage(resp)
          {:ok, %{content: content, tool_calls: tool_calls, usage: usage}}

        {:ok, %{status: status, body: resp_body}} ->
          error_msg = extract_error_message(resp_body)
          {:error, "HTTP #{status}: #{error_msg}"}

        {:error, reason} ->
          {:error, "Connection failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Unexpected error: #{Exception.message(e)}"}
    end
  end

  @doc "Format messages into the OpenAI wire format."
  def format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => to_string(content)}

      %{"role" => _role} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  @doc "Format tools into the OpenAI function-calling format."
  def format_tools(tools) do
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

  @doc "Parse tool_calls from an OpenAI-style message map."
  def parse_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      args =
        case Jason.decode(call["function"]["arguments"] || "{}") do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"],
        arguments: args
      }
    end)
  end

  def parse_tool_calls(_), do: []

  # --- Private helpers ---

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, format_tools(tools))
    end
  end

  defp maybe_add_max_tokens(body, opts) do
    case Keyword.get(opts, :max_tokens) do
      nil -> body
      n -> Map.put(body, :max_tokens, n)
    end
  end

  defp parse_usage(%{"usage" => %{"prompt_tokens" => inp, "completion_tokens" => out}}),
    do: %{input_tokens: inp, output_tokens: out}

  defp parse_usage(_), do: %{}

  defp extract_error_message(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(body), do: inspect(body)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
