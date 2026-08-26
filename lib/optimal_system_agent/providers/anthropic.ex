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

  # Tool schemas ride in a dedicated field of the request body, not in the
  # system-prompt text. See Providers.Behaviour.native_tool_schemas?/0.
  def native_tool_schemas?, do: true

  alias OptimalSystemAgent.Providers.ConfiguredModel
  alias OptimalSystemAgent.Providers.AnthropicModels
  alias OptimalSystemAgent.Providers.CacheAttribution
  alias OptimalSystemAgent.Providers.PromptCache

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
          ConfiguredModel.resolve(opts, :anthropic, &default_model/0)

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
          ConfiguredModel.resolve(opts, :anthropic, &default_model/0)

        base_url = Application.get_env(:optimal_system_agent, :anthropic_url, @default_url)
        do_chat_stream(base_url, auth, model, messages, callback, Keyword.delete(opts, :model))
    end
  end

  defp do_chat(base_url, auth, model, messages, opts) do
    formatted = format_messages(messages)
    {system_text, chat_msgs} = split_system(formatted, model)
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
      |> maybe_add_output_config(model, opts)
      # Keep the serialized body under Anthropic's request-size cap by evicting
      # the oldest inline images to an honest placeholder (see ImageBudget).
      # Strict no-op — body byte-for-byte unchanged — when already under budget.
      |> apply_image_budget(opts)

    # Fingerprint AFTER every body transform, so what is hashed is what goes on
    # the wire. Hashes only — no payload retained.
    cache_fp = CacheAttribution.fingerprint(body)

    headers = build_headers(auth, thinking, model)
    # Extended thinking can take 300+ s before producing output
    timeout = if thinking, do: 600_000, else: 120_000

    try do
      case Req.post("#{base_url}/messages", req_opts(body, headers, timeout, opts)) do
        # A 200 whose body is a BINARY rather than the decoded JSON object.
        #
        # The cause in practice is a gateway that only speaks SSE and answers a
        # NON-streaming request with an event stream anyway.
        #
        # The 200 arm below carries NO guard, so before this clause the SSE
        # binary matched it and was treated as a successful decode:
        # `extract_content/1` and `extract_tool_calls/1` both fall through to
        # their catch-all clauses on a binary, so the caller received
        # `{:ok, %{content: "", tool_calls: []}}` — a silent, empty, SUCCESSFUL
        # answer for a request whose real reply was sitting unparsed in `body`.
        # Ordering matters here: this clause must stay ABOVE the general 200.
        #
        # `Providers.OpenAICompat` gained this recovery first; this is the same
        # idea with a different collector, because Anthropic's stream path has
        # its own result shape (thinking_blocks) and its own sync FALLBACK,
        # which has to be disarmed here — see `collect_via_stream/6`.
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          if sse_body?(body) do
            Logger.info(
              "Anthropic endpoint answered a non-streaming request with SSE — " <>
                "re-issuing as a stream and collecting the result"
            )

            collect_via_stream(base_url, auth, model, messages, opts, body)
          else
            {:error,
             "Anthropic returned 200 with an unrecognized body: #{String.slice(body, 0, 500)}"}
          end

        {:ok, %{status: 200, body: resp}} ->
          content = extract_content(resp)
          tool_calls = extract_tool_calls(resp)
          usage = extract_usage(resp)
          thinking_blocks = extract_thinking(resp)

          # Name the culprit when the provider's reported cache read drops.
          # Diagnostics only — cannot fail the request (see CacheAttribution).
          CacheAttribution.observe(CacheAttribution.scope(opts), cache_fp, usage)

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
          rate_limited_error(retry_after)

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

  # An SSE payload rather than JSON. Anthropic streams are `event: <name>` /
  # `data: {...}` line pairs, so either prefix identifies one.
  @doc false
  @spec sse_body?(term()) :: boolean()
  def sse_body?(body) when is_binary(body) do
    trimmed = String.trim_leading(body)
    String.starts_with?(trimmed, "data:") or String.starts_with?(trimmed, "event:")
  end

  def sse_body?(_), do: false

  # Re-issue the request as a real stream and fold the events back into the one
  # `{:ok, result}` the synchronous caller is waiting for. Nothing is emitted
  # anywhere: the caller asked for a whole answer, so this is a transport
  # workaround, not a delivery change.
  #
  # Two things make this different from the OpenAI-compat collector:
  #
  #   1. `do_chat_stream/6` here falls back to `do_chat/5` on a connection error
  #      or an unexpected raise. Called from inside `do_chat/5` that is a
  #      MUTUAL RECURSION — sync sees SSE, re-issues as a stream, the stream
  #      fails, and the fallback re-enters sync, which sees SSE again. The
  #      `:__sse_recovery__` flag disarms that fallback for the duration of the
  #      recovery, so a failure surfaces as an error instead of looping.
  #   2. The done-result carries `thinking_blocks` when extended thinking is on,
  #      so the collector takes the result map WHOLE rather than rebuilding it.
  defp collect_via_stream(base_url, auth, model, messages, opts, original_body) do
    parent = self()
    ref = make_ref()

    callback = fn
      {:done, result} -> send(parent, {ref, :done, result})
      _ -> :ok
    end

    opts = Keyword.put(opts, :__sse_recovery__, true)

    case do_chat_stream(base_url, auth, model, messages, callback, opts) do
      :ok ->
        receive do
          {^ref, :done, result} -> {:ok, result}
        after
          0 ->
            {:error,
             "Anthropic SSE recovery: stream completed without a result. " <>
               "Original body: #{String.slice(original_body, 0, 300)}"}
        end

      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} ->
        {:error, "Anthropic SSE recovery failed: #{inspect(reason)}"}

      other ->
        {:error, "Anthropic SSE recovery failed: #{inspect(other)}"}
    end
  end

  # --- Streaming ---

  defp do_chat_stream(base_url, auth, model, messages, callback, opts) do
    formatted = format_messages(messages)
    {system_text, chat_msgs} = split_system(formatted, model)
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
      |> maybe_add_output_config(model, opts)
      # Keep the serialized body under Anthropic's request-size cap by evicting
      # the oldest inline images to an honest placeholder (see ImageBudget).
      # Strict no-op — body byte-for-byte unchanged — when already under budget.
      |> apply_image_budget(opts)

    # Fingerprint AFTER every body transform, so what is hashed is what goes on
    # the wire. Carried on the stream accumulator because `collect_stream/3` is
    # the only place the final usage exists.
    cache_fp = CacheAttribution.fingerprint(body)
    cache_scope = CacheAttribution.scope(opts)

    headers = build_headers(auth, thinking, model)
    # Extended thinking can take 300+ s before producing the first token
    timeout = if thinking, do: 600_000, else: 120_000

    try do
      case Req.post(
             "#{base_url}/messages",
             req_opts(body, headers, timeout, opts) ++ [into: :self]
           ) do
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
            cache_scope: cache_scope,
            cache_fp: cache_fp,
            # Carried purely so the MID-STREAM ERROR path can bill what this
            # request already cost. `message_start` delivers the whole prompt
            # cost up front; without an identity to bill it against, a stream
            # that dies afterwards took the money and left no record.
            session_id: Keyword.get(opts, :session_id),
            model: model,
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
          rate_limited_error(parse_retry_after(resp.headers))

        {:ok, %{status: status} = resp} ->
          Logger.warning("Anthropic stream HTTP #{status}")
          drain_self_stream(resp)
          {:error, "Anthropic stream HTTP #{status}"}

        {:error, reason} ->
          Logger.error("Anthropic stream connection failed: #{inspect(reason)}")
          sync_fallback(base_url, auth, model, messages, callback, opts, reason)
      end
    rescue
      e ->
        Logger.error("Anthropic stream unexpected error: #{Exception.message(e)}")
        sync_fallback(base_url, auth, model, messages, callback, opts, Exception.message(e))
    end
  end

  # `fallback_to_sync/6`, except it REFUSES when we are already inside the
  # sync→stream SSE recovery. Falling back there would re-enter `do_chat/5`,
  # which would see the same SSE body and re-issue the same stream, forever.
  defp sync_fallback(base_url, auth, model, messages, callback, opts, reason) do
    if Keyword.get(opts, :__sse_recovery__, false) do
      {:error, "Anthropic stream failed during SSE recovery: #{inspect(reason)}"}
    else
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
                stage_failed_request_spend(acc)
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

                observe_stream_cache(acc)

                callback.({:done, result})
                :ok

              true ->
                collect_stream(resp, callback, acc)
            end

          {:error, reason} ->
            Logger.error("Anthropic stream error: #{inspect(reason)}")
            stage_failed_request_spend(acc)
            {:error, "Stream error: #{inspect(reason)}"}

          :unknown ->
            # Not a message for this response (e.g. Finch pool internals) — skip.
            collect_stream(resp, callback, acc)
        end
    after
      620_000 ->
        Logger.error("Anthropic stream timeout after 620s")
        stage_failed_request_spend(acc)
        {:error, "Stream timeout"}
    end
  end

  # ── Billing a request that failed after the meter started ──────────────
  #
  # Anthropic sends `message_start` with the FULL prompt cost (`input_tokens`
  # plus the cache slices) before a single output token exists. Every failure
  # exit below it returns an error tuple that carries partial CONTENT but no
  # usage, and the loop's `usage = %{}` on the error branch is correct given
  # what it is handed — the loss is here. On a long-prompt turn the prompt IS
  # the bill, so this was silently the majority of the money on every failed
  # stream.
  #
  # Staged rather than returned, because the error tuple's shape is
  # pattern-matched at six-plus sites across the loop and the retry classifier;
  # widening it to carry usage would put a billing change on the
  # retry-classification path. `Accounting.stage_side_spend/3` already exists
  # for exactly this — an out-of-loop round-trip billed against a session id —
  # and the loop absorbs it at the point it holds both state and session id.
  #
  # Notes:
  #   * Reconciliation happens ONCE, inside `stage_side_spend/3`, against
  #     `:anthropic` (a disjoint-slice provider, so it is a no-op) — the
  #     one-reconcile-per-usage-map invariant of `reconcile_prompt_slices/2`
  #     is preserved.
  #   * A failure BEFORE `message_start` (auth rejection, connect error, a 4xx
  #     that never opened a stream) leaves the accumulator at all zeros, and
  #     `stage_side_spend/3` ignores an all-zero map. That case genuinely costs
  #     nothing and is closed here explicitly rather than by accident.
  #   * Each HTTP attempt is separately billed by Anthropic, so a retried
  #     stream staging once per attempt is correct, not double-counting.
  defp stage_failed_request_spend(acc) do
    OptimalSystemAgent.Agent.Loop.Accounting.stage_side_spend(
      Map.get(acc, :session_id),
      Map.get(acc, :usage, %{}),
      kind: :failed_request,
      model: Map.get(acc, :model),
      provider: :anthropic
    )
  end

  # Attribute a cache break on the streaming path. The accumulator carries the
  # scope and fingerprint because the final `usage` only exists here.
  # `collect_via_stream/6`'s recovery accumulator carries neither, so this is a
  # no-op there rather than a crash.
  defp observe_stream_cache(acc) do
    case {Map.get(acc, :cache_scope), Map.get(acc, :cache_fp)} do
      {scope, fp} when is_binary(scope) and is_map(fp) ->
        CacheAttribution.observe(scope, fp, Map.get(acc, :usage, %{}))

      _ ->
        :ok
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
    if Map.has_key?(acc, :usage),
      do: %{acc | usage: merge_stream_usage(acc.usage, usage)},
      else: acc
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
        if Map.has_key?(acc, :usage),
          do: %{acc | usage: merge_stream_usage(acc.usage, usage)},
          else: acc

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

  # ── Request-shape normalization ───────────────────────────────────────────
  #
  # Anthropic's `/v1/messages` has two shape rules OSA's history can violate:
  #
  #   1. `system` is a top-level field, not a role inside `messages`.
  #   2. On Opus/Sonnet 4.6 and everything newer (the whole Claude 5 family)
  #      the conversation MUST end with a `user` message. A trailing assistant
  #      turn is an "assistant message prefill", which those models reject:
  #
  #        400 — This model does not support assistant message prefill.
  #              The conversation must end with a user message.
  #
  # Both rules are enforced here, at the provider boundary, so no caller can
  # reintroduce a bad shape.
  #
  # The 400 seen in the wild came from rule 1 breaking rule 2. `ReactLoop`'s
  # steering paths (auto-continue, coding nudge, verification gate,
  # VerificationGate directives, reasoning-only backstop — ~7 call sites) each
  # append TWO messages: the assistant's text, then a `role: "system"` nudge
  # that is meant to be the last thing the model reads. Hoisting EVERY
  # system-role message onto the system prompt lifted that nudge out of the
  # conversation and stranded the assistant message as the final one.
  #
  # So only LEADING system messages are the system prompt. A system message
  # that appears after the conversation has started is mid-turn steering and
  # stays in the conversation as a `user` turn — which preserves its meaning
  # (the nudges are already written as bracketed `[System: …]` operator notes
  # the model reads as context) while satisfying the contract. It is NOT sent
  # as a mid-conversation `role: "system"` message: that shape is accepted only
  # on Opus 5 / Opus 4.8 / Fable 5 / Mythos 5 and 400s on Sonnet 5, Haiku 4.5
  # and the 4.6/4.7 models, so it would trade one model-specific 400 for
  # another.
  #
  # ── The system prompt keeps its BLOCK structure ───────────────────────────
  #
  # Anthropic's `system` field accepts either a string or an array of content
  # blocks, each optionally carrying its own `cache_control` breakpoint.
  # `Context.build_system_message/4` deliberately emits three blocks — static
  # base (cached), diffed world state (cached), volatile tail (uncached) — so
  # that the ~30k-token stable prefix is served from cache while the clock,
  # turn count and working-tree state stay outside every cached region.
  #
  # Flattening those three blocks into one string here destroyed that: the
  # single re-wrapped block carried `Context.runtime_block/1`'s timestamp
  # INSIDE the cached region, making every request byte-unique and the cache
  # hit rate a hard 0%. So leading system messages are returned as blocks
  # whenever any of them carries a cache breakpoint, and as a plain string
  # otherwise (the overwhelmingly common shape for non-Context callers, and
  # the cheapest thing to put on the wire).
  @doc false
  def split_system(formatted, model) do
    {leading, rest} = Enum.split_while(formatted, &(&1["role"] == "system"))
    system = system_prompt(leading)

    chat_msgs =
      rest
      |> Enum.map(fn
        %{"role" => "system"} = msg -> %{msg | "role" => "user"}
        msg -> msg
      end)
      |> ensure_trailing_user(model)

    {system, chat_msgs}
  end

  # Leading system messages -> either a plain string or an array of content
  # blocks. Blocks are returned only when at least one carries `cache_control`,
  # so every existing caller that sends a plain system string keeps the exact
  # wire shape it had before.
  defp system_prompt([]), do: ""

  defp system_prompt(leading) do
    blocks = Enum.flat_map(leading, &system_content_to_blocks(&1["content"]))

    if Enum.any?(blocks, &Map.has_key?(&1, "cache_control")) do
      blocks
    else
      Enum.map_join(leading, "\n\n", &system_content_to_string(&1["content"]))
    end
  end

  defp system_content_to_blocks(content) when is_binary(content),
    do: if(content == "", do: [], else: [%{"type" => "text", "text" => content}])

  defp system_content_to_blocks(nil), do: []

  defp system_content_to_blocks(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"text" => t} = b when is_binary(t) ->
        [put_cache_control(%{"type" => "text", "text" => t}, b)]

      %{text: t} = b when is_binary(t) ->
        [put_cache_control(%{"type" => "text", "text" => t}, b)]

      t when is_binary(t) ->
        [%{"type" => "text", "text" => t}]

      _ ->
        []
    end)
  end

  defp system_content_to_blocks(other), do: [%{"type" => "text", "text" => to_string(other)}]

  # Copy a `cache_control` marker from a source block onto a normalized one,
  # accepting either key style and normalizing the marker itself to string keys
  # so the serialized body is stable regardless of how the caller built it.
  defp put_cache_control(target, source) when is_map(source) do
    case Map.get(source, :cache_control) || Map.get(source, "cache_control") do
      nil -> target
      cc -> Map.put(target, "cache_control", normalize_cache_control(cc))
    end
  end

  defp put_cache_control(target, _source), do: target

  defp normalize_cache_control(cc) when is_map(cc) do
    Map.new(cc, fn {k, v} ->
      {to_string(k), if(is_atom(v), do: to_string(v), else: v)}
    end)
  end

  defp normalize_cache_control(cc), do: cc

  # Last line of defence for rule 2. After the demotion above a trailing
  # assistant message should be impossible from the steering paths, but it can
  # still arrive from a caller that committed a partial streamed reply on an
  # error path, from a resumed/compacted transcript, or from a future call site.
  #
  # The trailing content is meaningful — it is a real partial reply — so it is
  # NOT dropped. It stays exactly where it is and a short bracketed `user` turn
  # is appended naming what happened, so the model sees its own partial output
  # as context and knows to continue rather than restart. That keeps the
  # semantics of a prefill (the model resumes from its own words) without the
  # rejected shape.
  #
  # Gated on the model: Haiku 4.5 and older accept prefill, so their requests
  # pass through byte-for-byte unchanged.
  defp ensure_trailing_user([], _model), do: []

  defp ensure_trailing_user(msgs, model) do
    if AnthropicModels.supports_prefill?(model) do
      msgs
    else
      case List.last(msgs) do
        %{"role" => "assistant"} ->
          Logger.debug(
            "[anthropic] normalized trailing assistant message for #{model} " <>
              "(prefill unsupported on this model)"
          )

          msgs ++
            [
              %{
                "role" => "user",
                "content" => [
                  %{
                    "type" => "text",
                    "text" =>
                      "[System: your previous message above was cut off before it completed. " <>
                        "Continue from exactly where it stopped — do not repeat what you already said.]"
                  }
                ]
              }
            ]

        _ ->
          msgs
      end
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

            # `cache_control` MUST survive this hop. `Context.build_system_message/4`
            # emits the system prompt as three blocks carrying two ephemeral cache
            # breakpoints; a clause that rebuilt the block from `type`/`text` alone
            # silently dropped the marker before `split_system/2` ever saw it, so the
            # deliberate multi-block cache structure never reached the wire.
            %{type: "text", text: text} = block ->
              put_cache_control(%{"type" => "text", "text" => to_string(text)}, block)

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

  # Anthropic allows at most 4 `cache_control` breakpoints per request. The
  # system array is emitted stable-prefix-first, so when a caller somehow
  # exceeds the cap the EARLIEST markers are the ones worth keeping: each one
  # covers a longer stable prefix than the marker after it.
  @max_cache_breakpoints 4

  # Public as a test seam, exactly like `maybe_add_thinking/2` and
  # `maybe_add_output_config/3` above: the system-side cache decision had no
  # observable output at all, so there was nothing to assert on short of
  # standing up an HTTP stub.
  @doc false
  def maybe_add_system(body, ""), do: body
  def maybe_add_system(body, nil), do: body
  def maybe_add_system(body, []), do: body

  # Pre-blocked system prompt (Context's static / world-state / volatile split).
  # Passed through as an array so each block keeps its own cache breakpoint —
  # crucially leaving the volatile tail OUTSIDE every cached region.
  def maybe_add_system(body, blocks) when is_list(blocks) do
    blocks =
      if prompt_caching_enabled?() do
        cap_cache_breakpoints(blocks)
      else
        Enum.map(blocks, &Map.delete(&1, "cache_control"))
      end

    Map.put(body, :system, blocks)
  end

  def maybe_add_system(body, system_text) do
    # Anthropic caches from the end of the last `cache_control` marker, so an
    # unblocked system prompt is marked as one ephemeral block — but only once
    # it is long enough for the marker to create a cache entry at all.
    #
    # The threshold is `PromptCache.min_cacheable_bytes/0`, NOT a local 4,000.
    # There were three numbers for this one minimum: 4,000 here, 4,500 on the
    # tools-side sibling (recalibrated against a measured 4.1 bytes/token so a
    # placed marker clears the 1024-token floor), and 4,500 again in `Bedrock`
    # with a comment promising to hold it equal by hand. This one was also the
    # only one of the three that made its decision in silence.
    bytes = byte_size(system_text)
    caching? = prompt_caching_enabled?()
    place? = caching? and bytes >= PromptCache.min_cacheable_bytes()

    report_system_cache_decision(place?, caching?, bytes)

    if place? do
      Map.put(body, :system, [
        %{type: "text", text: system_text, cache_control: %{type: "ephemeral"}}
      ])
    else
      Map.put(body, :system, system_text)
    end
  end

  # Same instrument the tools side got, for the same reason: a breakpoint that
  # is not placed produces no error and no marker, just a system prefix re-billed
  # in full every turn. Deduped on the decision shape so a steady-state session
  # logs once rather than once per turn.
  defp report_system_cache_decision(placed?, caching?, bytes) do
    reason =
      cond do
        placed? -> :placed
        not caching? -> :caching_disabled
        true -> :below_min_cacheable
      end

    :telemetry.execute(
      [:osa, :anthropic, :system_cache],
      %{bytes: bytes, threshold: PromptCache.min_cacheable_bytes()},
      %{placed: placed?, reason: reason}
    )

    signature = {reason, div(bytes, 1_000)}

    if Process.get(:osa_system_cache_decision) != signature do
      Process.put(:osa_system_cache_decision, signature)
      tokens = PromptCache.approx_tokens(bytes)

      case reason do
        :placed ->
          Logger.debug("[Anthropic] system cache breakpoint placed: #{bytes} B (~#{tokens} tok)")

        :caching_disabled ->
          Logger.debug(
            "[Anthropic] system cache breakpoint skipped: prompt caching disabled (#{bytes} B)"
          )

        :below_min_cacheable ->
          Logger.info(
            "[Anthropic] system cache breakpoint NOT placed: #{bytes} B (~#{tokens} tok) is " <>
              "below the #{PromptCache.min_cacheable_bytes()} B minimum — this system prefix " <>
              "is re-billed in full every turn."
          )
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cap_cache_breakpoints(blocks), do: cap_cache_breakpoints(blocks, @max_cache_breakpoints)

  defp cap_cache_breakpoints(blocks, budget) do
    {kept, _} =
      Enum.map_reduce(blocks, 0, fn block, seen ->
        cond do
          not Map.has_key?(block, "cache_control") -> {block, seen}
          seen < budget -> {block, seen + 1}
          true -> {Map.delete(block, "cache_control"), seen}
        end
      end)

    kept
  end

  # The switch is GLOBAL policy, not this module's. It used to be read here and
  # only here (five call sites, all in this file), which meant setting it false
  # disabled caching on the native path and left it fully on for
  # OpenRouter → Anthropic. `PromptCache.enabled?/0` is now the single reader
  # and every marking route consults it.
  defp prompt_caching_enabled?, do: PromptCache.enabled?()

  @doc """
  Add extended thinking configuration to request body.
  No-ops when thinking is nil.
  """
  def maybe_add_thinking(body, nil), do: body

  def maybe_add_thinking(body, %{type: "adaptive"}) do
    # Claude 5 still reasons when `display` is omitted, but Anthropic defaults
    # current adaptive models to `omitted`: no readable `thinking_delta` events
    # are streamed, so the TUI appears to skip thinking only for Claude. Ask
    # for the provider's safe summarized view. This never exposes raw chain of
    # thought; Anthropic generates the display summary separately.
    Map.put(body, :thinking, %{type: "adaptive", display: "summarized"})
  end

  def maybe_add_thinking(body, %{type: "enabled", budget_tokens: budget}) do
    # Anthropic requires minimum 1024 budget tokens
    budget = max(budget, 1024)
    Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})
  end

  def maybe_add_thinking(body, _), do: body

  @doc """
  Add `output_config.effort` — the ONLY thing that carries reasoning depth on
  an adaptive-thinking model.

  `thinking: {type: "adaptive"}` is byte-identical at every OSA effort tier, so
  before this existed the entire `Agent.Effort` ladder was a silent no-op on
  every current Claude model: `/effort fast` and `/effort ultra` produced the
  same request. Only Haiku 4.5 (a `:budget` model) ever saw the tier at all,
  via `budget_tokens`.

  Resolution order matches the Google and Responses transports:
  `opts[:reasoning_effort]` → `opts[:effort]` → `Agent.Effort.current/0`.

  Omits the field entirely when the model has no effort parameter or the level
  is unrecognised — see `AnthropicModels.effort_value/2`.

  > #### Effective default changed {: .warning}
  >
  > Anthropic's own default is `high`. OSA's default effort is `:medium`, so a
  > user who never touched `/effort` now gets `effort: "medium"` where they
  > previously got the model's `high`. That is cheaper and slightly less
  > capable. It is also the point: an effort ladder whose middle rung does not
  > mean `medium` is a ladder that lies. Pin `/effort high` to restore the old
  > behaviour exactly.
  """
  @spec maybe_add_output_config(map(), String.t() | atom() | nil, keyword()) :: map()
  def maybe_add_output_config(body, model, opts \\ []) do
    case build_output_config(model, opts) do
      nil -> body
      cfg -> Map.put(body, :output_config, cfg)
    end
  end

  @doc """
  Test seam: build just the `output_config` map for a model + opts, with no
  live HTTP call. `nil` means "send nothing".
  """
  @spec build_output_config(String.t() | atom() | nil, keyword()) :: map() | nil
  def build_output_config(model, opts \\ []) do
    level =
      Keyword.get(opts, :reasoning_effort) ||
        Keyword.get(opts, :effort) ||
        current_effort()

    case AnthropicModels.effort_value(to_string(model || ""), level) do
      nil -> nil
      wire -> %{effort: wire}
    end
  end

  # A renderer of a request body must never be the thing that kills the turn:
  # an unavailable Settings table means "unpinned", not "crash".
  defp current_effort do
    OptimalSystemAgent.Agent.Effort.current()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

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
    # API-key auth (`x-api-key`) is the ONLY supported Anthropic auth path.
    # The former `{:oauth, token}` clause — `Authorization: Bearer …` plus the
    # subscription fingerprint `anthropic-beta: oauth-2025-04-20` — was removed;
    # see `OptimalSystemAgent.Auth.LegacyAnthropicOAuth`. Its removal also fixes
    # the duplicate-header bug it caused: that clause emitted its own
    # `anthropic-beta` entry, so whenever any other beta was active the request
    # carried TWO `anthropic-beta` headers. Betas are now collected in exactly
    # one place and emitted as a single comma-joined header, by construction.
    auth_header =
      case auth do
        {:api_key, key} when is_binary(key) ->
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

  # Single wiring point for HTTP 429 (sync + streaming both funnel here).
  #
  # `CredentialPool` advertises "automatic skip of rate-limited keys", but
  # nothing ever marked a key: `mark_rate_limited/2` had zero callers, so a
  # throttled key kept being handed straight back out of `resolve_auth/0` and
  # every same-provider retry (Resilience runs those BEFORE any fallback) hit
  # the same 429. Marking here — at the point the 429 is recognised, before the
  # error tuple propagates into the retry loop — is what makes the next attempt
  # pick a different key.
  #
  # Best-effort: the pool is a cast, and a single-key/env-fallback setup is a
  # no-op there. It must never convert a rate-limit into a crash.
  defp rate_limited_error(retry_after) do
    _ =
      try do
        OptimalSystemAgent.Providers.CredentialPool.mark_rate_limited(:anthropic)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

    {:error, {:rate_limited, retry_after}}
  end

  @doc """
  Resolve authentication.

  Anthropic is **API-key only**. Returns `{:api_key, key}` or `{:error, reason}`.
  The former subscription-OAuth fallback was removed — see
  `OptimalSystemAgent.Auth.LegacyAnthropicOAuth` for why.
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

      # A user who was signed in with the removed Anthropic subscription flow
      # would otherwise just see "no API key" with no explanation of why the
      # thing that worked yesterday stopped. Name the removal explicitly for
      # the run in which their stale credential was purged.
      OptimalSystemAgent.Auth.LegacyAnthropicOAuth.purged?() ->
        {:error,
         "ANTHROPIC_API_KEY not configured. " <>
           OptimalSystemAgent.Auth.LegacyAnthropicOAuth.notice()}

      true ->
        # Phrased so `ErrorCatalog.missing_api_key?/1` (which matches "not
        # configured") catches it — previously "No Anthropic API key or
        # OAuth token configured." fell through that matcher (the word
        # "not" never appeared) and got classified :unknown, skipping the
        # actionable `osa setup`/env-var guidance for exactly the provider
        # a Claude-first user is most likely to hit first (P4). Leads with
        # "ANTHROPIC_API_KEY" so the message-level regex
        # (`missing_api_key_message/1`) also names the right env var.
        {:error,
         "ANTHROPIC_API_KEY not configured. Run /provider to add a key, or set ANTHROPIC_API_KEY."}
    end
  end

  # Tool definitions render FIRST in an Anthropic request — ahead of `system`
  # and `messages` — and they are the single most stable thing in it. OSA sends
  # ~62 KB (~15.5k tokens) of them on every turn.
  #
  # Until now they carried no `cache_control` of their own. They were still
  # cached, because caching is a prefix match and the first `system` breakpoint
  # covers everything before it — but only as part of ONE segment welded to the
  # static base. Anthropic's invalidation hierarchy is tiered: a change to the
  # system prompt invalidates the system cache while LEAVING the tools cache
  # intact — but only if a tools breakpoint exists to define that tier. Without
  # one, editing a rules file, connecting an MCP server, or changing the user
  # profile re-wrote all ~48k tokens at the 1.25x write rate instead of
  # re-writing the ~32k that actually changed and reading the ~15.5k that did
  # not.
  #
  # Context uses 2 of the 4 available breakpoints, so this one is free. It costs
  # nothing when nothing changes (both segments are reads) and saves the tools
  # segment whenever the system prompt alone moves.
  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        body
        |> Map.put(:tools, format_tools(tools))
        |> mark_tools_cache_boundary(stable_tool_count(tools))
    end
  end

  # How many tools at the FRONT of the array are the session's stable base.
  #
  # `Agent.Loop.ToolDiscovery` appends tools mid-session when a `tool_search`
  # hit surfaces something the model could otherwise never call, and tags each
  # one `discovered?: true`. Those appended schemas are new bytes in the most
  # cache-sensitive position in the request. Putting the tools breakpoint on the
  # very last tool would move it past them, so the request would carry no
  # breakpoint at the boundary the previous turns cached and the whole ~15.5k
  # tool segment would be re-written.
  #
  # Marking the last STABLE tool instead leaves that prefix byte-identical, so
  # Anthropic's tools-tier entry still matches; only the `system` tier — which
  # renders after the tools and therefore genuinely moved — is re-written. That
  # is the difference between a widening costing the tools+system segments and
  # costing system alone.
  #
  # A session that never discovers anything has no tagged tools and this is the
  # last index, i.e. exactly the previous behaviour.
  defp stable_tool_count(tools) do
    case Enum.find_index(tools, &Map.get(&1, :discovered?, false)) do
      nil -> length(tools)
      idx -> idx
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

  # Anthropic's minimum cacheable prefix is 1024 tokens on most models (512 on
  # Opus 5, 2048-4096 on others). Below it a breakpoint silently does nothing —
  # no error, just no cache entry — and a wasted marker is not free: there are
  # four per request, and `enforce_breakpoint_budget/1` pays for a tools marker
  # by dropping one out of the SYSTEM array. So the threshold has to be a real
  # estimate of the segment, not an under-count.
  #
  # 4,500 bytes, measured: the default 23-tool array serializes to 33,897 bytes
  # and Anthropic counts it as ~8,267 tokens — 4.1 bytes/token. 4,500 bytes is
  # therefore ~1,100 tokens, just clear of the 1024 floor. (The old 4,000 was
  # calibrated against a count that omitted `input_schema`, so it was neither a
  # byte figure nor a token figure.)
  #
  # The figure now lives in `PromptCache.min_cacheable_bytes/0`, shared with the
  # system side above and with `Bedrock`, because three copies of one minimum is
  # how they drift.
  defp min_cacheable_tools_bytes, do: PromptCache.min_cacheable_bytes()

  defp mark_tools_cache_boundary(%{tools: tools} = body, stable_count)
       when is_list(tools) and tools != [] do
    # The breakpoint goes on the last STABLE tool. `stable_count` is the full
    # length unless discovery appended something, and is clamped to at least one
    # so a pathological all-discovered array still gets a usable marker.
    boundary = tools |> length() |> min(max(stable_count, 1))
    cacheable = Enum.take(tools, boundary)
    bytes = tools_payload_bytes(cacheable)
    caching? = prompt_caching_enabled?()
    place? = caching? and bytes >= min_cacheable_tools_bytes()

    report_tools_cache_decision(place?, caching?, bytes, length(cacheable))

    if place? do
      {leading, [last | trailing]} = Enum.split(tools, boundary - 1)
      marked = leading ++ [Map.put(last, "cache_control", %{"type" => "ephemeral"})] ++ trailing

      body
      |> Map.put(:tools, marked)
      |> enforce_breakpoint_budget()
    else
      body
    end
  end

  defp mark_tools_cache_boundary(body, _stable_count), do: body

  @doc """
  Bytes the tool array actually contributes to the request.

  This is what decides whether the tools cache breakpoint is placed, so it has
  to measure what is sent. It used to sum `name` + `description` only and ignore
  `input_schema`, which is the larger half: the default 23-tool array measures
  20,271 bytes that way against 33,897 on the wire — a 40% under-count, i.e. the
  threshold was effectively 1.7x higher than the constant said.

  On the full default toolbox the gap did not change the outcome (20,271 clears
  4,000 either way). It changed it on every TRIMMED array, and `ToolFilter`
  trims constantly — small-window budget, coordinator mode, `FastPath` intent
  sets. Measured, the `:team` intent set (`delegate` + `task_write`) came to
  3,022 by the old count and 6,973 on the wire: ~1,700 tokens, comfortably
  cacheable, and it got no breakpoint. `delegate` alone is 1,357 vs 4,115.

  Serialized rather than summed per field so it stays correct as the tool shape
  changes: JSON punctuation and key names are bytes Anthropic bills too.
  """
  @spec tools_payload_bytes([map()]) :: non_neg_integer()
  def tools_payload_bytes(tools) when is_list(tools) do
    case Jason.encode(tools) do
      {:ok, json} ->
        byte_size(json)

      # A tool whose schema will not serialize is a request that is about to
      # fail anyway; fall back to a field sum so the measurement cannot be the
      # thing that raises. Deliberately still counts the schema.
      _ ->
        Enum.reduce(tools, 0, fn tool, acc ->
          acc + byte_size(to_string(tool["name"])) + byte_size(to_string(tool["description"])) +
            byte_size(inspect(tool["input_schema"]))
        end)
    end
  end

  # The loss this whole function guards against was silent for as long as it
  # existed: no breakpoint, no error, no log — just a tools segment re-billed at
  # full rate every turn. A skip is therefore reported at :info, with the numbers
  # that produced it, and a placement at :debug. Deduped on the decision shape so
  # a steady-state session logs once, not once per turn — a line per turn would
  # be noise, and noise is how the next one of these gets missed.
  defp report_tools_cache_decision(placed?, caching?, bytes, count) do
    reason =
      cond do
        placed? -> :placed
        not caching? -> :caching_disabled
        true -> :below_min_cacheable
      end

    :telemetry.execute(
      [:osa, :anthropic, :tools_cache],
      %{bytes: bytes, tool_count: count, threshold: min_cacheable_tools_bytes()},
      %{placed: placed?, reason: reason}
    )

    signature = {reason, count, div(bytes, 1_000)}

    if Process.get(:osa_tools_cache_decision) != signature do
      Process.put(:osa_tools_cache_decision, signature)
      tokens = PromptCache.approx_tokens(bytes)

      case reason do
        :placed ->
          Logger.debug(
            "[Anthropic] tools cache breakpoint placed: #{count} tools, #{bytes} B (~#{tokens} tok)"
          )

        :caching_disabled ->
          Logger.debug(
            "[Anthropic] tools cache breakpoint skipped: prompt caching disabled " <>
              "(#{count} tools, #{bytes} B)"
          )

        :below_min_cacheable ->
          Logger.info(
            "[Anthropic] tools cache breakpoint NOT placed: #{count} tools, #{bytes} B " <>
              "(~#{tokens} tok) is below the #{min_cacheable_tools_bytes()} B minimum — " <>
              "this tool segment is re-billed in full every turn."
          )
      end
    end
  end

  # Global cap across the whole body. `maybe_add_system/2` caps the SYSTEM array
  # on its own, and runs before tools are added, so it cannot know a tools
  # breakpoint is coming. Walk the body in wire order — tools, then system — and
  # drop any marker past the limit. Wire order is also stable-prefix order: an
  # earlier marker covers a longer stable prefix than a later one, so keeping
  # the earliest is the right policy, and it is the same rule
  # `cap_cache_breakpoints/1` already applies within the system array.
  defp enforce_breakpoint_budget(body) do
    tools = Map.get(body, :tools) || []
    system = Map.get(body, :system)

    tool_markers = Enum.count(tools, &Map.has_key?(&1, "cache_control"))

    case system do
      blocks when is_list(blocks) ->
        remaining = @max_cache_breakpoints - tool_markers
        Map.put(body, :system, cap_cache_breakpoints(blocks, remaining))

      _ ->
        body
    end
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

  # Guarded: a non-binary `message` (nested object, validation list) would
  # otherwise reach a string interpolation at the call sites and raise
  # Protocol.UndefinedError instead of producing a classifiable error.
  defp extract_error(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
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
