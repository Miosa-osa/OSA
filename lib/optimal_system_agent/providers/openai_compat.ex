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

  alias OptimalSystemAgent.Providers.ThinkStreamParser
  alias OptimalSystemAgent.Providers.ToolCallParsers
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

  @doc """
  Streaming chat completion for OpenAI-compatible endpoints.

  Sends SSE-streamed tokens to the callback as `{:text_delta, text}`,
  `{:thinking_delta, text}`, and `{:done, result}`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec chat_stream(String.t(), String.t() | nil, String.t(), list(), function(), keyword()) ::
          :ok | {:error, String.t()}
  def chat_stream(base_url, api_key, model, messages, callback, opts) do
    unless api_key do
      {:error, "API key not configured"}
    else
      do_chat_stream(base_url, api_key, model, messages, callback, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    body =
      %{
        model: model,
        messages: format_messages(messages) |> maybe_strip_images(opts)
      }
      |> OptimalSystemAgent.Providers.ImageBudget.gate_unsupported(:openai, model)
      |> OptimalSystemAgent.Providers.ImageBudget.apply(provider: :openai)
      |> maybe_add_temperature(model, opts)
      |> maybe_add_tools(opts)
      |> maybe_add_max_tokens(model, opts)
      |> maybe_add_reasoning(model, opts)
      # LAST: DeepSeek accepts only low/high/max, so this must overwrite the
      # generic "medium" that maybe_add_reasoning/3 would otherwise leave.
      |> maybe_add_provider_thinking(model, opts, base_url)
      |> maybe_add_prompt_cache_key(opts, base_url)

    extra_headers = Keyword.get(opts, :extra_headers, [])

    headers =
      [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ] ++ extra_headers

    url = "#{base_url}/chat/completions"
    # Reasoning models (o3, deepseek-reasoner, etc.) need 300+ s for chain-of-thought
    timeout = Keyword.get(opts, :receive_timeout, 120_000)

    try do
      case Req.post(url, req_opts(body, headers, timeout, opts)) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} = choice | _]} = resp}} ->
          raw_content = msg["content"] || ""
          tool_calls = parse_tool_calls(msg, model)

          # Strip XML tool-call markup from content when calls were parsed from text (not tool_calls field)
          content =
            if tool_calls != [] and not Map.has_key?(msg, "tool_calls") do
              strip_tool_call_markup(raw_content)
            else
              raw_content
            end
            |> Text.strip_thinking_tokens()

          usage = parse_usage(resp)

          {:ok,
           %{
             content: content,
             tool_calls: tool_calls,
             usage: usage,
             stop_reason: choice["finish_reason"]
           }}

        {:ok, %{status: 429, body: resp_body, headers: resp_headers}} ->
          retry_after = parse_retry_after(resp_headers)
          error_msg = extract_error_message(resp_body)
          Logger.warning("Rate limited by provider (HTTP 429): #{error_msg}")
          {:error, {:rate_limited, retry_after}}

        # A 200 whose body did not match the JSON shape above. The common cause
        # is a gateway that only speaks SSE and answers a non-streaming request
        # with an event stream anyway: the body decodes to a BINARY, falls
        # through to the clause below, and `extract_error_message/1` renders it
        # as `inspect(body)` — a wall of escaped `data: {...}` frames presented
        # to the user as the error message, for a request that in fact
        # succeeded. OSA already has the inverse recovery (stream → sync, in
        # `Registry.stream_with_fallback/5`); this is the missing direction.
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          if sse_body?(body) do
            Logger.info(
              "OpenAI-compat endpoint answered a non-streaming request with SSE — " <>
                "re-issuing as a stream and collecting the result"
            )

            collect_via_stream(base_url, api_key, model, messages, opts)
          else
            {:error, "HTTP 200 with an unrecognized body: #{String.slice(body, 0, 500)}"}
          end

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

  # An SSE payload, not JSON: OpenAI-compatible streams are `data: {...}` lines
  # and terminate with `data: [DONE]`.
  defp sse_body?(body) do
    trimmed = String.trim_leading(body)
    String.starts_with?(trimmed, "data:") or String.starts_with?(trimmed, "event:")
  end

  # Re-issue the request as a real stream and fold the deltas back into the
  # single `{:ok, result}` the sync caller is waiting for. The caller asked for
  # a whole answer, so nothing is emitted anywhere — this is a transport
  # workaround, not a delivery change.
  defp collect_via_stream(base_url, api_key, model, messages, opts) do
    parent = self()
    ref = make_ref()

    callback = fn
      {:done, result} -> send(parent, {ref, :done, result})
      _ -> :ok
    end

    case do_chat_stream(base_url, api_key, model, messages, callback, opts) do
      :ok ->
        receive do
          {^ref, :done, result} -> {:ok, result}
        after
          0 -> {:error, "SSE recovery: stream completed without a result"}
        end

      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} ->
        {:error, "SSE recovery failed: #{inspect(reason)}"}

      other ->
        {:error, "SSE recovery failed: #{inspect(other)}"}
    end
  end

  # ── Streaming implementation ───────────────────────────────────────────

  @doc """
  Build the streaming request body. Public (not just `defp`) so tests can
  assert the request actually asks for usage on the stream — the P2 fix:
  without `stream_options.include_usage`, OpenAI-compatible backends omit
  `usage` from every streamed response and Accounting.record always sees 0
  tokens.
  """
  def build_stream_body(model, messages, opts, base_url \\ nil) do
    %{
      model: model,
      messages: format_messages(messages) |> maybe_strip_images(opts),
      stream: true,
      # Ask OpenAI-compatible backends to emit a final `usage` chunk on the
      # stream (off by default per the OpenAI streaming API). Without this,
      # `usage` never arrives and Accounting.record sees 0 tokens for every
      # streamed turn. Servers that ignore the flag (some Ollama/local
      # builds) fall back to the char/token estimate in finalize_sse_stream/4.
      stream_options: %{include_usage: true}
    }
    |> OptimalSystemAgent.Providers.ImageBudget.gate_unsupported(:openai, model)
    |> OptimalSystemAgent.Providers.ImageBudget.apply(provider: :openai)
    |> maybe_add_temperature(model, opts)
    |> maybe_add_tools(opts)
    |> maybe_add_max_tokens(model, opts)
    |> maybe_add_reasoning(model, opts)
    # LAST: DeepSeek accepts only low/high/max, so this must overwrite the
    # generic "medium" that maybe_add_reasoning/3 would otherwise leave.
    |> maybe_add_provider_thinking(model, opts, base_url)
    |> maybe_add_prompt_cache_key(opts, base_url)
  end

  @doc """
  Assert cache identity to the server instead of leaving it to be inferred.

  Codex keys the provider cache on the **session id** (`prompt_cache_key`
  defaults to the session's id and is regenerated never), which is simpler and
  more robust than trying to keep a derived value byte-stable. OSA sends the
  same thing: the session id, stable for the whole thread.

  Gated by host allowlist, default `["api.openai.com"]`. `prompt_cache_key` is
  an OpenAI field, and many OpenAI-*compatible* servers (local Ollama builds,
  gateways, proxies) reject unknown top-level body fields with a 400 — sending
  it everywhere would trade a cache hint for broken requests on those
  endpoints. Widen `:prompt_cache_key_hosts` only for a host observed to accept
  it.
  """
  @spec maybe_add_prompt_cache_key(map(), keyword(), String.t()) :: map()
  def maybe_add_prompt_cache_key(body, opts, base_url) do
    key = Keyword.get(opts, :prompt_cache_key) || Keyword.get(opts, :session_id)

    if prompt_cache_key_host?(base_url) and is_binary(key) and key != "" do
      Map.put(body, :prompt_cache_key, key)
    else
      body
    end
  end

  @doc "True when this endpoint's host is allowlisted for `prompt_cache_key`."
  @spec prompt_cache_key_host?(String.t() | nil) :: boolean()
  def prompt_cache_key_host?(base_url) when is_binary(base_url) do
    allowed =
      Application.get_env(:optimal_system_agent, :prompt_cache_key_hosts, ["api.openai.com"])

    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> host in allowed
      _ -> false
    end
  end

  def prompt_cache_key_host?(_), do: false

  defp do_chat_stream(base_url, api_key, model, messages, callback, opts) do
    body = build_stream_body(model, messages, opts, base_url)

    extra_headers = Keyword.get(opts, :extra_headers, [])

    headers =
      [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ] ++ extra_headers

    url = "#{base_url}/chat/completions"
    timeout = Keyword.get(opts, :receive_timeout, 600_000)

    # Accumulator for streamed data (stored in process dictionary like Ollama)
    stream_key = {__MODULE__, :stream, make_ref()}

    Process.put(stream_key, %{
      buffer: "",
      content: "",
      # index → %{id, name, arguments_json}
      tool_calls: %{},
      usage: %{},
      finish_reason: nil,
      # Streaming splitter for inline <think>…</think> reasoning tags (GLM et al.)
      think: ThinkStreamParser.new()
    })

    into = fn {:data, data}, {req, resp} ->
      acc = Process.get(stream_key)
      acc = handle_sse_chunk(data, callback, acc)
      Process.put(stream_key, acc)
      {:cont, {req, resp}}
    end

    try do
      case Req.post(url, req_opts(body, headers, timeout, opts) ++ [into: into]) do
        {:ok, %{status: status} = resp} when status != 200 ->
          # Non-200: Req still returns {:ok, _} and the error JSON body was fed
          # to the `into` callback (no `data:` prefix, so no SSE events emitted).
          # Finalizing here would report an empty SUCCESS, defeating retry-after
          # handling and provider fallback. Surface it as an error instead.
          acc = Process.get(stream_key)
          Process.delete(stream_key)

          if status == 429 do
            Logger.warning("OpenAI-compat stream HTTP 429 (rate limited)")
            {:error, {:rate_limited, parse_retry_after(resp.headers)}}
          else
            Logger.warning("OpenAI-compat stream HTTP #{status}")
            {:error, "HTTP #{status}: #{extract_stream_error(acc)}"}
          end

        {:ok, _resp} ->
          acc = Process.get(stream_key)
          Process.delete(stream_key)
          finalize_sse_stream(acc, callback, model, messages)

        {:error, reason} ->
          Process.delete(stream_key)
          Logger.error("OpenAI-compat stream failed: #{inspect(reason)}")
          {:error, "Stream connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Process.delete(stream_key)
        Logger.error("OpenAI-compat stream error: #{Exception.message(e)}")
        {:error, "Stream error: #{Exception.message(e)}"}
    end
  end

  @doc """
  Test seam: drive the exact same SSE-chunk handling and finalization used by
  `do_chat_stream/6` from a list of raw `data: {...}` text chunks, without a
  live HTTP connection. Returns the finalized `{:done, result}` payload.
  Lets tests exercise the real usage-parsing (`stream_options.include_usage`
  response) and the estimate-fallback path.
  """
  def stream_from_sse_chunks(data_chunks, model \\ "gpt-4o", messages \\ [])
      when is_list(data_chunks) do
    test_pid = self()
    callback = fn msg -> send(test_pid, {:sse_test_callback, msg}) end

    init_acc = %{
      buffer: "",
      content: "",
      tool_calls: %{},
      usage: %{},
      finish_reason: nil,
      think: ThinkStreamParser.new()
    }

    acc =
      Enum.reduce(data_chunks, init_acc, fn data, a -> handle_sse_chunk(data, callback, a) end)

    finalize_sse_stream(acc, callback, model, messages)

    receive do
      {:sse_test_callback, {:done, result}} -> result
    after
      1_000 -> raise "stream_from_sse_chunks/3: no :done callback received"
    end
  end

  # Parse SSE data lines. OpenAI SSE format:
  #   data: {"choices":[{"delta":{"content":"tok"}}]}
  #   data: [DONE]
  defp handle_sse_chunk(data, callback, acc) do
    {lines, new_buffer} = split_sse_lines(acc.buffer <> data)
    acc = %{acc | buffer: new_buffer}
    Enum.reduce(lines, acc, &process_sse_line(&1, callback, &2))
  end

  defp split_sse_lines(data) do
    lines = String.split(data, "\n")
    {complete, [remainder]} = Enum.split(lines, -1)
    # Only keep lines starting with "data:" — skip comments, empty lines, event: lines
    sse_data =
      complete
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> rest -> String.trim_leading(rest) end)

    {sse_data, remainder}
  end

  defp process_sse_line("[DONE]", _callback, acc), do: acc

  defp process_sse_line(json_str, callback, acc) do
    case Jason.decode(json_str) do
      {:ok, %{"choices" => [%{"delta" => delta} = choice | _]} = chunk} ->
        acc = process_delta(delta, callback, acc)

        # Capture the terminal finish_reason ("length" when truncated by the
        # token limit) so the loop's TRUNCATED-MESSAGE guard can refuse partial
        # tool calls.
        acc =
          case choice["finish_reason"] do
            fr when is_binary(fr) -> %{acc | finish_reason: fr}
            _ -> acc
          end

        # Capture usage if present (some providers send it in the final chunk)
        case chunk do
          %{"usage" => %{"prompt_tokens" => _, "completion_tokens" => _} = u} ->
            %{acc | usage: stream_usage(u)}

          _ ->
            acc
        end

      {:ok, %{"usage" => %{"prompt_tokens" => _, "completion_tokens" => _} = u}} ->
        %{acc | usage: stream_usage(u)}

      # `inspect/1` rather than interpolation: a non-binary `message` here would
      # raise inside the SSE accumulator and kill the whole stream over a log line.
      {:ok, %{"error" => %{"message" => msg}}} ->
        Logger.error(
          "OpenAI-compat stream error: #{if is_binary(msg), do: msg, else: inspect(msg)}"
        )

        acc

      {:error, _} ->
        # Malformed JSON — skip
        acc

      _ ->
        acc
    end
  end

  defp process_delta(delta, callback, acc) do
    # Text content
    acc =
      case delta do
        %{"content" => text} when is_binary(text) and text != "" ->
          full = acc.content <> text

          # Suppress XML tool-call markup from streaming output — it will be stripped in finalize
          if xml_tool_call_content?(full) do
            %{acc | content: full}
          else
            # Split inline <think>…</think> reasoning out of the visible stream:
            # reasoning is routed to the thinking box, the tags + reasoning are
            # stripped from what the user sees. Handled streaming (tags may span
            # chunks) — see ThinkStreamParser.
            {visible, thinking, think_state} = ThinkStreamParser.feed(acc.think, text)
            if thinking != "", do: callback.({:thinking_delta, thinking})
            if visible != "", do: callback.({:text_delta, visible})
            %{acc | content: full, think: think_state}
          end

        _ ->
          acc
      end

    # Reasoning/thinking content (DeepSeek and some providers)
    acc =
      case delta do
        %{"reasoning_content" => text} when is_binary(text) and text != "" ->
          callback.({:thinking_delta, text})
          acc

        _ ->
          acc
      end

    # Tool call deltas — accumulate across chunks.
    # OpenAI streams tool calls as: index, id (first chunk), function.name (first),
    # function.arguments (subsequent chunks, partial JSON).
    case delta do
      %{"tool_calls" => tool_deltas} when is_list(tool_deltas) ->
        Enum.reduce(tool_deltas, acc, fn tc_delta, a ->
          idx = tc_delta["index"] || 0
          existing = Map.get(a.tool_calls, idx, %{id: nil, name: "", arguments_json: ""})

          updated =
            existing
            |> maybe_set_id(tc_delta)
            |> maybe_append_name(tc_delta)
            |> maybe_append_args(tc_delta)

          %{a | tool_calls: Map.put(a.tool_calls, idx, updated)}
        end)

      _ ->
        acc
    end
  end

  defp maybe_set_id(tc, %{"id" => id}) when is_binary(id), do: %{tc | id: id}
  defp maybe_set_id(tc, _), do: tc

  defp maybe_append_name(tc, %{"function" => %{"name" => name}}) when is_binary(name),
    do: %{tc | name: tc.name <> name}

  defp maybe_append_name(tc, _), do: tc

  defp maybe_append_args(tc, %{"function" => %{"arguments" => args}}) when is_binary(args),
    do: %{tc | arguments_json: tc.arguments_json <> args}

  defp maybe_append_args(tc, _), do: tc

  defp finalize_sse_stream(acc, callback, model, orig_messages) do
    # Drain any tag tail the streaming splitter was holding back, so the live
    # display never loses trailing characters at end-of-stream.
    case Map.get(acc, :think) do
      %ThinkStreamParser{} = ts ->
        {leftover_vis, leftover_think, _} = ThinkStreamParser.flush(ts)
        if leftover_think != "", do: callback.({:thinking_delta, leftover_think})
        if leftover_vis != "", do: callback.({:text_delta, leftover_vis})

      _ ->
        :ok
    end

    content = Text.strip_thinking_tokens(acc.content)

    # Build tool_calls from accumulated deltas
    streamed_tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        args =
          case Jason.decode(tc.arguments_json) do
            {:ok, parsed} when is_map(parsed) -> parsed
            _ -> %{}
          end

        %{
          id: tc.id || generate_id(),
          name: tc.name |> normalize_tool_name(),
          arguments: args
        }
      end)

    # Fallback: parse tool calls from content if none streamed
    {tool_calls, content} =
      if streamed_tool_calls != [] do
        {streamed_tool_calls, content}
      else
        parsed =
          case ToolCallParsers.parse(acc.content, model) do
            [] -> parse_tool_calls_from_content(acc.content)
            calls -> calls
          end

        if parsed != [] do
          clean = acc.content |> strip_tool_call_markup() |> Text.strip_thinking_tokens()
          {parsed, clean}
        else
          {[], content}
        end
      end

    # Some OpenAI-compatible backends (certain Ollama/local builds) ignore
    # `stream_options.include_usage` and never send a usage chunk, leaving
    # acc.usage == %{}. Rather than record a flat 0 (the bug this fixes),
    # fall back to the same char/token heuristic the rest of the codebase
    # already uses for budgeting (Agent.Context.estimate_tokens*).
    usage = estimate_usage_fallback(acc.usage, orig_messages, content)

    result = %{
      content: content,
      tool_calls: tool_calls,
      usage: usage,
      stop_reason: Map.get(acc, :finish_reason)
    }

    callback.({:done, result})
    :ok
  end

  defp estimate_usage_fallback(usage, messages, content) when is_map(usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    if input > 0 or output > 0 do
      usage
    else
      %{
        input_tokens: OptimalSystemAgent.Agent.Context.estimate_tokens_messages(messages),
        output_tokens: OptimalSystemAgent.Agent.Context.estimate_tokens(content),
        estimated: true
      }
    end
  end

  defp estimate_usage_fallback(_usage, messages, content) do
    %{
      input_tokens: OptimalSystemAgent.Agent.Context.estimate_tokens_messages(messages),
      output_tokens: OptimalSystemAgent.Agent.Context.estimate_tokens(content),
      estimated: true
    }
  end

  # Build the Req.post options keyword, honoring a header-aware retry decision:
  # `:force_http1` forces the request onto HTTP/1.1 (via Mint's `:protocols`)
  # to escape a poisoned HTTP/2 connection pool on the first 5xx retry.
  defp req_opts(body, headers, timeout, opts) do
    base = [json: body, headers: headers, receive_timeout: timeout]

    if Keyword.get(opts, :force_http1, false) do
      Keyword.put(base, :connect_options, protocols: [:http1])
    else
      base
    end
  end

  # Strip inline images from already-wire-formatted messages (413 recovery).
  # Replaces each `image_url` content part with an honest text placeholder so
  # the model does not hallucinate the removed image's contents.
  defp maybe_strip_images(wire_messages, opts) do
    if Keyword.get(opts, :strip_images, false) do
      Enum.map(wire_messages, &strip_message_images/1)
    else
      wire_messages
    end
  end

  @image_placeholder "[An image was removed to keep the request within its size limit. Do not describe or reason about its contents; ask the user to re-share it if needed.]"

  defp strip_message_images(%{"content" => content} = msg) when is_list(content) do
    new_content =
      Enum.map(content, fn
        %{"type" => "image_url"} -> %{"type" => "text", "text" => @image_placeholder}
        %{type: "image_url"} -> %{"type" => "text", "text" => @image_placeholder}
        other -> other
      end)

    Map.put(msg, "content", new_content)
  end

  defp strip_message_images(msg), do: msg

  @doc "Format messages into the OpenAI wire format."
  def format_messages(messages) do
    Enum.map(messages, fn
      # Tool result messages — preserve tool_call_id and name for the API.
      # `name` identifies which function produced this result; Groq and some
      # OpenAI-compat providers require it to match the original tool call on
      # iteration 2+ (Bug 5: tool name mismatch on 2nd iteration).
      %{role: "tool", content: content, tool_call_id: id} = msg ->
        base = %{
          "role" => "tool",
          # `encode_text/1`, not `to_string/1`: a `tool` turn's content can be a
          # block list (ToolExecutor's screenshot branch emits text + image),
          # and the OpenAI `tool` role accepts only a string — so blocks are
          # flattened to text with an honest note where the image was.
          "content" => encode_text_preserving_cache(content),
          "tool_call_id" => to_string(id)
        }

        case Map.get(msg, :name) do
          nil -> base
          name -> Map.put(base, "name", to_string(name))
        end

      # Assistant messages with tool_calls — preserve structured tool calls
      %{role: "assistant", content: content, tool_calls: calls}
      when is_list(calls) and calls != [] ->
        msg = %{"role" => "assistant", "content" => encode_text_preserving_cache(content)}

        formatted_calls =
          Enum.map(calls, fn tc ->
            %{
              "id" => to_string(tc[:id] || tc["id"] || ""),
              "type" => "function",
              "function" => %{
                "name" => (tc[:name] || tc["name"] || "") |> to_string() |> normalize_tool_name(),
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

      # Generic atom-keyed messages. `content` may be a LIST of structured
      # blocks (`MessageHandler.build_messages/3` emits `text` + `image` blocks
      # for an attachment); `to_string/1` on a list of maps raises
      # `Protocol.UndefinedError` and kills the turn. Encode it into the
      # OpenAI multimodal content-part array instead — which is also the only
      # way an image ever reaches a vision-capable OpenAI-compatible model.
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => encode_content(content)}

      %{"role" => _role} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  # ── Multimodal content encoding ───────────────────────────────────────────
  #
  # OSA's internal block shape is Anthropic's
  # (`%{type: "image", source: %{type: "base64", media_type: .., data: ..}}`).
  # The OpenAI chat-completions equivalent is a content ARRAY of parts, where an
  # image is `%{"type" => "image_url", "image_url" => %{"url" => <data URL>}}`.
  # Without this translation the only thing that ever reached an OpenAI-shaped
  # provider was a crash (`to_string/1` on a list) or, upstream of it,
  # `Registry.normalize_message_content/2`'s "provider does not accept inline
  # image content" placeholder — which is simply false for gpt-4o and friends.
  @doc false
  @spec encode_content(term()) :: String.t() | list(map())
  def encode_content(content) when is_binary(content), do: content

  def encode_content(content) when is_list(content) do
    parts =
      content
      |> Enum.map(&content_part/1)
      |> Enum.reject(&is_nil/1)

    case parts do
      [] ->
        ""

      # A single text part is emitted as a plain string: byte-identical to what
      # every provider received before, so nothing about a text-only turn moves.
      # A part carrying `cache_control` is the exception — collapsing it to a
      # string is exactly the deletion this fix exists to stop (map patterns in
      # Elixir are partial, so the clause below would otherwise match and drop
      # the marker), so it stays an array of one.
      [%{"type" => "text", "text" => text} = part]
      when not is_map_key(part, "cache_control") ->
        text

      parts ->
        parts
    end
  end

  def encode_content(nil), do: ""

  def encode_content(other) do
    if String.Chars.impl_for(other), do: to_string(other), else: inspect(other)
  end

  defp content_part(text) when is_binary(text), do: %{"type" => "text", "text" => text}

  defp content_part(%{type: "image", source: source}), do: image_part(source)
  defp content_part(%{"type" => "image", "source" => source}), do: image_part(source)

  # Already in OpenAI shape (a re-entrant retry/fallback hop) — pass through.
  defp content_part(%{"type" => "image_url"} = part), do: part

  defp content_part(%{type: "image_url", image_url: url}),
    do: %{"type" => "image_url", "image_url" => url}

  defp content_part(%{type: "text", text: t} = b) when is_binary(t),
    do: carry_cache_control(%{"type" => "text", "text" => t}, b)

  defp content_part(%{"type" => "text", "text" => t} = b) when is_binary(t),
    do: carry_cache_control(%{"type" => "text", "text" => t}, b)

  defp content_part(%{text: t} = b) when is_binary(t),
    do: carry_cache_control(%{"type" => "text", "text" => t}, b)

  defp content_part(%{"text" => t} = b) when is_binary(t),
    do: carry_cache_control(%{"type" => "text", "text" => t}, b)

  # `cache_control` is an Anthropic field, but OpenRouter forwards it verbatim
  # on an OpenAI-shaped content part when the upstream model is Anthropic —
  # which is the only case `Registry.anthropic_prompt_cache?/2` lets reach here.
  # Keys are normalized to strings so the serialized body is byte-stable
  # regardless of how the caller built the block; a prefix that is not
  # byte-stable is not a cacheable prefix.
  defp carry_cache_control(target, source) when is_map(source) do
    case Map.get(source, :cache_control) || Map.get(source, "cache_control") do
      nil ->
        target

      cc when is_map(cc) ->
        normalized =
          Map.new(cc, fn {k, v} -> {to_string(k), if(is_atom(v), do: to_string(v), else: v)} end)

        Map.put(target, "cache_control", normalized)

      cc ->
        Map.put(target, "cache_control", cc)
    end
  end

  defp carry_cache_control(target, _source), do: target

  # Anything else structured (a stray tool_use block) carries nothing this API
  # can render.
  defp content_part(_), do: nil

  defp image_part(source) do
    media_type = get_in_either(source, :media_type, "media_type") || "image/png"
    data = get_in_either(source, :data, "data")
    url = get_in_either(source, :url, "url")

    cond do
      is_binary(url) and url != "" ->
        %{"type" => "image_url", "image_url" => %{"url" => url}}

      is_binary(data) and data != "" ->
        %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}

      true ->
        nil
    end
  end

  defp get_in_either(map, atom_key, string_key) when is_map(map),
    do: Map.get(map, atom_key, Map.get(map, string_key))

  defp get_in_either(_, _, _), do: nil

  @image_unrenderable "[An image was attached here but this message role cannot carry image content, so the image was not sent. Do not describe or reason about it; ask the user to re-share it as a new message if it matters.]"

  # Text-only flattening, for the two roles the OpenAI API restricts to a plain
  # string (`tool`, and `assistant` alongside tool_calls). An image block there
  # cannot be carried, so it becomes an explicit note rather than "" — a
  # silently dropped image is what makes a model answer confidently about
  # something it never received.
  @doc false
  @spec encode_text(term()) :: String.t()
  def encode_text(content) when is_binary(content), do: content
  def encode_text(nil), do: ""

  def encode_text(content) when is_list(content) do
    content
    |> Enum.map(fn block ->
      case content_part(block) do
        %{"type" => "text", "text" => t} -> t
        %{"type" => "image_url"} -> @image_unrenderable
        _ -> nil
      end
    end)
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.join("\n\n")
  end

  def encode_text(other) do
    if String.Chars.impl_for(other), do: to_string(other), else: inspect(other)
  end

  # `encode_text/1`, except a block list carrying a `cache_control` marker is
  # kept as an ARRAY so the marker survives.
  #
  # `tool` and `assistant` turns are normally flattened to a string, because
  # that is what the OpenAI schema asks for. But `PromptCache` puts the rolling
  # conversation breakpoint on the LAST history message, and in an agent loop
  # that message is usually a tool result — so flattening it deleted the one
  # breakpoint that lets the transcript itself be cached.
  #
  # Verified on the wire against OpenRouter → Anthropic (2026-08-14): a
  # `tool`-role message with array content and a `cache_control` part is
  # accepted, and it is what makes the cached prefix GROW with the conversation
  # (26,213 → 28,297 tokens over six turns) instead of staying pinned to the
  # static prefix.
  @doc false
  @spec encode_text_preserving_cache(term()) :: String.t() | list(map())
  def encode_text_preserving_cache(content) when is_list(content) do
    parts = content |> Enum.map(&content_part/1) |> Enum.reject(&is_nil/1)

    if Enum.any?(parts, &Map.has_key?(&1, "cache_control")) do
      parts
    else
      encode_text(content)
    end
  end

  def encode_text_preserving_cache(content), do: encode_text(content)

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
        name: call["function"]["name"] |> to_string() |> normalize_tool_name(),
        arguments: args
      }
    end)
  end

  # Fallback: detect tool calls embedded as XML/JSON in the content field
  def parse_tool_calls(%{"content" => content}) when is_binary(content) do
    parse_tool_calls_from_content(content)
  end

  def parse_tool_calls(_), do: []

  @doc """
  Model-aware variant — tries model-specific parsers before the generic fallback.
  """
  def parse_tool_calls(%{"tool_calls" => calls}, _model) when is_list(calls) do
    parse_tool_calls(%{"tool_calls" => calls})
  end

  def parse_tool_calls(%{"content" => content} = _msg, model) when is_binary(content) do
    case ToolCallParsers.parse(content, model) do
      [] -> parse_tool_calls_from_content(content)
      calls -> calls
    end
  end

  def parse_tool_calls(msg, _model), do: parse_tool_calls(msg)

  @doc false
  def parse_tool_calls_from_content(content) when is_binary(content) do
    cond do
      # Format 2: <function_call>{"name": "...", "arguments": {...}}</function_call>
      # Must be checked BEFORE Format 1 — "<function_call>" contains "<function"
      String.contains?(content, "<function_call>") ->
        ~r/<function_call>\s*/s
        |> Regex.split(content, include_captures: false)
        |> Enum.drop(1)
        |> Enum.flat_map(fn chunk ->
          case extract_balanced_json(chunk) do
            {:ok, json_str} ->
              case Jason.decode(json_str) do
                {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
                  [%{id: generate_id(), name: normalize_tool_name(name), arguments: args}]

                {:ok, %{"name" => name, "arguments" => args}} when is_binary(args) ->
                  parsed =
                    case Jason.decode(args) do
                      {:ok, a} -> a
                      _ -> %{}
                    end

                  [%{id: generate_id(), name: normalize_tool_name(name), arguments: parsed}]

                _ ->
                  []
              end

            _ ->
              []
          end
        end)

      # Format 1: <function name="tool_name" parameters={...}></function>
      String.contains?(content, "<function") ->
        extract_xml_function_calls(content)

      # Format 3: raw JSON tool call object {"name": "...", "arguments": {...}}
      String.contains?(content, "\"name\"") and String.contains?(content, "\"arguments\"") ->
        extract_json_tool_calls(content)

      true ->
        []
    end
  end

  def parse_tool_calls_from_content(_), do: []

  # Extract <function name="..." parameters={...}></function> tags with proper
  # balanced-brace JSON parsing (fixes non-greedy regex failure on nested JSON).
  @xml_fn_pattern ~r/<function\s+name="([^"\s{(]*).*?parameters=/s

  defp extract_xml_function_calls(content) do
    @xml_fn_pattern
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{match_start, match_len}, {name_start, name_len}] ->
      name = binary_part(content, name_start, name_len)
      json_offset = match_start + match_len
      rest = binary_part(content, json_offset, byte_size(content) - json_offset)

      case extract_balanced_json(rest) do
        {:ok, args_str} ->
          args =
            case Jason.decode(args_str) do
              {:ok, parsed} -> parsed
              _ -> %{}
            end

          [%{id: generate_id(), name: normalize_tool_name(name), arguments: args}]

        _ ->
          []
      end
    end)
  end

  # Extract all JSON tool call objects from free-form text (Format 3).
  defp extract_json_tool_calls(content) do
    content
    |> scan_json_objects()
    |> Enum.flat_map(fn json_str ->
      case Jason.decode(json_str) do
        {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
          [%{id: generate_id(), name: normalize_tool_name(name), arguments: args}]

        _ ->
          []
      end
    end)
  end

  # Scan a string for all top-level JSON objects, returning them as strings.
  defp scan_json_objects(str), do: scan_json_objects(str, [])

  defp scan_json_objects("", acc), do: Enum.reverse(acc)

  defp scan_json_objects(str, acc) do
    case :binary.match(str, "{") do
      :nomatch ->
        Enum.reverse(acc)

      {pos, 1} ->
        substr = binary_part(str, pos, byte_size(str) - pos)

        case extract_balanced_json(substr) do
          {:ok, json_str} ->
            rest_pos = pos + byte_size(json_str)
            rest = binary_part(str, rest_pos, byte_size(str) - rest_pos)
            scan_json_objects(rest, [json_str | acc])

          _ ->
            rest = binary_part(str, pos + 1, byte_size(str) - pos - 1)
            scan_json_objects(rest, acc)
        end
    end
  end

  # Extract a balanced JSON object starting at the first `{` in the string.
  # Handles nested objects and quoted strings (including escaped quotes).
  # Returns {:ok, json_string} or :error.
  defp extract_balanced_json(str) do
    case :binary.match(str, "{") do
      :nomatch ->
        :error

      {start, 1} ->
        substr = binary_part(str, start, byte_size(str) - start)

        case scan_balanced(substr, 0, 0) do
          {:ok, len} -> {:ok, binary_part(substr, 0, len)}
          :error -> :error
        end
    end
  end

  defp scan_balanced(str, depth, pos)

  defp scan_balanced("", depth, _pos) when depth > 0, do: :error
  defp scan_balanced("", 0, pos), do: {:ok, pos}

  # Enter a quoted string — skip until closing unescaped quote
  defp scan_balanced(<<"\"", rest::binary>>, depth, pos) do
    case skip_json_string(rest, pos + 1) do
      {:ok, new_pos} ->
        scan_balanced(
          binary_part(rest, new_pos - pos - 1, byte_size(rest) - (new_pos - pos - 1)),
          depth,
          new_pos
        )

      :error ->
        :error
    end
  end

  defp scan_balanced(<<"{", rest::binary>>, depth, pos) do
    scan_balanced(rest, depth + 1, pos + 1)
  end

  defp scan_balanced(<<"}", _rest::binary>>, 1, pos) do
    {:ok, pos + 1}
  end

  defp scan_balanced(<<"}", rest::binary>>, depth, pos) when depth > 1 do
    scan_balanced(rest, depth - 1, pos + 1)
  end

  defp scan_balanced(<<_byte, rest::binary>>, depth, pos) do
    scan_balanced(rest, depth, pos + 1)
  end

  # Skip over a JSON string (already consumed the opening `"`).
  # Returns {:ok, position_after_closing_quote} or :error.
  defp skip_json_string(str, pos)

  defp skip_json_string("", _pos), do: :error

  defp skip_json_string(<<"\\", _escaped, rest::binary>>, pos) do
    skip_json_string(rest, pos + 2)
  end

  defp skip_json_string(<<"\"", _rest::binary>>, pos) do
    {:ok, pos + 1}
  end

  defp skip_json_string(<<_byte, rest::binary>>, pos) do
    skip_json_string(rest, pos + 1)
  end

  defp normalize_tool_name(name) when is_binary(name) do
    name |> String.split(~r/[\s({]/) |> List.first() |> String.trim()
  end

  defp strip_tool_call_markup(content) when is_binary(content) do
    content
    |> String.replace(~r/<function\s+name="[^"]+"\s+parameters=\{.*?\}\s*>\s*<\/function>/s, "")
    |> String.replace(~r/<function_call>.*?<\/function_call>/s, "")
    |> String.trim()
  end

  defp strip_tool_call_markup(content), do: content

  defp xml_tool_call_content?(content) when is_binary(content) do
    String.contains?(content, "<function") or String.contains?(content, "<function_call>")
  end

  defp xml_tool_call_content?(_), do: false

  # --- Private helpers ---

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        body
        |> Map.put(:tools, format_tools(tools))
        |> Map.put(:tool_choice, "auto")
    end
  end

  # OpenAI o-series reasoning models (o1/o3/o4) reject the classic `max_tokens`
  # field and require `max_completion_tokens`. Every other OpenAI-compatible
  # provider uses `max_tokens`. Route the value to the right key so o-series
  # calls don't 400 ("max_tokens is not supported with this model").
  defp maybe_add_max_tokens(body, model, opts) do
    case Keyword.get(opts, :max_tokens) do
      nil ->
        body

      n when is_integer(n) and n > 0 ->
        capped = cap_max_output(model, n)

        if openai_reasoning_model?(model),
          do: Map.put(body, :max_completion_tokens, capped),
          else: Map.put(body, :max_tokens, capped)

      _ ->
        body
    end
  end

  # Clamp the requested output cap to the model's real output ceiling (Catalog /
  # static table) so num-output never exceeds a model's limit and 400s or
  # truncates. No-op when the ceiling is unknown.
  defp cap_max_output(model, n) do
    case OptimalSystemAgent.Providers.ModelLimits.max_output(model) do
      cap when is_integer(cap) and cap > 0 -> min(n, cap)
      _ -> n
    end
  end

  # OpenAI o-series reasoning models only support the default temperature (1) and
  # 400 on any explicit `temperature`. Omit the field for them; every other model
  # gets the requested temperature (default 0.7). Mirrors CC's rule of dropping
  # temperature when a reasoning/thinking mode is active.
  defp maybe_add_temperature(body, model, opts) do
    if openai_reasoning_model?(model) do
      body
    else
      Map.put(body, :temperature, Keyword.get(opts, :temperature, 0.7))
    end
  end

  # Narrow: ONLY OpenAI o-series (o1/o3/o4). deepseek-reasoner and kimi are
  # reasoning models too (reasoning_model?/1) but DO accept temperature/max_tokens,
  # so they must NOT be swept in here.
  # Single source of truth: Providers.OpenAIModels. The old `starts_with?` scan
  # over "o1"/"o3"/"o4" silently missed the GPT-5.x reasoning models — whose
  # names begin with "gpt" — so OSA kept sending them `temperature` (which they
  # reject) and never sent `reasoning_effort` (so effort was a no-op on them).
  # OpenAIModels.reasoning?/1 falls back to the same o-series prefix scan for
  # ids it doesn't yet know, so a brand-new o5-* still behaves correctly.
  defp openai_reasoning_model?(model) do
    OptimalSystemAgent.Providers.OpenAIModels.reasoning?(String.downcase(to_string(model)))
  end

  # Add reasoning_effort for OpenAI o-series models.
  # OpenAI's API only accepts "low" | "medium" | "high" (default: medium), so the
  # OSA effort ladder (:fast/:medium/:high/:xhigh/:ultra, plus legacy low/max and
  # "off") is mapped down via openai_reasoning_effort/1 — never passed raw.
  # For non-reasoning models this is a no-op.
  defp maybe_add_reasoning(body, model, opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        if reasoning_model?(model) do
          Map.put(body, :reasoning_effort, "medium")
        else
          body
        end

      effort ->
        case openai_reasoning_effort(effort) do
          nil -> body
          value -> Map.put(body, :reasoning_effort, value)
        end
    end
  end

  # Map an OSA effort level (atom or string) to the OpenAI reasoning_effort value.
  # OpenAI only understands "low"/"medium"/"high"; anything above "high" clamps to
  # "high", and "off"/"none" omit the field entirely (nil). Legacy low/max are
  # handled. An unknown / corrupt persisted value falls back to "medium" (the
  # model's own default) rather than nil — a garbage effort must not silently
  # DISABLE reasoning on an o-series model (W4 invalid-effort hardening); only an
  # explicit off/none turns it off.
  defp openai_reasoning_effort(effort) do
    case effort |> to_string() |> String.trim() |> String.downcase() do
      "off" -> nil
      "none" -> nil
      "fast" -> "low"
      "low" -> "low"
      "medium" -> "medium"
      "high" -> "high"
      "xhigh" -> "high"
      "max" -> "high"
      "ultra" -> "high"
      _ -> "medium"
    end
  end

  @doc """
  Returns true for models that use chain-of-thought reasoning.

  Used to widen the HTTP timeout to 600s and to default `reasoning_effort`.

  The DeepSeek arm is no longer an id comparison. Under the old API reasoning
  WAS a different model (`deepseek-reasoner`), so `name == "deepseek-reasoner"`
  was a correct test. DeepSeek V4 retired that id and moved thinking onto a
  request parameter, which means every V4 model reasons — so the question
  "is this a reasoning model?" is now answered by the catalog, not by the name.
  Left as a literal comparison, this returned false for `deepseek-v4-pro` and
  silently dropped the long reasoning timeout.
  """
  def reasoning_model?(model) do
    name = String.downcase(to_string(model))

    OptimalSystemAgent.Providers.OpenAIModels.reasoning?(name) or
      OptimalSystemAgent.Providers.DeepSeekModels.thinking_model?(name) or
      OptimalSystemAgent.Providers.XAIModels.reasoning?(name) or
      name == "deepseek-reasoner" or
      String.contains?(name, "kimi")
  end

  # DeepSeek V4 takes a `thinking` object in the request body (what the OpenAI
  # SDK calls `extra_body`); OSA builds raw JSON, so it is simply merged in at
  # top level.
  #
  # This must run even when the caller passes no effort: DeepSeek defaults
  # `thinking.type` to "enabled", so an OSA "off" effort has to send
  # `{"type": "disabled"}` explicitly — omitting the object leaves thinking ON.
  #
  # The gate is `thinking_params/2`, a pure MODEL-NAME test. This module is the
  # shared transport for OpenRouter, Groq, LM Studio and every user-defined
  # base_url, and those gateways host DeepSeek weights under DeepSeek's own
  # names — `deepseek/deepseek-v3.2` on OpenRouter, `deepseek-r1:70b` locally.
  # Keyed on the name alone, DeepSeek's proprietary top-level `thinking` object
  # was merged into requests bound for servers that reject an unknown top-level
  # field with a 400. The transport is what decides whether a
  # provider-proprietary body decoration is legal, so the endpoint gets a vote.
  defp maybe_add_provider_thinking(body, model, opts, base_url) do
    if deepseek_endpoint?(base_url) do
      effort =
        Keyword.get(opts, :reasoning_effort) ||
          Keyword.get(opts, :effort) ||
          current_effort()

      case OptimalSystemAgent.Providers.DeepSeekModels.thinking_params(model, effort) do
        params when map_size(params) == 0 -> body
        params -> Map.merge(body, params)
      end
    else
      body
    end
  end

  # `nil` = the caller did not say (the 3-arity `build_stream_body/3` contract
  # tests use). Unknown transport keeps the pre-existing behaviour rather than
  # silently disabling thinking for a caller that never had a URL to give.
  defp deepseek_endpoint?(nil), do: true

  defp deepseek_endpoint?(url) when is_binary(url) do
    host = URI.parse(url).host || ""

    # A user proxying DeepSeek through their own host is still DeepSeek: the
    # :deepseek provider's configured URL counts however it is spelled.
    String.ends_with?(host, "deepseek.com") or
      url ==
        Application.get_env(
          :optimal_system_agent,
          :deepseek_url,
          "https://api.deepseek.com/v1"
        )
  end

  defp deepseek_endpoint?(_), do: false

  defp current_effort do
    OptimalSystemAgent.Agent.Effort.current()
  rescue
    _ -> "medium"
  catch
    _, _ -> "medium"
  end

  # Cached input is reported by every OpenAI-compatible provider that supports
  # it (OpenAI, DeepSeek, Groq, OpenRouter, xAI) under
  # `prompt_tokens_details.cached_tokens` — and this dropped it on the floor,
  # so those providers reported cache_read = 0 even when they HAD cached. The
  # key name matters as much as the value: `CacheAttribution` and
  # `Loop.Accounting` both read `:cache_read_input_tokens` and nothing else, so
  # a provider parser that files the same number under any other key is
  # invisible to pricing. `openai_responses.ex` used to store it as
  # `:cached_tokens` for exactly that reason; it does not any more
  # (`openai_responses.ex:462` emits `:cache_read_input_tokens`), so this is a
  # convention to keep, not a live divergence.
  defp parse_usage(%{"usage" => %{"prompt_tokens" => inp, "completion_tokens" => out} = u}) do
    %{
      input_tokens: inp,
      output_tokens: out,
      cache_read_input_tokens: cached_input(u),
      cache_creation_input_tokens: cache_written(u)
    }
  end

  # The SSE path's equivalent of `parse_usage/1`.
  #
  # Both streaming branches used to build `%{input_tokens: .., output_tokens: ..}`
  # and nothing else, so `cache_read_input_tokens` was ALWAYS absent on the
  # streamed path — and the agent loop streams. The effect was not just a blind
  # dashboard: `Accounting` reconciles OpenAI-shaped `prompt_tokens` (which is
  # INCLUSIVE of cached tokens) against the cache slices, so a missing
  # cache_read meant the whole cached prefix was billed at full input rate
  # instead of 0.1x — a ~10x overcharge on exactly the requests the prompt-cache
  # fix had just made cheap.
  #
  # Same shape of bug as the caching one itself: the compat path silently
  # diverging from the native Anthropic path, with a plausible-looking number
  # hiding it.
  defp stream_usage(%{"prompt_tokens" => inp, "completion_tokens" => out} = u) do
    %{
      input_tokens: inp,
      output_tokens: out,
      cache_read_input_tokens: cached_input(u),
      cache_creation_input_tokens: cache_written(u)
    }
  end

  defp cached_input(%{"prompt_tokens_details" => %{"cached_tokens" => n}}) when is_integer(n),
    do: n

  defp cached_input(%{"cached_tokens" => n}) when is_integer(n), do: n
  defp cached_input(_), do: 0

  # Cache WRITES bill at ~1.25x input, and nothing on this path captured them
  # at all — so a cache miss looked free and the cost of a cold prefix was
  # under-reported on every first turn. OpenRouter reports it as
  # `prompt_tokens_details.cache_write_tokens`; Anthropic-shaped gateways use
  # `cache_creation_input_tokens`. Accept both.
  defp cache_written(%{"prompt_tokens_details" => %{"cache_write_tokens" => n}})
       when is_integer(n),
       do: n

  defp cache_written(%{"cache_creation_input_tokens" => n}) when is_integer(n), do: n
  defp cache_written(%{"cache_write_tokens" => n}) when is_integer(n), do: n
  defp cache_written(_), do: 0

  defp parse_usage(_), do: %{}

  # `message` is only usable as a message when it IS one. Some gateways answer
  # with `{"error": {"message": {"detail": ...}}}` or a list of validation
  # objects; without the guard that map reached a `"#{}"` interpolation at the
  # call sites below and raised Protocol.UndefinedError, turning a classifiable
  # provider error into an unclassifiable crash that ErrorCatalog and the
  # fallback chain never got to see. Fall through to `inspect/1` instead.
  defp extract_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp extract_error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(body), do: inspect(body)

  # On a non-200 streamed response the error JSON body accumulates in the SSE
  # buffer (no `data:` prefix). Best-effort decode for a human-readable message.
  defp extract_stream_error(%{buffer: buf}) when is_binary(buf) and buf != "" do
    case Jason.decode(buf) do
      {:ok, decoded} -> extract_error_message(decoded)
      _ -> String.slice(buf, 0, 500)
    end
  end

  defp extract_stream_error(_), do: "streaming request failed"

  # Parse the Retry-After header from HTTP 429 responses.
  # Handles both integer seconds and RFC 7231 HTTP-date strings.
  # Returns the number of seconds to wait, or nil if the header is absent/unparseable.
  defp parse_retry_after(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"retry-after", v} -> v
      {"Retry-After", v} -> v
      _ -> nil
    end)
    |> parse_retry_after_value()
  end

  # Req 0.5.x delivers response headers as a MAP with list values
  # (%{"retry-after" => ["30"]}). Without this clause every 429 gets nil and
  # the provider's Retry-After (incl. HTTP-date form) is ignored.
  defp parse_retry_after(headers) when is_map(headers) do
    (headers["retry-after"] || headers["Retry-After"])
    |> case do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> nil
    end
    |> parse_retry_after_value()
  end

  defp parse_retry_after(_), do: nil

  # Integer seconds: "30"
  defp parse_retry_after_value(nil), do: nil

  defp parse_retry_after_value(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {seconds, ""} when seconds > 0 ->
        seconds

      _ ->
        # RFC 7231 HTTP-date: "Thu, 01 Jan 2026 00:00:30 GMT"
        case parse_http_date(v) do
          {:ok, future_dt} ->
            diff = DateTime.diff(future_dt, DateTime.utc_now(), :second)
            if diff > 0, do: diff, else: nil

          :error ->
            nil
        end
    end
  end

  @http_date_months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  # Parse RFC 7231 date format: "Thu, 01 Jan 2026 00:00:30 GMT"
  defp parse_http_date(v) when is_binary(v) do
    pattern = ~r/\w{3},\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT/

    case Regex.run(pattern, v) do
      [_, day_s, month_s, year_s, hour_s, min_s, sec_s] ->
        with {day, ""} <- Integer.parse(day_s),
             {month, _} <-
               Map.fetch(@http_date_months, month_s)
               |> then(fn
                 {:ok, m} -> {m, ""}
                 :error -> :error
               end),
             {year, ""} <- Integer.parse(year_s),
             {hour, ""} <- Integer.parse(hour_s),
             {minute, ""} <- Integer.parse(min_s),
             {second, ""} <- Integer.parse(sec_s),
             {:ok, dt} <-
               DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second)) do
          {:ok, dt}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
