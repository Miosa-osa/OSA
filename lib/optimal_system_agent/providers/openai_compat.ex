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

  alias OptimalSystemAgent.Utils.Text

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
          content = Text.strip_thinking_tokens(msg["content"] || "")
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
      # Tool result messages — preserve tool_call_id for the API
      %{role: "tool", content: content, tool_call_id: id} ->
        %{"role" => "tool", "content" => to_string(content), "tool_call_id" => to_string(id)}

      # Assistant messages with tool_calls — preserve structured tool calls
      %{role: "assistant", content: content, tool_calls: calls} when is_list(calls) and calls != [] ->
        msg = %{"role" => "assistant", "content" => to_string(content)}

        formatted_calls =
          Enum.map(calls, fn tc ->
            %{
              "id" => to_string(tc[:id] || tc["id"] || ""),
              "type" => "function",
              "function" => %{
                "name" => to_string(tc[:name] || tc["name"] || ""),
                "arguments" =>
                  case tc[:arguments] || tc["arguments"] do
                    a when is_binary(a) -> a
                    a when is_map(a) -> Jason.encode!(a)
                    _ -> "{}"
                  end
              }
            }
          end)

        Map.put(msg, "tool_calls", formatted_calls)

      # Generic atom-keyed messages
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
        name: call["function"]["name"] |> to_string() |> String.split(~r/\s+/) |> List.first(),
        arguments: args
      }
    end)
  end

  # Fallback: detect tool calls embedded as XML/JSON in the content field
  def parse_tool_calls(%{"content" => content}) when is_binary(content) do
    parse_tool_calls_from_content(content)
  end

  def parse_tool_calls(_), do: []

  @doc false
  def parse_tool_calls_from_content(content) when is_binary(content) do
    cond do
      # Format 1: <function name="tool_name" parameters={...}></function>
      String.contains?(content, "<function") ->
        ~r/<function\s+name="([^"]+)"\s+parameters=(\{.*?\})>\s*<\/function>/s
        |> Regex.scan(content)
        |> Enum.map(fn [_full, name, args_str] ->
          args =
            case Jason.decode(args_str) do
              {:ok, parsed} -> parsed
              _ -> %{}
            end

          %{
            id: generate_id(),
            name: name |> String.split(~r/\s+/) |> List.first(),
            arguments: args
          }
        end)

      # Format 2: <function_call>{"name": "...", "arguments": {...}}</function_call>
      String.contains?(content, "<function_call>") ->
        ~r/<function_call>\s*(\{.*?\})\s*<\/function_call>/s
        |> Regex.scan(content)
        |> Enum.flat_map(fn [_full, json_str] ->
          case Jason.decode(json_str) do
            {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
              [%{id: generate_id(), name: name |> String.split(~r/\s+/) |> List.first(), arguments: args}]

            {:ok, %{"name" => name, "arguments" => args}} when is_binary(args) ->
              case Jason.decode(args) do
                {:ok, parsed} ->
                  [%{id: generate_id(), name: name |> String.split(~r/\s+/) |> List.first(), arguments: parsed}]

                _ ->
                  [%{id: generate_id(), name: name |> String.split(~r/\s+/) |> List.first(), arguments: %{}}]
              end

            _ ->
              []
          end
        end)

      # Format 3: raw JSON tool call object {"name": "...", "arguments": {...}}
      String.contains?(content, "\"name\"") and String.contains?(content, "\"arguments\"") ->
        ~r/\{\s*"name"\s*:\s*"[^"]+"\s*,\s*"arguments"\s*:\s*\{.*?\}\s*\}/s
        |> Regex.scan(content)
        |> Enum.flat_map(fn [json_str] ->
          case Jason.decode(json_str) do
            {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
              [%{id: generate_id(), name: name |> String.split(~r/\s+/) |> List.first(), arguments: args}]

            _ ->
              []
          end
        end)

      true ->
        []
    end
  end

  def parse_tool_calls_from_content(_), do: []

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

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
