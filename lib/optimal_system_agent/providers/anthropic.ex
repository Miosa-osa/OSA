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

  # Anthropic 1M-token context beta (CC parity: src/utils/betas.ts +
  # src/utils/context.ts). Sent ONLY for the Claude models that support it and
  # only when not disabled, so the advertised context window (Providers.Registry)
  # and the request headers stay in lockstep.
  @context_1m_beta "context-1m-2025-08-07"

  @impl true
  def name, do: :anthropic

  alias OptimalSystemAgent.Providers.AnthropicModels

  @impl true
  def default_model, do: AnthropicModels.default_model()

  @impl true
  def available_models, do: AnthropicModels.ids()

  @impl true
  def chat(messages, opts \\ []) do
    case resolve_auth() do
      {:error, reason} ->
        {:error, reason}

      auth ->
        model =
          Keyword.get(opts, :model) ||
            Application.get_env(:optimal_system_agent, :anthropic_model, default_model())

        base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)
        do_chat(base_url, auth, model, messages, Keyword.delete(opts, :model))
    end
  end

  @impl true
  def chat_stream(messages, callback, opts \\ []) do
    case resolve_auth() do
      {:error, reason} ->
        {:error, reason}

      auth ->
        model =
          Keyword.get(opts, :model) ||
            Application.get_env(:optimal_system_agent, :anthropic_model, default_model())

        base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)
        do_chat_stream(base_url, auth, model, messages, callback, Keyword.delete(opts, :model))
    end
  end

  defp do_chat(base_url, auth, model, messages, opts) do
    formatted = format_messages(messages)
    {system_msgs, chat_msgs} = Enum.split_with(formatted, &(&1["role"] == "system"))
    system_text = Enum.map_join(system_msgs, "\n\n", &system_content_to_string(&1["content"]))
    thinking = normalize_thinking(Keyword.get(opts, :thinking), model)

    body =
      %{
        model: model,
        max_tokens: resolve_max_tokens(model, opts),
        messages: chat_msgs
      }
      |> maybe_add_system(system_text)
      |> maybe_add_tools(opts)
      |> maybe_add_thinking(thinking)
      # Keep the serialized body under Anthropic's request-size cap by evicting
      # the oldest inline images to an honest placeholder (see ImageBudget).
      # Strict no-op — body byte-for-byte unchanged — when already under budget.
      |> apply_image_budget(opts)

    headers = build_headers(auth, thinking, model)
    # Extended thinking can take 300+ s before producing output
    timeout = if thinking, do: 600_000, else: 120_000

    try do
      case Req.post("#{base_url}/messages", req_opts(body, headers, timeout, opts)) do
        {:ok, %{status: 200, body: resp}} ->
          content = extract_content(resp)
          tool_calls = extract_tool_calls(resp)
          usage = extract_usage(resp)
          thinking_blocks = extract_thinking(resp)

          result = %{
            content: content,
            tool_calls: tool_calls,
            usage: usage,
            stop_reason: resp["stop_reason"]
          }

          result =
            if thinking_blocks != [],
              do: Map.put(result, :thinking_blocks, thinking_blocks),
              else: result

          {:ok, result}

        {:ok, %{status: 429, headers: headers, body: resp_body}} ->
          retry_after = parse_retry_after(headers)
          error_msg = extract_error(resp_body)
          Logger.warning("Anthropic rate limited. retry-after: #{retry_after}s — #{error_msg}")
          {:error, {:rate_limited, retry_after}}

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

  defp do_chat_stream(base_url, auth, model, messages, callback, opts) do
    formatted = format_messages(messages)
    {system_msgs, chat_msgs} = Enum.split_with(formatted, &(&1["role"] == "system"))
    system_text = Enum.map_join(system_msgs, "\n\n", &system_content_to_string(&1["content"]))
    thinking = normalize_thinking(Keyword.get(opts, :thinking), model)

    body =
      %{
        model: model,
        max_tokens: resolve_max_tokens(model, opts),
        messages: chat_msgs,
        stream: true
      }
      |> maybe_add_system(system_text)
      |> maybe_add_tools(opts)
      |> maybe_add_thinking(thinking)
      # Keep the serialized body under Anthropic's request-size cap by evicting
      # the oldest inline images to an honest placeholder (see ImageBudget).
      # Strict no-op — body byte-for-byte unchanged — when already under budget.
      |> apply_image_budget(opts)

    headers = build_headers(auth, thinking, model)
    # Extended thinking can take 300+ s before producing the first token
    timeout = if thinking, do: 600_000, else: 120_000

    try do
      case Req.post("#{base_url}/messages", req_opts(body, headers, timeout, opts) ++ [into: :self]) do
        {:ok, %{status: 200} = resp} ->
          collect_stream(resp, callback, %{
            content: "",
            tool_calls: [],
            current_tool: nil,
            buffer: "",
            thinking: [],
            current_thinking: nil,
            stream_error: nil,
            stop_reason: nil,
            usage: %{
              input_tokens: 0,
              output_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0
            }
          })

        {:ok, %{status: 429} = resp} ->
          # Rate limited: Req still returns {:ok, _} with the error body streamed
          # as data chunks (no SSE events), which previously finalized as an empty
          # SUCCESS. Surface it as an error so Resilience/FallbackChain engage.
          Logger.warning("Anthropic stream HTTP 429 (rate limited)")
          drain_self_stream(resp)
          {:error, {:rate_limited, parse_retry_after(resp.headers)}}

        {:ok, %{status: status} = resp} ->
          Logger.warning("Anthropic stream HTTP #{status}")
          drain_self_stream(resp)
          {:error, "Anthropic stream HTTP #{status}"}

        {:error, reason} ->
          Logger.error("Anthropic stream connection failed: #{inspect(reason)}")
          fallback_to_sync(base_url, auth, model, messages, callback, opts)
      end
    rescue
      e ->
        Logger.error("Anthropic stream unexpected error: #{Exception.message(e)}")
        fallback_to_sync(base_url, auth, model, messages, callback, opts)
    end
  end

  @doc """
  Test seam: fold a list of already-decoded Anthropic SSE event maps (the
  shape produced by `parse_sse_chunk/1` after `Jason.decode`) through the
  exact same `process_stream_event/3` clauses the live stream uses, then
  finalize exactly as `collect_stream/3` does on `:done`. Lets tests exercise
  the real usage-accumulation logic (message_start/message_delta) without a
  live HTTP connection.
  """
  def accumulate_stream_events(events) when is_list(events) do
    init_acc = %{
      content: "",
      tool_calls: [],
      current_tool: nil,
      buffer: "",
      thinking: [],
      current_thinking: nil,
      stream_error: nil,
      stop_reason: nil,
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0
      }
    }

    noop_callback = fn _ -> :ok end

    acc =
      Enum.reduce(events, init_acc, fn event, a ->
        process_stream_event(event, noop_callback, a)
      end)

    acc = finalize_current_tool(acc)
    acc = finalize_current_thinking(acc)

    %{
      content: acc.content,
      tool_calls: Enum.reverse(acc.tool_calls),
      stop_reason: acc.stop_reason,
      usage: Map.get(acc, :usage, %{})
    }
  end

  defp collect_stream(resp, callback, acc) do
    receive do
      message ->
        # Req delivers `into: :self` chunks tagged with an internal ref. Use
        # Req.parse_message/2 to decode them — matching on `resp.body` directly
        # never matches (the messages are tagged with resp.body.ref, not the
        # struct), which previously hung the stream until the caller timed out.
        case Req.parse_message(resp, message) do
          {:ok, parts} ->
            {acc, done?} =
              Enum.reduce(parts, {acc, false}, fn
                {:data, data}, {inner, done?} ->
                  {events, new_buffer} = parse_sse_chunk(inner.buffer <> data)
                  inner = %{inner | buffer: new_buffer}

                  inner =
                    Enum.reduce(events, inner, fn event, a ->
                      process_stream_event(event, callback, a)
                    end)

                  {inner, done?}

                :done, {inner, _done?} ->
                  {inner, true}

                _other, state ->
                  state
              end)

            cond do
              # A streaming `error` event arrived mid-stream (e.g. overloaded_error).
              # This is NOT an HTTP status — the connection was already 200 OK.
              # Distinguish it and route to the retry path, preserving whatever
              # partial output was already streamed to the callback.
              acc.stream_error != nil ->
                Logger.warning("Anthropic mid-stream error: #{acc.stream_error}")
                {:error, {:stream_error, acc.stream_error, acc.content}}

              done? ->
                acc = finalize_current_tool(acc)
                acc = finalize_current_thinking(acc)

                result = %{
                  content: acc.content,
                  tool_calls: Enum.reverse(acc.tool_calls),
                  stop_reason: acc.stop_reason,
                  usage: Map.get(acc, :usage, %{})
                }

                result =
                  if acc.thinking != [],
                    do: Map.put(result, :thinking_blocks, Enum.reverse(acc.thinking)),
                    else: result

                callback.({:done, result})
                :ok

              true ->
                collect_stream(resp, callback, acc)
            end

          {:error, reason} ->
            Logger.error("Anthropic stream error: #{inspect(reason)}")
            {:error, "Stream error: #{inspect(reason)}"}

          :unknown ->
            # Not a message for this response (e.g. Finch pool internals) — skip.
            collect_stream(resp, callback, acc)
        end
    after
      620_000 ->
        Logger.error("Anthropic stream timeout after 620s")
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
          %{
            acc
            | current_thinking: %{acc.current_thinking | text: acc.current_thinking.text <> text}
          }
        else
          acc
        end

      %{"type" => "signature_delta", "signature" => sig} ->
        # Capture the thinking block's cryptographic signature. It is NOT needed
        # for display, but interleaved thinking REQUIRES it be echoed back
        # verbatim on the next tool round-trip (else Anthropic 400s and the
        # thinking-block prompt cache is broken). Store it on the in-flight
        # thinking block so finalize_current_thinking/1 can attach it.
        if acc.current_thinking do
          %{acc | current_thinking: Map.put(acc.current_thinking, :signature, sig)}
        else
          acc
        end

      %{"type" => "signature_delta"} ->
        # signature_delta without a signature payload — nothing to capture.
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

  defp process_stream_event(%{"type" => "content_block_stop"}, callback, acc) do
    # If a tool block just completed, emit it for streaming tool execution
    acc =
      if acc.current_tool do
        tool = acc.current_tool

        arguments =
          case Jason.decode(tool.input_json) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        tool_call = %{id: tool.id, name: tool.name, arguments: arguments}
        callback.({:tool_use_block, tool_call})
        %{acc | tool_calls: [tool_call | acc.tool_calls], current_tool: nil}
      else
        finalize_current_tool(acc)
      end

    finalize_current_thinking(acc)
  end

  defp process_stream_event(%{"type" => "message_stop"}, _callback, acc), do: acc

  # `message_start` carries the initial usage snapshot: input_tokens plus any
  # prompt-cache creation/read counts (output_tokens is 0/near-0 at this
  # point). Without this, streamed turns never see input/cache token counts
  # and Accounting.record always sees 0 (the "budget 0" root cause).
  defp process_stream_event(
         %{"type" => "message_start", "message" => %{"usage" => usage}},
         _callback,
         acc
       )
       when is_map(usage) do
    if Map.has_key?(acc, :usage), do: %{acc | usage: merge_stream_usage(acc.usage, usage)}, else: acc
  end

  defp process_stream_event(%{"type" => "message_start"}, _callback, acc), do: acc

  # The final `message_delta` carries the terminal stop_reason (e.g.
  # "max_tokens" when the response was truncated by the token limit) AND the
  # authoritative output_tokens count (top-level `usage`, not under `delta`).
  # Capture both so the loop's TRUNCATED-MESSAGE guard works and streamed
  # turns record real output token usage instead of 0.
  defp process_stream_event(
         %{"type" => "message_delta"} = event,
         _callback,
         acc
       ) do
    acc =
      case event["delta"] do
        %{"stop_reason" => stop_reason} when is_binary(stop_reason) ->
          if Map.has_key?(acc, :stop_reason), do: %{acc | stop_reason: stop_reason}, else: acc

        _ ->
          acc
      end

    case event["usage"] do
      usage when is_map(usage) ->
        if Map.has_key?(acc, :usage), do: %{acc | usage: merge_stream_usage(acc.usage, usage)}, else: acc

      _ ->
        acc
    end
  end

  defp process_stream_event(%{"type" => "ping"}, _callback, acc), do: acc

  # Mid-stream error event. The SSE stream opened 200 OK, then the server
  # emitted `event: error` (commonly `overloaded_error`). Record it on the
  # accumulator so `collect_stream/3` can stop and route to the retry path
  # instead of silently finalizing a truncated response as success.
  defp process_stream_event(%{"type" => "error"} = event, _callback, acc) do
    msg =
      case event["error"] do
        %{"message" => m} when is_binary(m) -> m
        %{"type" => t} when is_binary(t) -> t
        other -> inspect(other)
      end

    %{acc | stream_error: msg}
  end

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
    # Preserve the signature captured from signature_delta events so the block
    # can be re-serialized verbatim on the next interleaved-thinking round-trip.
    block = %{type: "thinking", thinking: thinking.text, signature: Map.get(thinking, :signature)}
    %{acc | thinking: [block | acc.thinking], current_thinking: nil}
  end

  # Handle accumulators without thinking fields (e.g., fallback sync path)
  defp finalize_current_thinking(acc), do: acc

  defp fallback_to_sync(base_url, auth, model, messages, callback, opts) do
    Logger.warning("Falling back to synchronous Anthropic chat")

    case do_chat(base_url, auth, model, messages, opts) do
      {:ok, result} ->
        if result.content != "", do: callback.({:text_delta, result.content})
        callback.({:done, result})
        :ok

      {:error, _} = err ->
        err
    end
  end

  # --- Private ---

  # Default output cap when the caller omits :max_tokens. Mirrors CC's per-model
  # defaults (getModelMaxOutputTokens); the old flat 8192 sat far below the
  # model ceiling and silently truncated long responses. Overridable via
  # :anthropic_max_tokens app env (ANTHROPIC / CLAUDE_CODE_MAX_OUTPUT_TOKENS).
  defp resolve_max_tokens(model, opts) do
    Keyword.get(opts, :max_tokens) ||
      Application.get_env(:optimal_system_agent, :anthropic_max_tokens) ||
      default_max_tokens(model)
  end

  # Single source of truth: Providers.AnthropicModels. The old hand-rolled
  # `cond` here was a third independent copy of the per-model output cap and
  # had already drifted — it returned 32_000 for claude-sonnet-4-6 while
  # ModelLimits returned 64_000, and this one is what actually sets max_tokens
  # on the wire, so long answers truncated at half the real ceiling.
  defp default_max_tokens(model) do
    case AnthropicModels.resolve(model) do
      nil ->
        m = String.downcase(to_string(model))
        if String.contains?(m, "claude-3"), do: 8_192, else: 32_000

      found ->
        found.max_output
    end
  end

  # Apply the image byte-budget. Normally eviction is gated at the provider cap;
  # when a header-aware retry decision asked for a 413 image-strip
  # (`opts[:strip_images]`), force a full strip (cap 0) so *all* inline images
  # are replaced with the honest placeholder before the retry.
  defp apply_image_budget(body, opts) do
    if Keyword.get(opts, :strip_images, false) do
      OptimalSystemAgent.Providers.ImageBudget.apply(body,
        provider: :anthropic,
        cap_bytes: 0,
        headroom_bytes: 0
      )
    else
      OptimalSystemAgent.Providers.ImageBudget.apply(body, provider: :anthropic)
    end
  end

  # Build the Req.post options keyword, honoring `:force_http1` (HTTP/1.1
  # client rebuild to escape a poisoned HTTP/2 pool on the first 5xx retry).
  defp req_opts(body, headers, timeout, opts) do
    base = [json: body, headers: headers, receive_timeout: timeout]

    if Keyword.get(opts, :force_http1, false) do
      Keyword.put(base, :connect_options, protocols: [:http1])
    else
      base
    end
  end

  @doc false
  def format_messages(messages) do
    Enum.map(messages, fn
      # Thinking blocks (possibly combined with tool_calls for interleaved-thinking turns)
      %{role: role, content: content, thinking_blocks: blocks} = msg
      when is_list(blocks) and blocks != [] ->
        thinking_content =
          blocks
          # Anthropic REJECTS unsigned thinking blocks on input (400). Only signed
          # blocks may be echoed back on a subsequent interleaved-thinking turn,
          # so drop any block whose signature was never captured rather than send
          # an invalid block. With the streaming signature-capture fix above,
          # real blocks are always signed; this only guards degenerate/legacy state.
          |> Enum.filter(fn block ->
            (block[:signature] || block["signature"]) not in [nil, ""]
          end)
          |> Enum.map(fn block ->
            %{
              "type" => "thinking",
              "thinking" => block[:thinking] || block["thinking"],
              "signature" => block[:signature] || block["signature"]
            }
          end)

        text_blocks =
          if to_string(content) != "",
            do: [%{"type" => "text", "text" => to_string(content)}],
            else: []

        # Include any tool_use blocks when thinking + tool_calls co-exist
        tool_blocks =
          case Map.get(msg, :tool_calls) do
            tcs when is_list(tcs) and tcs != [] ->
              Enum.map(tcs, fn tc ->
                %{
                  "type" => "tool_use",
                  "id" => tc[:id] || tc["id"],
                  "name" => tc[:name] || tc["name"],
                  "input" => tc[:arguments] || tc["arguments"] || %{}
                }
              end)

            _ ->
              []
          end

        %{"role" => to_string(role), "content" => thinking_content ++ text_blocks ++ tool_blocks}

      # Tool result with structured content (e.g., image + text)
      %{role: "tool", tool_call_id: id, content: content} when is_list(content) ->
        formatted_blocks =
          Enum.map(content, fn
            %{type: "image", source: source} ->
              %{
                "type" => "image",
                "source" => %{
                  "type" => source[:type] || source["type"],
                  "media_type" => source[:media_type] || source["media_type"],
                  "data" => source[:data] || source["data"]
                }
              }

            %{type: "text", text: text} ->
              %{"type" => "text", "text" => to_string(text)}

            other ->
              other
          end)

        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => to_string(id),
              "content" => formatted_blocks
            }
          ]
        }

      # Tool result with plain text content
      %{role: "tool", tool_call_id: id, content: content} ->
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => to_string(id),
              "content" => to_string(content)
            }
          ]
        }

      # Assistant message with tool_calls — format as Anthropic content blocks
      %{role: role, tool_calls: tool_calls} = msg
      when is_list(tool_calls) and tool_calls != [] ->
        content = Map.get(msg, :content, "")

        text_blocks =
          if to_string(content) != "",
            do: [%{"type" => "text", "text" => to_string(content)}],
            else: []

        tool_blocks =
          Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc[:id] || tc["id"],
              "name" => tc[:name] || tc["name"],
              "input" => tc[:arguments] || tc["arguments"] || %{}
            }
          end)

        %{"role" => to_string(role), "content" => text_blocks ++ tool_blocks}

      # Structured content blocks (images, mixed content in non-tool messages)
      %{role: role, content: content} when is_list(content) ->
        formatted_content =
          Enum.map(content, fn
            %{type: "image", source: source} ->
              %{
                "type" => "image",
                "source" => %{
                  "type" => source[:type] || source["type"],
                  "media_type" => source[:media_type] || source["media_type"],
                  "data" => source[:data] || source["data"]
                }
              }

            %{type: "text", text: text} ->
              %{"type" => "text", "text" => to_string(text)}

            other ->
              other
          end)

        %{"role" => to_string(role), "content" => formatted_content}

      # Regular text message
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => to_string(content)}

      %{"role" => _} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  # Normalize a system message's content to a plain string. Content may arrive
  # as a binary, or as a list of content blocks (e.g. [%{"text" => "..."}] or
  # [%{"type" => "text", "text" => "..."}]). map_join over raw list content
  # crashes with "cannot convert the given list to a string", so flatten here.
  defp system_content_to_string(content) when is_binary(content), do: content
  defp system_content_to_string(nil), do: ""

  defp system_content_to_string(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => t} when is_binary(t) -> t
      %{text: t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp system_content_to_string(other), do: to_string(other)

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
  Coerce a thinking config to the dialect `model` actually accepts.

  Belt-and-braces for `Agent.Loop.LLMClient.thinking_config/1`: any caller that
  hands us `{type: "enabled", budget_tokens: N}` for a model on which Anthropic
  removed the fixed budget (the Claude 5 family, Opus 4.7/4.8) would otherwise
  get a 400 rather than a degraded answer. Downgrading to `adaptive` here keeps
  thinking working instead of failing the whole request.
  """
  @spec normalize_thinking(map() | nil, String.t() | atom() | nil) :: map() | nil
  def normalize_thinking(nil, _model), do: nil

  def normalize_thinking(%{type: "enabled"} = thinking, model) do
    if AnthropicModels.thinking_mode(model) == :adaptive do
      %{type: "adaptive"}
    else
      thinking
    end
  end

  def normalize_thinking(thinking, _model), do: thinking

  @doc """
  True for Claude models that support the 1M-token context window beta, unless
  disabled via the `DISABLE_1M_CONTEXT` env var or `:disable_1m_context` config.

  Single source of truth: `Providers.Registry` consults this to decide the
  advertised context window, and `build_headers/3` consults it to decide whether
  to send the `context-1m` beta header — so the two can never disagree (a >200K
  prompt on sonnet-4-6/opus-4-6 either gets the beta or is budgeted at 200K).
  """
  @spec supports_1m?(String.t() | atom()) :: boolean()
  def supports_1m?(model) do
    AnthropicModels.context_window(model) == 1_000_000 and
      (not beta_gated_1m?(model) or not one_m_disabled?())
  end

  @doc """
  True only for models whose 1M window is gated behind the `context-1m` beta
  header.

  The Claude 4.6 generation needed that header to unlock 1M. The Claude 5
  family (and Opus 4.7/4.8) ship 1M as the DEFAULT window, so sending the beta
  for them is at best noise and at worst a rejected request — which is why the
  header decision is separate from `supports_1m?/1` (what window we advertise).
  """
  @spec needs_1m_beta?(String.t() | atom()) :: boolean()
  def needs_1m_beta?(model), do: beta_gated_1m?(model) and not one_m_disabled?()

  defp beta_gated_1m?(model) do
    m = String.downcase(to_string(model))
    String.contains?(m, "sonnet-4-6") or String.contains?(m, "opus-4-6")
  end

  defp one_m_disabled? do
    case System.get_env("DISABLE_1M_CONTEXT") do
      v when v in [nil, "", "0", "false", "no"] ->
        Application.get_env(:optimal_system_agent, :disable_1m_context, false) == true

      _ ->
        true
    end
  end

  @doc """
  Build request headers, adding interleaved-thinking beta when thinking is
  enabled and the context-1m beta for 1M-capable Claude models. `model` defaults
  to nil (no 1M beta) so pre-existing `build_headers/2` callers are unaffected.
  """
  def build_headers(auth, thinking, model \\ nil) do
    auth_header =
      case auth do
        {:oauth, token} ->
          [{"authorization", "Bearer #{token}"}, {"anthropic-beta", "oauth-2025-04-20"}]

        {:api_key, key} ->
          [{"x-api-key", key}]

        key when is_binary(key) ->
          [{"x-api-key", key}]
      end

    base =
      auth_header ++
        [
          {"anthropic-version", @api_version},
          {"content-type", "application/json"}
        ]

    # Collect beta features
    betas = []
    betas = if thinking, do: ["interleaved-thinking-2025-05-14" | betas], else: betas
    betas = if prompt_caching_enabled?(), do: ["prompt-caching-2024-07-31" | betas], else: betas
    betas = if model && needs_1m_beta?(model), do: [@context_1m_beta | betas], else: betas

    case betas do
      [] -> base
      _ -> [{"anthropic-beta", Enum.join(betas, ",")} | base]
    end
  end

  @doc """
  Resolve authentication — checks API key first, falls back to OAuth.

  Returns `{:api_key, key}`, `{:oauth, token}`, or `{:error, reason}`.
  """
  def resolve_auth do
    # Try credential pool first (supports key rotation)
    pool_key =
      try do
        OptimalSystemAgent.Providers.CredentialPool.get_key(:anthropic)
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    # `live_env/1` re-reads ~/.osa/.env on demand. Every other cloud provider
    # has this fallback (openai_compat_provider.ex, registry.ex) and Anthropic
    # did not — so a key written by the standalone `mix osa.setup.wizard`
    # subprocess (whose put_env dies with the subprocess) stayed invisible to
    # Anthropic until the whole daemon restarted, even though the setup flow
    # reported success.
    api_key =
      pool_key ||
        Application.get_env(:optimal_system_agent, :anthropic_api_key) ||
        OptimalSystemAgent.Onboarding.live_env("ANTHROPIC_API_KEY")

    cond do
      is_binary(api_key) and api_key != "" ->
        {:api_key, api_key}

      true ->
        case OptimalSystemAgent.Auth.OAuth.get_valid_token() do
          {:ok, token} ->
            {:oauth, token}

          {:error, _} ->
            # Phrased so `ErrorCatalog.missing_api_key?/1` (which matches "not
            # configured") catches it — previously "No Anthropic API key or
            # OAuth token configured." fell through that matcher (the word
            # "not" never appeared) and got classified :unknown, skipping the
            # actionable `osa setup`/env-var guidance for exactly the provider
            # a Claude-first user is most likely to hit first (P4). Leads with
            # "ANTHROPIC_API_KEY" so the message-level regex
            # (`missing_api_key_message/1`) also names the right env var.
            {:error,
             "ANTHROPIC_API_KEY not configured (no API key or OAuth token). Run `osa setup` " <>
               "or set ANTHROPIC_API_KEY."}
        end
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

  # Merge a raw Anthropic SSE `usage` object (string keys, only the fields
  # present on that particular event) into the running stream accumulator
  # (atom keys). Anthropic sends each field's authoritative total (not a
  # delta to add), so a present key overwrites; an absent key keeps the
  # prior value. `message_start` supplies input/cache tokens up front,
  # `message_delta` supplies the final output_tokens.
  defp merge_stream_usage(acc_usage, usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || acc_usage.input_tokens,
      output_tokens: usage["output_tokens"] || acc_usage.output_tokens,
      cache_creation_input_tokens:
        usage["cache_creation_input_tokens"] || acc_usage.cache_creation_input_tokens,
      cache_read_input_tokens:
        usage["cache_read_input_tokens"] || acc_usage.cache_read_input_tokens
    }
  end

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body), do: inspect(body)

  # Parse Retry-After header — supports both integer seconds and HTTP date formats
  defp parse_retry_after(headers) when is_list(headers) do
    case List.keyfind(headers, "retry-after", 0) || List.keyfind(headers, "Retry-After", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, _} -> seconds
          :error -> 60
        end

      nil ->
        unified_reset_seconds(headers) || 60
    end
  end

  # Req 0.5.x returns response headers as a MAP (%{"retry-after" => ["30"]}),
  # not a keyword list. Without this clause a real 429 falls through to the
  # catch-all and always waits 60s, ignoring the provider's Retry-After.
  defp parse_retry_after(headers) when is_map(headers) do
    case headers["retry-after"] || headers["Retry-After"] do
      [v | _] -> parse_seconds(v)
      v when is_binary(v) -> parse_seconds(v)
      _ -> unified_reset_seconds(headers) || 60
    end
  end

  defp parse_retry_after(_), do: 60

  # Rate-limit surfacing (CC claudeAiLimits parity): when no Retry-After
  # header is present, `anthropic-ratelimit-unified-reset` (unix seconds)
  # says when the quota window resets. Convert it to an effective retry-after
  # so both the backoff and the user-facing rate-limit message reflect the
  # real reset time instead of a blind 60s guess.
  defp unified_reset_seconds(headers) do
    raw =
      case headers do
        h when is_list(h) ->
          case List.keyfind(h, "anthropic-ratelimit-unified-reset", 0) do
            {_, v} -> v
            nil -> nil
          end

        h when is_map(h) ->
          case h["anthropic-ratelimit-unified-reset"] do
            [v | _] -> v
            v when is_binary(v) -> v
            _ -> nil
          end

        _ ->
          nil
      end

    with v when is_binary(v) <- raw,
         {reset_unix, _} <- Integer.parse(v) do
      max(reset_unix - System.os_time(:second), 1)
    else
      _ -> nil
    end
  end

  defp parse_seconds(v) when is_binary(v) do
    case Integer.parse(v) do
      {seconds, _} -> seconds
      :error -> 60
    end
  end

  defp parse_seconds(_), do: 60

  # Drain a Req `into: :self` streamed response body so mailbox messages tagged
  # with the response ref don't leak after we've decided to error out on a
  # non-200 status. Best-effort with a short bound.
  defp drain_self_stream(resp) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, parts} ->
            if Enum.any?(parts, &(&1 == :done)), do: :ok, else: drain_self_stream(resp)

          _ ->
            drain_self_stream(resp)
        end
    after
      2_000 -> :ok
    end
  end

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
