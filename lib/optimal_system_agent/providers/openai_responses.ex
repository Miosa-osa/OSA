defmodule OptimalSystemAgent.Providers.OpenAIResponses do
  @moduledoc """
  OpenAI **Responses API** wire protocol.

  A separate transport from `Providers.OpenAICompat` (chat/completions), used
  only by the `openai_codex` provider. The existing `openai` provider and
  `openai_compat.ex` are deliberately untouched: the two protocols differ in
  request shape, streaming events and usage keys, and a working path being
  quietly reshaped by a change aimed at something else is the failure mode
  this project has been bitten by most often. Unifying them, if it ever makes
  sense, is a separate deliberate change with the old path already proven
  against the new one.

  ## How Responses differs from chat/completions

  | | chat/completions | Responses |
  |---|---|---|
  | payload | `messages: [{role, content}]` | `input: [items]` |
  | system prompt | a `system` message | top-level `instructions` |
  | tools | `{type: "function", function: {name, …}}` | **flat** `{type: "function", name, …}` |
  | tool call | `message.tool_calls[]` | `function_call` output items |
  | tool result | `role: "tool"` message | `function_call_output` input item |
  | streaming | `choices[].delta` | typed `response.*` events |
  | usage | `prompt_tokens` / `completion_tokens` | `input_tokens` / `output_tokens` |

  The streaming surface is narrow — five event types carry everything OSA
  needs — which is why this adapter is a few hundred lines rather than a
  reimplementation of the chat/completions module.

  Returns exactly the shapes the rest of OSA already expects from a provider
  (`%{content:, tool_calls:, usage:, stop_reason:}`, and the
  `{:text_delta, _}` / `{:done, result}` callback protocol), so nothing
  downstream has to know which protocol produced them.
  """

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.ReasoningContent
  alias OptimalSystemAgent.Utils.Text

  @doc "Non-streaming completion against the Responses API."
  @spec chat(String.t(), String.t(), String.t(), list(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def chat(base_url, token, model, messages, opts \\ []) do
    body = model |> build_body(messages, opts, false) |> put_prompt_cache_key(opts, base_url)
    timeout = Keyword.get(opts, :receive_timeout, 180_000)

    options =
      [
        url: url(base_url),
        json: body,
        headers: headers(token, opts),
        receive_timeout: timeout
      ] ++ Keyword.get(opts, :req_options, [])

    case Req.post(options) do
      {:ok, %{status: 200, body: resp} = http} when is_map(resp) ->
        record_quota(http)
        {:ok, parse_response(resp, messages)}

      {:ok, %{status: 429} = resp} ->
        {:error, {:rate_limited, retry_after(resp)}}

      {:ok, %{status: 403, body: resp}} ->
        {:error, forbidden_reason(resp)}

      # 401 is returned as a TAGGED reason, not a formatted string, because it
      # is the one status a caller can act on: a subscription transport can
      # refresh and retry. Formatting it here was how "HTTP 401: …" became a
      # dead end with no reactive refresh anywhere behind it.
      {:ok, %{status: 401, body: resp}} ->
        {:error, {:unauthorized, error_message(resp)}}

      {:ok, %{status: status, body: resp}} ->
        {:error, "HTTP #{status}: #{error_message(resp)}"}

      {:error, e} ->
        {:error, "Connection failed: #{Exception.message(e)}"}
    end
  rescue
    e -> {:error, "Unexpected error: #{Exception.message(e)}"}
  end

  @doc """
  Streaming completion.

  `callback` receives `{:text_delta, chunk}` as text arrives and exactly one
  `{:done, result}` at the end — the same contract `OpenAICompat.chat_stream/6`
  offers, so the agent loop is protocol-agnostic.
  """
  @spec chat_stream(String.t(), String.t(), String.t(), list(), function(), keyword()) ::
          :ok | {:error, term()}
  def chat_stream(base_url, token, model, messages, callback, opts \\ []) do
    body = model |> build_body(messages, opts, true) |> put_prompt_cache_key(opts, base_url)
    timeout = Keyword.get(opts, :receive_timeout, 300_000)

    acc = %{content: "", tool_calls: [], usage: %{}, stop_reason: nil, buffer: "", reasoning: ""}
    {:ok, agent} = Agent.start_link(fn -> acc end)

    try do
      options =
        [
          url: url(base_url),
          json: body,
          headers: headers(token, opts),
          receive_timeout: timeout,
          into: fn {:data, data}, ctx ->
            Agent.update(agent, &consume(&1, data, callback))
            {:cont, ctx}
          end
        ] ++ Keyword.get(opts, :req_options, [])

      case Req.post(options) do
        {:ok, %{status: 200} = http} ->
          record_quota(http)
          final = Agent.get(agent, & &1)
          callback.({:done, finalize(final, messages)})
          :ok

        {:ok, %{status: 429} = resp} ->
          {:error, {:rate_limited, retry_after(resp)}}

        {:ok, %{status: 403, body: resp}} ->
          {:error, forbidden_reason(resp)}

        # See the non-streaming clause. A 401 on the streaming path is
        # retryable in exactly the same way, and must be reported the same way
        # or the retry only ever covers half the requests OSA makes.
        {:ok, %{status: 401, body: resp}} ->
          {:error, {:unauthorized, error_message(resp)}}

        {:ok, %{status: status, body: resp}} ->
          {:error, "HTTP #{status}: #{error_message(resp)}"}

        {:error, e} ->
          {:error, "Connection failed: #{Exception.message(e)}"}
      end
    after
      Agent.stop(agent)
    end
  rescue
    e -> {:error, "Unexpected error: #{Exception.message(e)}"}
  end

  defp url(base_url), do: String.trim_trailing(base_url, "/") <> "/responses"

  @doc """
  Assert cache identity to the server with a session-stable `prompt_cache_key`.

  This is codex's model: the key IS the session id — stable for the whole
  thread, regenerated never — so cache identity is asserted rather than
  inferred from a prefix that some later edit might perturb.

  Applied outside `build_body/4` so that function keeps its arity (it has no
  `base_url`), and gated by the same host allowlist as the Chat Completions
  path: the ChatGPT backend the Codex provider talks to is not the public
  Responses API and is not known to accept the field.
  """
  @spec put_prompt_cache_key(map(), keyword(), String.t()) :: map()
  def put_prompt_cache_key(body, opts, base_url) do
    key = Keyword.get(opts, :prompt_cache_key) || Keyword.get(opts, :session_id)

    if OptimalSystemAgent.Providers.OpenAICompat.prompt_cache_key_host?(base_url) and
         is_binary(key) and key != "" do
      Map.put(body, :prompt_cache_key, key)
    else
      body
    end
  end

  # ── Request shaping ─────────────────────────────────────────────────────

  @doc false
  @spec build_body(String.t(), list(), keyword(), boolean()) :: map()
  def build_body(model, messages, opts, stream?) do
    {instructions, input} = split_instructions(messages)

    # The ChatGPT Codex endpoint rejects persisted Responses requests. Codex
    # clients must explicitly opt out of server-side storage; omitting this
    # field currently produces an unhelpful empty HTTP 400 response.
    %{model: model, input: input, stream: stream?, store: false}
    |> put_unless_nil(:instructions, instructions)
    |> put_unless_nil(:service_tier, Keyword.get(opts, :service_tier))
    |> maybe_put_tools(opts)
    |> maybe_put_reasoning(model, opts)
    |> maybe_put_max_tokens(opts)
  end

  @doc """
  Split system messages out of the conversation.

  Responses takes the system prompt as a top-level `instructions` string
  rather than as a message, so leaving system turns in `input` would silently
  demote OSA's steering to ordinary conversation text. Multiple system
  messages are joined rather than last-wins, so nothing is dropped.
  """
  @spec split_instructions(list()) :: {String.t() | nil, list()}
  def split_instructions(messages) do
    {system, rest} =
      Enum.split_with(messages, fn m -> to_string(role_of(m)) == "system" end)

    instructions =
      system
      |> Enum.map(&text_of/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    {if(instructions == "", do: nil, else: instructions), Enum.flat_map(rest, &to_items/1)}
  end

  # One conversation message may expand to SEVERAL Responses input items: an
  # assistant turn that called two tools becomes two `function_call` items, and
  # each tool result is its own `function_call_output`. Hence flat_map.
  defp to_items(message) do
    role = to_string(role_of(message))
    content = text_of(message)
    tool_calls = get(message, :tool_calls) || []

    case role do
      "tool" ->
        parts = input_parts(get(message, :content))

        [
          %{
            type: "function_call_output",
            call_id: get(message, :tool_call_id) || get(message, :id),
            output: if(Enum.any?(parts, &(&1.type == "input_image")), do: parts, else: content)
          }
        ]

      "assistant" ->
        text_item =
          if content in [nil, ""] do
            []
          else
            [
              %{
                type: "message",
                role: "assistant",
                content: [%{type: "output_text", text: content}]
              }
            ]
          end

        text_item ++ Enum.map(tool_calls, &call_item/1)

      _ ->
        [
          %{
            type: "message",
            role: "user",
            content: input_parts(get(message, :content))
          }
        ]
    end
  end

  defp input_parts(content) when is_binary(content), do: [%{type: "input_text", text: content}]

  defp input_parts(content) when is_list(content) do
    parts = Enum.flat_map(content, &input_part/1)
    if parts == [], do: [%{type: "input_text", text: ""}], else: parts
  end

  defp input_parts(content), do: [%{type: "input_text", text: to_string(content || "")}]

  defp input_part(text) when is_binary(text), do: [%{type: "input_text", text: text}]
  defp input_part(%{type: "text", text: text}), do: [%{type: "input_text", text: text}]
  defp input_part(%{"type" => "text", "text" => text}), do: [%{type: "input_text", text: text}]
  defp input_part(%{type: "image", source: source}), do: image_input_part(source)
  defp input_part(%{"type" => "image", "source" => source}), do: image_input_part(source)
  defp input_part(_), do: []

  defp image_input_part(source) do
    media_type = get(source, :media_type) || "image/png"
    data = get(source, :data)
    url = get(source, :url)

    cond do
      is_binary(url) and url != "" ->
        [%{type: "input_image", image_url: url}]

      is_binary(data) and data != "" ->
        [%{type: "input_image", image_url: "data:#{media_type};base64,#{data}"}]

      true ->
        []
    end
  end

  defp call_item(tc) do
    args = get(tc, :arguments) || get(tc, :args) || %{}

    %{
      type: "function_call",
      call_id: get(tc, :id),
      name: get(tc, :name),
      arguments: if(is_binary(args), do: args, else: Jason.encode!(args))
    }
  end

  # Responses flattens the tool schema: name/description/parameters sit at the
  # top level rather than under a nested `function` key. Sending the
  # chat/completions shape here is accepted with the tool silently ignored,
  # which presents as "the model never calls tools" — so this conversion is
  # load-bearing, not cosmetic.
  @doc false
  @spec format_tools(list()) :: list()
  def format_tools(tools) do
    tools
    |> OpenAICompat.format_tools()
    |> Enum.map(fn
      %{"type" => "function", "function" => f} ->
        %{
          "type" => "function",
          "name" => f["name"],
          "description" => f["description"],
          "parameters" => f["parameters"]
        }

      %{type: "function", function: f} ->
        %{
          "type" => "function",
          "name" => get(f, :name),
          "description" => get(f, :description),
          "parameters" => get(f, :parameters)
        }

      other ->
        other
    end)
  end

  defp maybe_put_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) and tools != [] -> Map.put(body, :tools, format_tools(tools))
      _ -> body
    end
  end

  # Effort on the Responses transport, resolved exactly the way the
  # chat/completions transport resolves it.
  #
  # What was here before accepted only a literal "low"/"medium"/"high" and
  # dropped everything else on the floor. Two consequences, both silent:
  #
  #   * OSA's effort ladder is `:fast | :medium | :high | :xhigh | :ultra`.
  #     Three of those five are not in the accepted set, so choosing `xhigh`
  #     on a Codex model sent NO reasoning field and the model ran at its own
  #     default. The `openai_compat` path has mapped the full ladder down for
  #     a long time (`openai_reasoning_effort/1`); this path never learned.
  #   * Nothing on the normal turn path passes `:reasoning_effort` at all —
  #     `openai_compat` reads `Agent.Effort.current()` itself. So on Codex the
  #     setting was inert end to end: `/effort high` changed the status bar
  #     and nothing else.
  #
  # Gated on `OpenAIModels.reasoning?/1`, the single source of truth for
  # "does this model take reasoning_effort instead of temperature". It is a
  # catalog lookup, NOT a prefix scan — the GPT-5.x reasoning models (Codex's
  # entire line-up) have ids beginning `gpt`, which a prefix scan misses.
  defp maybe_put_reasoning(body, model, opts) do
    effort =
      Keyword.get(opts, :reasoning_effort) ||
        Keyword.get(opts, :effort) ||
        current_effort()

    with true <- reasoning_model?(model),
         level when is_binary(level) <- normalize_model_effort(model, effort) do
      Map.put(body, :reasoning, %{effort: level})
    else
      _ -> body
    end
  end

  # Ultra includes Codex-specific orchestration. On the API, use the
  # documented maximum effort rather than silently reducing it to high.
  defp normalize_model_effort("gpt-6-astra", effort) do
    case effort |> to_string() |> String.trim() |> String.downcase() do
      "xhigh" -> "xhigh"
      value when value in ["max", "ultra"] -> "max"
      other -> normalize_effort(other)
    end
  end

  defp normalize_model_effort(_model, effort), do: normalize_effort(effort)

  defp reasoning_model?(model) do
    OptimalSystemAgent.Providers.OpenAIModels.reasoning?(String.downcase(to_string(model)))
  rescue
    _ -> false
  end

  # Same ladder mapping as `OpenAICompat.openai_reasoning_effort/1`. An
  # explicit off/none omits the field; an unrecognised/corrupt value falls back
  # to the model's own default rather than disabling reasoning — a garbage
  # setting must not silently turn a reasoning model into a non-reasoning one.
  defp normalize_effort(effort) do
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

  defp current_effort do
    OptimalSystemAgent.Agent.Effort.current()
  rescue
    _ -> "medium"
  catch
    _, _ -> "medium"
  end

  defp maybe_put_max_tokens(body, opts) do
    case Keyword.get(opts, :max_tokens) do
      n when is_integer(n) and n > 0 -> Map.put(body, :max_output_tokens, n)
      _ -> body
    end
  end

  # ── Headers ─────────────────────────────────────────────────────────────

  @doc false
  @spec headers(String.t(), keyword()) :: list()
  def headers(token, opts) do
    base = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"originator", Keyword.get(opts, :originator, "osa")}
    ]

    case Keyword.get(opts, :account_id) do
      id when is_binary(id) and id != "" ->
        [{"chatgpt-account-id", id}, {"openai-beta", "responses=v1"} | base]

      _ ->
        base
    end
  end

  # ── Non-streaming response ──────────────────────────────────────────────

  @doc false
  @spec parse_response(map(), list()) :: map()
  def parse_response(resp, orig_messages) do
    output = Map.get(resp, "output", []) |> List.wrap()

    content =
      output
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(&List.wrap(&1["content"]))
      |> Enum.filter(&(is_map(&1) and &1["type"] == "output_text"))
      |> Enum.map_join("", &to_string(&1["text"] || ""))
      |> Text.strip_thinking_tokens()

    tool_calls =
      output
      |> Enum.filter(&(&1["type"] == "function_call"))
      |> Enum.map(&decode_call/1)

    # `reasoning` items in `output` carry a `summary` array of
    # `%{"type" => "summary_text", "text" => ...}`. Encrypted reasoning carries
    # no text and yields nothing, by design.
    reasoning =
      output
      |> Enum.filter(&(is_map(&1) and &1["type"] == "reasoning"))
      |> Enum.map_join("", &ReasoningContent.extract(%{"reasoning_details" => &1["summary"]}))

    %{
      content: content,
      tool_calls: tool_calls,
      usage: parse_usage(Map.get(resp, "usage"), orig_messages, content),
      stop_reason: stop_reason(resp, tool_calls)
    }
    |> ReasoningContent.put_result(reasoning)
  end

  defp decode_call(item) do
    args =
      case Jason.decode(to_string(item["arguments"] || "")) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    %{id: item["call_id"] || item["id"], name: item["name"], arguments: args}
  end

  defp stop_reason(resp, tool_calls) do
    cond do
      tool_calls != [] -> "tool_calls"
      resp["status"] == "incomplete" -> incomplete_reason(resp)
      true -> "stop"
    end
  end

  defp incomplete_reason(resp) do
    case get_in(resp, ["incomplete_details", "reason"]) do
      r when is_binary(r) -> r
      _ -> "incomplete"
    end
  end

  # Responses reports `input_tokens`/`output_tokens`; chat/completions reports
  # `prompt_tokens`/`completion_tokens`. Normalised here so Accounting never
  # has to care which protocol served the turn.
  @doc false
  @spec parse_usage(map() | nil, list(), String.t()) :: map()
  def parse_usage(usage, orig_messages, content) when is_map(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    if input > 0 or output > 0 do
      %{
        input_tokens: input,
        output_tokens: output,
        # `:cache_read_input_tokens`, not `:cached_tokens` — CacheAttribution
        # reads the former, so the latter was collected and never seen.
        cache_read_input_tokens: get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0,
        reasoning_tokens: get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0
      }
    else
      estimate(orig_messages, content)
    end
  end

  def parse_usage(_, orig_messages, content), do: estimate(orig_messages, content)

  defp estimate(messages, content) do
    %{
      input_tokens: OptimalSystemAgent.Agent.Context.estimate_tokens_messages(messages),
      output_tokens: OptimalSystemAgent.Agent.Context.estimate_tokens(content || ""),
      estimated: true
    }
  end

  # ── Streaming ───────────────────────────────────────────────────────────

  # Accumulate raw bytes and emit complete SSE records. A chunk boundary can
  # fall anywhere, including mid-UTF8 or mid-JSON, so the tail is carried in
  # `buffer` rather than parsed optimistically.
  @doc false
  @spec consume(map(), binary(), function()) :: map()
  def consume(acc, data, callback) do
    {events, rest} = split_events(acc.buffer <> data)
    Enum.reduce(events, %{acc | buffer: rest}, &apply_event(&2, &1, callback))
  end

  defp split_events(buffer) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/)
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {complete, tail}
  end

  defp apply_event(acc, raw, callback) do
    data =
      raw
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("", &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading()))

    if data in ["", "[DONE]"] do
      acc
    else
      case Jason.decode(data) do
        {:ok, event} when is_map(event) -> handle(acc, event, callback)
        # A malformed frame must not kill a turn that is otherwise streaming
        # fine — drop it and keep going.
        _ -> acc
      end
    end
  end

  # The events that carry everything OSA needs. Anything else (the many
  # `.added` / `.delta` variants for annotations and refusals) is ignored on
  # purpose: reacting to events we do not render would only create ways to
  # double-count. Reasoning summaries used to be in that ignored set; they are
  # not, because OSA DOES render reasoning — in the thinking box.
  defp handle(acc, %{"type" => "response.output_text.delta", "delta" => delta}, callback)
       when is_binary(delta) do
    callback.({:text_delta, delta})
    %{acc | content: acc.content <> delta}
  end

  # Reasoning summary text. The Responses API is the SAME defect as
  # chat/completions' `reasoning` vs `reasoning_content` split, wearing
  # different event names: the summary arrives on its own event stream and the
  # comment below used to call ignoring it deliberate. It is not double-counted
  # by surfacing it — nothing else renders it, and `usage` is untouched
  # (`:reasoning_tokens` stays collected-and-unsummed, see parse_usage/3).
  defp handle(acc, %{"type" => "response.reasoning_summary_text.delta", "delta" => delta}, cb)
       when is_binary(delta) and delta != "" do
    cb.({:thinking_delta, delta})
    %{acc | reasoning: Map.get(acc, :reasoning, "") <> delta}
  end

  defp handle(
         acc,
         %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item},
         _cb
       ) do
    %{acc | tool_calls: acc.tool_calls ++ [decode_call(item)]}
  end

  defp handle(acc, %{"type" => "response.completed", "response" => resp}, _cb) do
    %{acc | usage: Map.get(resp, "usage") || %{}, stop_reason: acc.stop_reason || "stop"}
  end

  defp handle(acc, %{"type" => "response.incomplete", "response" => resp}, _cb) do
    %{acc | usage: Map.get(resp, "usage") || %{}, stop_reason: incomplete_reason(resp)}
  end

  defp handle(acc, %{"type" => "response.failed", "response" => resp}, _cb) do
    Logger.warning("[codex] response.failed: #{error_message(resp)}")
    %{acc | stop_reason: "error"}
  end

  defp handle(acc, _event, _callback), do: acc

  defp finalize(acc, orig_messages) do
    content = Text.strip_thinking_tokens(acc.content)

    %{
      content: content,
      tool_calls: acc.tool_calls,
      usage: parse_usage(acc.usage, orig_messages, content),
      stop_reason: acc.stop_reason || if(acc.tool_calls != [], do: "tool_calls", else: "stop")
    }
    |> ReasoningContent.put_result(Map.get(acc, :reasoning, ""))
  end

  # ── Errors ──────────────────────────────────────────────────────────────

  # A 403 here is usually the edge gate rejecting our `originator`, not a bad
  # credential — and telling a user with a perfectly valid subscription to
  # re-authenticate would send them round a loop that cannot help.
  defp forbidden_reason(resp) do
    message = error_message(resp)

    if message =~ ~r/originator|cloudflare|forbidden|access denied/i or message == "" do
      :originator_rejected
    else
      "HTTP 403: #{message}"
    end
  end

  defp error_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp error_message(%{"error" => e}) when is_binary(e), do: e
  defp error_message(%{"message" => m}) when is_binary(m), do: m
  defp error_message(body) when is_binary(body), do: body
  defp error_message(_), do: ""

  defp retry_after(%{headers: headers}) when is_map(headers) do
    case headers |> Map.get("retry-after", []) |> List.wrap() |> List.first() do
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} -> n
          _ -> nil
        end

      v when is_integer(v) ->
        v

      _ ->
        nil
    end
  end

  defp retry_after(_), do: nil

  # The `x-codex-*` headers are the only place OpenAI reports how much of the
  # plan's rate-limit window is gone, and they ride along on responses OSA was
  # already paying for. Remembering them here is what lets `/usage` answer
  # "what does my account have left" without spending a request to find out —
  # so this is deliberately fire-and-forget and can never fail a turn.
  defp record_quota(%{headers: headers}) do
    OptimalSystemAgent.Usage.RateLimits.record(
      "openai_codex",
      OptimalSystemAgent.Providers.OpenAICodex.rate_limit_info(headers)
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp record_quota(_), do: :ok

  # ── small helpers ───────────────────────────────────────────────────────

  defp role_of(m), do: get(m, :role) || "user"

  defp text_of(m) do
    case get(m, :content) do
      c when is_binary(c) ->
        c

      c when is_list(c) ->
        Enum.map_join(c, "", fn part ->
          cond do
            is_binary(part) -> part
            is_map(part) -> to_string(get(part, :text) || "")
            true -> ""
          end
        end)

      _ ->
        ""
    end
  end

  defp get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get(_, _), do: nil

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
