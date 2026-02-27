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
  def default_model, do: "claude-sonnet-4-6"

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

  @impl true
  def chat_stream(messages, callback, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)
    model = Application.get_env(:optimal_system_agent, :anthropic_model, default_model())
    base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      do_chat_stream(base_url, api_key, model, messages, callback, opts)
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

  # --- Streaming ---

  defp do_chat_stream(base_url, api_key, model, messages, callback, opts) do
    formatted = format_messages(messages)
    {system_msgs, chat_msgs} = Enum.split_with(formatted, &(&1["role"] == "system"))
    system_text = Enum.map_join(system_msgs, "\n\n", & &1["content"])

    body =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        messages: chat_msgs,
        stream: true
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
             receive_timeout: 120_000,
             into: :self
           ) do
        {:ok, resp} ->
          collect_stream(resp, callback, %{content: "", tool_calls: [], current_tool: nil, buffer: ""})

        {:error, reason} ->
          Logger.error("Anthropic stream connection failed: #{inspect(reason)}")
          fallback_to_sync(base_url, api_key, model, messages, callback, opts)
      end
    rescue
      e ->
        Logger.error("Anthropic stream unexpected error: #{Exception.message(e)}")
        fallback_to_sync(base_url, api_key, model, messages, callback, opts)
    end
  end

  defp collect_stream(resp, callback, acc) do
    ref = resp.body

    receive do
      {^ref, {:data, data}} ->
        {events, new_buffer} = parse_sse_chunk(acc.buffer <> data)
        acc = %{acc | buffer: new_buffer}

        acc =
          Enum.reduce(events, acc, fn event, inner_acc ->
            process_stream_event(event, callback, inner_acc)
          end)

        collect_stream(resp, callback, acc)

      {^ref, :done} ->
        # Finalize any in-progress tool call
        acc = finalize_current_tool(acc)

        result = %{content: acc.content, tool_calls: Enum.reverse(acc.tool_calls)}
        callback.({:done, result})
        :ok

      {^ref, {:error, reason}} ->
        Logger.error("Anthropic stream error: #{inspect(reason)}")
        {:error, "Stream error: #{inspect(reason)}"}
    after
      130_000 ->
        Logger.error("Anthropic stream timeout")
        {:error, "Stream timeout"}
    end
  end

  defp parse_sse_chunk(data) do
    # Split by double newline (SSE event boundary)
    parts = String.split(data, "\n\n")

    # The last part may be incomplete — keep it as buffer
    {complete, [remainder]} = Enum.split(parts, -1)

    events =
      complete
      |> Enum.flat_map(fn part ->
        lines = String.split(part, "\n")

        data_lines =
          lines
          |> Enum.filter(&String.starts_with?(&1, "data: "))
          |> Enum.map(&String.trim_leading(&1, "data: "))

        Enum.flat_map(data_lines, fn json_str ->
          case Jason.decode(json_str) do
            {:ok, parsed} -> [parsed]
            _ -> []
          end
        end)
      end)

    {events, remainder}
  end

  defp process_stream_event(%{"type" => "content_block_start", "content_block" => block}, callback, acc) do
    case block do
      %{"type" => "text"} ->
        acc

      %{"type" => "tool_use", "id" => id, "name" => name} ->
        acc = finalize_current_tool(acc)
        callback.({:tool_use_start, %{id: id, name: name}})
        %{acc | current_tool: %{id: id, name: name, input_json: ""}}

      _ ->
        acc
    end
  end

  defp process_stream_event(%{"type" => "content_block_delta", "delta" => delta}, callback, acc) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        callback.({:text_delta, text})
        %{acc | content: acc.content <> text}

      %{"type" => "input_json_delta", "partial_json" => json_chunk} ->
        callback.({:tool_use_delta, json_chunk})

        if acc.current_tool do
          updated_tool = %{acc.current_tool | input_json: acc.current_tool.input_json <> json_chunk}
          %{acc | current_tool: updated_tool}
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp process_stream_event(%{"type" => "content_block_stop"}, _callback, acc) do
    finalize_current_tool(acc)
  end

  defp process_stream_event(%{"type" => "message_stop"}, _callback, acc), do: acc
  defp process_stream_event(%{"type" => "message_start"}, _callback, acc), do: acc
  defp process_stream_event(%{"type" => "message_delta"}, _callback, acc), do: acc
  defp process_stream_event(%{"type" => "ping"}, _callback, acc), do: acc
  defp process_stream_event(_event, _callback, acc), do: acc

  defp finalize_current_tool(%{current_tool: nil} = acc), do: acc

  defp finalize_current_tool(%{current_tool: tool} = acc) do
    arguments =
      case Jason.decode(tool.input_json) do
        {:ok, parsed} -> parsed
        _ -> %{}
      end

    tool_call = %{id: tool.id, name: tool.name, arguments: arguments}
    %{acc | tool_calls: [tool_call | acc.tool_calls], current_tool: nil}
  end

  defp fallback_to_sync(base_url, api_key, model, messages, callback, opts) do
    Logger.warning("Falling back to synchronous Anthropic chat")

    case do_chat(base_url, api_key, model, messages, opts) do
      {:ok, result} ->
        if result.content != "", do: callback.({:text_delta, result.content})
        callback.({:done, result})
        :ok

      {:error, _} = err ->
        err
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
