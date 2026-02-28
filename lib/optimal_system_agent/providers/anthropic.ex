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
  def available_models do
    ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
  end

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :anthropic_model, default_model())

    base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      do_chat(base_url, api_key, model, messages, Keyword.delete(opts, :model))
    end
  end

  @impl true
  def chat_stream(messages, callback, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :anthropic_model, default_model())

    base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      do_chat_stream(base_url, api_key, model, messages, callback, Keyword.delete(opts, :model))
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    formatted = format_messages(messages)
    {system_msgs, chat_msgs} = Enum.split_with(formatted, &(&1["role"] == "system"))
    system_text = Enum.map_join(system_msgs, "\n\n", & &1["content"])
    thinking = Keyword.get(opts, :thinking)

    body =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        messages: chat_msgs
      }
      |> maybe_add_system(system_text)
      |> maybe_add_tools(opts)
      |> maybe_add_thinking(thinking)

    headers = build_headers(api_key, thinking)

    try do
      case Req.post("#{base_url}/messages",
             json: body,
             headers: headers,
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          content = extract_content(resp)
          tool_calls = extract_tool_calls(resp)
          usage = extract_usage(resp)
          thinking_blocks = extract_thinking(resp)

          result = %{content: content, tool_calls: tool_calls, usage: usage}
          result = if thinking_blocks != [], do: Map.put(result, :thinking_blocks, thinking_blocks), else: result
          {:ok, result}

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
    thinking = Keyword.get(opts, :thinking)

    body =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        messages: chat_msgs,
        stream: true
      }
      |> maybe_add_system(system_text)
      |> maybe_add_tools(opts)
      |> maybe_add_thinking(thinking)

    headers = build_headers(api_key, thinking)

    try do
      case Req.post("#{base_url}/messages",
             json: body,
             headers: headers,
             receive_timeout: 120_000,
             into: :self
           ) do
        {:ok, resp} ->
          collect_stream(resp, callback, %{
            content: "",
            tool_calls: [],
            current_tool: nil,
            buffer: "",
            thinking: [],
            current_thinking: nil
          })

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
        # Finalize any in-progress tool call or thinking block
        acc = finalize_current_tool(acc)
        acc = finalize_current_thinking(acc)

        result = %{content: acc.content, tool_calls: Enum.reverse(acc.tool_calls)}
        result = if acc.thinking != [], do: Map.put(result, :thinking_blocks, Enum.reverse(acc.thinking)), else: result
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

  defp process_stream_event(
         %{"type" => "content_block_start", "content_block" => block},
         callback,
         acc
       ) do
    case block do
      %{"type" => "text"} ->
        acc

      %{"type" => "thinking"} ->
        acc = finalize_current_thinking(acc)
        callback.({:thinking_start, %{}})
        %{acc | current_thinking: %{text: ""}}

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

      %{"type" => "thinking_delta", "thinking" => text} ->
        callback.({:thinking_delta, text})

        if acc.current_thinking do
          %{acc | current_thinking: %{acc.current_thinking | text: acc.current_thinking.text <> text}}
        else
          acc
        end

      %{"type" => "signature_delta"} ->
        # Signature deltas are not needed for display — skip
        acc

      %{"type" => "input_json_delta", "partial_json" => json_chunk} ->
        callback.({:tool_use_delta, json_chunk})

        if acc.current_tool do
          updated_tool = %{
            acc.current_tool
            | input_json: acc.current_tool.input_json <> json_chunk
          }

          %{acc | current_tool: updated_tool}
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp process_stream_event(%{"type" => "content_block_stop"}, _callback, acc) do
    acc
    |> finalize_current_tool()
    |> finalize_current_thinking()
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

  defp finalize_current_thinking(%{current_thinking: nil} = acc), do: acc

  defp finalize_current_thinking(%{current_thinking: thinking} = acc) do
    block = %{type: "thinking", thinking: thinking.text, signature: nil}
    %{acc | thinking: [block | acc.thinking], current_thinking: nil}
  end

  # Handle accumulators without thinking fields (e.g., fallback sync path)
  defp finalize_current_thinking(acc), do: acc

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

  @doc false
  def format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content, thinking_blocks: blocks} when is_list(blocks) and blocks != [] ->
        # When assistant message has thinking blocks, include them as content blocks
        # (required by Anthropic API for tool use turns with thinking)
        thinking_content =
          Enum.map(blocks, fn block ->
            base = %{"type" => "thinking", "thinking" => block.thinking || block[:thinking]}
            if block[:signature] || block.signature, do: Map.put(base, "signature", block.signature || block[:signature]), else: base
          end)

        text_content = [%{"type" => "text", "text" => to_string(content)}]
        %{"role" => to_string(role), "content" => thinking_content ++ text_content}

      %{role: role, content: content} when is_list(content) ->
        # Structured content blocks (images, mixed text+image tool results)
        formatted_content = Enum.map(content, fn
          %{type: "image", source: source} ->
            %{"type" => "image", "source" => %{
              "type" => source.type || source[:type],
              "media_type" => source.media_type || source[:media_type],
              "data" => source.data || source[:data]
            }}
          %{type: "text", text: text} ->
            %{"type" => "text", "text" => to_string(text)}
          other ->
            other
        end)
        %{"role" => to_string(role), "content" => formatted_content}

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

  defp maybe_add_system(body, system_text) do
    if prompt_caching_enabled?() do
      # Split system prompt into cacheable blocks.
      # Anthropic caches from the end of the last cache_control marker,
      # so we mark the full system text as one ephemeral cached block.
      # Minimum cacheable size is 1024 tokens (~4K chars).
      if byte_size(system_text) >= 4_000 do
        Map.put(body, :system, [
          %{type: "text", text: system_text, cache_control: %{type: "ephemeral"}}
        ])
      else
        Map.put(body, :system, system_text)
      end
    else
      Map.put(body, :system, system_text)
    end
  end

  defp prompt_caching_enabled? do
    Application.get_env(:optimal_system_agent, :prompt_caching_enabled, true)
  end

  @doc """
  Add extended thinking configuration to request body.
  No-ops when thinking is nil.
  """
  def maybe_add_thinking(body, nil), do: body

  def maybe_add_thinking(body, %{type: "adaptive"}) do
    Map.put(body, :thinking, %{type: "adaptive"})
  end

  def maybe_add_thinking(body, %{type: "enabled", budget_tokens: budget}) do
    # Anthropic requires minimum 1024 budget tokens
    budget = max(budget, 1024)
    Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})
  end

  def maybe_add_thinking(body, _), do: body

  @doc """
  Build request headers, adding interleaved-thinking beta when thinking is enabled.
  """
  def build_headers(api_key, thinking) do
    base = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    # Collect beta features
    betas = []
    betas = if thinking, do: ["interleaved-thinking-2025-05-14" | betas], else: betas
    betas = if prompt_caching_enabled?(), do: ["prompt-caching-2024-07-31" | betas], else: betas

    case betas do
      [] -> base
      _ -> [{"anthropic-beta", Enum.join(betas, ",")} | base]
    end
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

  @doc "Extract thinking blocks from Anthropic response."
  def extract_thinking(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "thinking"))
    |> Enum.map(fn block ->
      %{
        type: "thinking",
        thinking: block["thinking"],
        signature: block["signature"]
      }
    end)
  end

  def extract_thinking(_), do: []

  @doc "Extract usage including cache tokens."
  def extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
      cache_read_input_tokens: usage["cache_read_input_tokens"] || 0
    }
  end

  def extract_usage(_), do: %{}

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body), do: inspect(body)

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
