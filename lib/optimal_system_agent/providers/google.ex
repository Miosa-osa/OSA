defmodule OptimalSystemAgent.Providers.Google do
  @moduledoc """
  Google Gemini provider — Gemini API (`generativelanguage.googleapis.com`).

  ## Which Google API this is

  Google ships two different products with different auth, endpoints and
  request shapes: the **Gemini API** (API key, `generativelanguage.googleapis.com`)
  and **Vertex AI** (OAuth/ADC + a GCP project, `*-aiplatform.googleapis.com`).
  OSA targets the Gemini API, which is the right choice for a BYOK user pasting
  a key: Vertex would require a service-account JSON, a project id and a region
  before the first request. Vertex is **not** supported — a Vertex-only key will
  not work here.

  Within the Gemini API, Google introduced the **Interactions API**
  (`POST /v1beta/interactions`) and now describes `generateContent` as *legacy*,
  though it "remains fully supported" with no announced shutdown. OSA stays on
  `generateContent` deliberately — see "Known gaps" below.

  ## This is NOT an OpenAI-compatible shim

  Gemini takes `contents` with `role`/`parts` (never OpenAI `messages`),
  `systemInstruction` as a separate top-level field (never a system *message*),
  `generationConfig` for sampling, and `tools[].functionDeclarations` for tools.
  Roles are `"user"` and `"model"` — **`"assistant"` and `"tool"` are both
  invalid** and are translated below.

  ## Known gaps (deliberate, not oversights)

    * **No streaming.** This module implements `chat/2` only, so
      `Registry.chat_stream/3` falls back to a synchronous call and emits the
      whole answer in one delta. Correct, but the TUI shows nothing until the
      turn finishes. Adding `streamGenerateContent?alt=sse` is a self-contained
      follow-up.
    * **Interactions API not adopted.** Migrating is a rewrite of the request,
      response and streaming shapes at once, and `generateContent` is still
      fully supported. Worth noting that Interactions defaults `store: true`,
      persisting conversations server-side — an active decision for an agent
      handling private source, and another reason not to switch silently.

  ## Safety defaults are already permissive

  For Gemini 2.5 and 3 models Google's default block threshold is **Off**, so
  configurable safety filters cannot silently truncate a legitimate coding
  response and OSA does not need to send `safetySettings`. Sending anything
  *stricter* is what would cause spurious blocks.
  Source: https://ai.google.dev/gemini-api/docs/safety-settings

  Config keys:
    :google_api_key — required (GOOGLE_API_KEY / GEMINI_API_KEY)
    :google_model   — (default: `Providers.GoogleModels.default_model/0`)
    :google_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.GoogleModels

  @default_url "https://generativelanguage.googleapis.com/v1beta"

  @impl true
  def name, do: :google

  # Single source of truth: Providers.GoogleModels. `gemini-2.0-flash` (OSA's
  # default until 2026-08-01) was shut down 2026-06-01; the `gemini-2.5-*`
  # family shuts down 2026-10-16, inside the 90-day guard, so it is no longer
  # offered either. See GoogleModels for the full reasoning and sources.
  @impl true
  def default_model, do: GoogleModels.default_model()

  @impl true
  def available_models, do: GoogleModels.ids()

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :google_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :google_model, default_model())

    base_url = Application.get_env(:optimal_system_agent, :google_url, @default_url)

    unless api_key do
      {:error, "GOOGLE_API_KEY not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    formatted = format_messages(messages)
    {system_instruction, contents} = extract_system(formatted)

    body =
      %{contents: contents}
      |> maybe_add_system_instruction(system_instruction)
      |> maybe_add_generation_config(model, opts)
      |> maybe_add_tools(opts)

    # The API key goes in the `x-goog-api-key` HEADER, not a `?key=` query
    # parameter. Every current Google example uses the header, and the query
    # form is no longer documented anywhere. It also leaked the key into
    # anything that records a URL — Req debug logs, error messages, proxies —
    # which a header does not.
    url = "#{base_url}/models/#{model}:generateContent"

    headers = [
      {"Content-Type", "application/json"},
      {"x-goog-api-key", api_key}
    ]

    # Thinking models can take 300+ s for complex reasoning.
    timeout = if thinking_model?(model), do: 600_000, else: 120_000

    try do
      case Req.post(url, json: body, headers: headers, receive_timeout: timeout) do
        {:ok, %{status: 200, body: resp}} ->
          content = extract_content(resp)
          tool_calls = extract_tool_calls(resp)
          {:ok, %{content: content, tool_calls: tool_calls, usage: extract_usage(resp)}}

        {:ok, %{status: status, body: resp_body}} ->
          error_msg = extract_error(resp_body)
          Logger.warning("Google Gemini returned #{status}: #{error_msg}")
          {:error, "Google Gemini returned #{status}: #{error_msg}"}

        {:error, reason} ->
          Logger.error("Google Gemini connection failed: #{inspect(reason)}")
          {:error, "Google Gemini connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Google Gemini unexpected error: #{Exception.message(e)}")
        {:error, "Google Gemini unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private ---

  # Normalize atom-keyed messages to string keys.
  #
  # The old version matched `%{role: role, content: content}` and rebuilt the
  # map with ONLY those two keys — so `:tool_calls` and `:tool_call_id` were
  # discarded here, before `extract_system/1` could ever see them. That is the
  # upstream half of the broken tool round-trip: even a correct `contents`
  # builder had nothing to work with. Every key is preserved now.
  defp format_messages(messages) do
    Enum.map(messages, fn
      %{"role" => _} = msg ->
        msg

      msg when is_map(msg) ->
        Map.new(msg, fn {k, v} -> {to_string(k), v} end)

      other ->
        %{"role" => "user", "content" => to_string(other)}
    end)
  end

  @doc """
  Test seam: build the `{systemInstruction_text, contents}` pair for a raw
  message list, without a live HTTP call.
  """
  def build_contents(messages), do: messages |> format_messages() |> extract_system()

  # Only LEADING system messages are the system prompt.
  #
  # The bug this replaces: `Enum.split_with(messages, &(&1["role"] == "system"))`
  # hoisted EVERY system-role message onto `systemInstruction`, wherever it sat.
  # `ReactLoop`'s steering paths (auto-continue, coding nudge, verification gate,
  # VerificationGate directive, reasoning-only backstop — ~7 call sites) each
  # append TWO messages: the assistant's text, then a `role: "system"` nudge that
  # is meant to be the LAST thing the model reads. Hoisting lifted that nudge out
  # of the conversation and buried it in background context.
  #
  # Unlike Anthropic — where the same defect stranded a trailing assistant turn
  # and produced a hard 400 — Gemini happily accepts a trailing `model` turn, so
  # this failed SILENTLY: no error, just degraded steering. Which is why there is
  # no `ensure_trailing_user` analogue here: it is not needed and adding it would
  # inject a phantom turn into every tool-calling round trip.
  #
  # A system message that appears after the conversation has started is mid-turn
  # steering and stays in `contents`, demoted to a `user` turn — the only role
  # Gemini offers for "input the model must act on" (`contents` accepts exactly
  # "user" and "model"; there is no system role, and "model" would make OSA's own
  # directive read as something Gemini already said).
  defp extract_system(messages) do
    {sys_msgs, rest} = Enum.split_while(messages, &(&1["role"] == "system"))

    system_text =
      case sys_msgs do
        [] -> nil
        msgs -> Enum.map_join(msgs, "\n\n", &to_string(&1["content"] || ""))
      end

    chat_msgs =
      Enum.map(rest, fn
        %{"role" => "system"} = msg -> Map.put(msg, "role", "user")
        msg -> msg
      end)

    # Gemini accepts exactly two roles: "user" and "model". "assistant" and
    # "tool" are both INVALID and are translated here.
    #
    # The tool round-trip was previously lost entirely: an assistant turn's
    # `tool_calls` were dropped (only its text survived) and a tool RESULT was
    # emitted with role "tool", which Gemini rejects. So any turn that called a
    # tool either errored or silently lost the fact that the tool ran, and the
    # model would call it again. Gemini keys a function response by NAME, not
    # by call id, so the id→name map is carried forward from the preceding
    # assistant turn.
    {contents, _names} =
      Enum.map_reduce(chat_msgs, %{}, fn msg, names ->
        content_part(msg, names)
      end)

    contents =
      contents
      |> Enum.reject(&(&1["parts"] == []))
      |> collapse_same_role()

    {system_text, contents}
  end

  # Merge adjacent same-role turns into one turn with multiple parts.
  #
  # Google's reference says the role "should alternate between user and model",
  # and consecutive same-role `contents` are reported in the wild as
  # 400 INVALID_ARGUMENT; the accepted remedy is collapsing them rather than
  # dropping one. Demoting a mid-conversation system nudge to `user` can produce
  # exactly that shape (e.g. a tool result — already emitted as a `user` turn —
  # followed immediately by a nudge), so the collapse runs unconditionally.
  #
  # It is deliberately restricted to TEXT-ONLY turns: a `functionCall` /
  # `functionResponse` part must stay in the turn Gemini pairs it with, so the
  # tool round-trip is left byte-for-byte as it was.
  defp collapse_same_role(contents) do
    contents
    |> Enum.reduce([], fn c, acc ->
      case acc do
        [prev | rest] ->
          if prev["role"] == c["role"] and text_only?(prev) and text_only?(c) do
            [Map.put(prev, "parts", prev["parts"] ++ c["parts"]) | rest]
          else
            [c | acc]
          end

        [] ->
          [c]
      end
    end)
    |> Enum.reverse()
  end

  defp text_only?(%{"parts" => parts}), do: Enum.all?(parts, &Map.has_key?(&1, "text"))
  defp text_only?(_), do: false

  # Tool result → a "user" turn carrying a functionResponse part.
  defp content_part(%{"role" => "tool"} = msg, names) do
    id = to_string(msg["tool_call_id"] || msg["id"] || "")
    name = msg["name"] || Map.get(names, id) || "unknown_function"

    part = %{
      "functionResponse" => %{
        "name" => name,
        # Gemini requires an OBJECT here, so a plain string result is wrapped.
        "response" => %{"result" => to_string(msg["content"] || "")}
      }
    }

    {%{"role" => "user", "parts" => [part]}, names}
  end

  # Assistant turn → a "model" turn; text and any functionCall parts together.
  defp content_part(%{"role" => "assistant"} = msg, names) do
    calls = msg["tool_calls"] || []

    names =
      Enum.reduce(calls, names, fn c, acc ->
        Map.put(acc, to_string(c[:id] || c["id"] || ""), c[:name] || c["name"])
      end)

    text = to_string(msg["content"] || "")
    text_parts = if text == "", do: [], else: [%{"text" => text}]

    call_parts =
      Enum.map(calls, fn c ->
        %{
          "functionCall" => %{
            "name" => c[:name] || c["name"],
            "args" => c[:arguments] || c["arguments"] || %{}
          }
        }
      end)

    {%{"role" => "model", "parts" => text_parts ++ call_parts}, names}
  end

  defp content_part(msg, names) do
    {%{"role" => "user", "parts" => [%{"text" => to_string(msg["content"] || "")}]}, names}
  end

  defp maybe_add_system_instruction(body, nil), do: body
  defp maybe_add_system_instruction(body, ""), do: body

  defp maybe_add_system_instruction(body, text) do
    Map.put(body, :systemInstruction, %{
      "parts" => [%{"text" => text}]
    })
  end

  defp maybe_add_generation_config(body, model, opts) do
    config =
      %{}
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:maxOutputTokens, Keyword.get(opts, :max_tokens))
      |> maybe_add_thinking_config(model, opts)

    if map_size(config) > 0 do
      Map.put(body, :generationConfig, config)
    else
      body
    end
  end

  @doc """
  Test seam: build just the thinking portion of the `generationConfig` for a
  model + opts, without a live HTTP call.

  Returns one of:

    * `%{thinkingLevel: "minimal"|"low"|"medium"|"high"}` — Gemini 3.x, which
      takes an effort ENUM;
    * `%{thinkingConfig: %{thinkingBudget: N}}` — Gemini 2.5, the legacy token
      budget;
    * `%{}` — the model has no thinking mode, or thinking was turned off on a
      model that permits it.

  **`thinkingLevel` and `thinkingBudget` are mutually exclusive** — sending
  both in one request is an error — which is why the dialect is selected from
  `GoogleModels.thinking_mode/1` rather than guessed.
  """
  def build_thinking_config(model, opts), do: maybe_add_thinking_config(%{}, model, opts)

  # Thinking dialect is per-model, from the single source of truth.
  #
  # The bug this replaces: the predicate was `String.contains?(name, "2.5")`.
  # When the default moved to `gemini-3.6-flash` that went false, so OSA sent
  # NO thinking configuration at all and the whole `Agent.Effort` ladder was a
  # silent no-op on Google — the user could select :ultra and get default
  # thinking. It was also the wrong dialect: 3.x wants a level, not a budget.
  defp maybe_add_thinking_config(config, model, opts) do
    case GoogleModels.thinking_mode(model) do
      :level -> put_thinking_level(config, model, opts)
      :budget -> put_thinking_budget(config, opts)
      :none -> config
    end
  end

  # Gemini 3.x — `thinkingLevel`, clamped into the levels this model accepts
  # (Pro has no "minimal"). Thinking cannot be fully disabled on any Gemini 3
  # model, so an "off" effort resolves to the model's floor, not to omission.
  defp put_thinking_level(config, model, opts) do
    effort =
      Keyword.get(opts, :reasoning_effort) ||
        Keyword.get(opts, :effort) ||
        current_effort()

    case GoogleModels.thinking_level(model, effort) do
      level when is_binary(level) -> Map.put(config, :thinkingLevel, level)
      _ -> config
    end
  end

  # Gemini 2.5 — the legacy raw token budget.
  #
  # `is_integer` guard: a caller passing `thinking_budget: nil` (or any
  # non-integer) must NOT emit `thinkingBudget: nil` — Elixir term ordering
  # makes `nil > 0` true (atom > number), so an unguarded `budget > 0` would
  # send a bogus null budget. Fall through to the no-op instead (W4 harden).
  defp put_thinking_budget(config, opts) do
    budget = Keyword.get(opts, :thinking_budget, 8192)

    if is_integer(budget) and budget > 0 do
      Map.put(config, :thinkingConfig, %{thinkingBudget: budget})
    else
      config
    end
  end

  defp current_effort do
    OptimalSystemAgent.Agent.Effort.current()
  rescue
    _ -> "medium"
  catch
    _, _ -> "medium"
  end

  # True when the model has ANY thinking mode — used only to widen the HTTP
  # timeout, so it must not care which dialect.
  defp thinking_model?(model), do: GoogleModels.thinking_mode(model) != :none

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, [%{"functionDeclarations" => format_tools(tools)}])
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    end)
  end

  defp extract_content(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts
    |> Enum.filter(&Map.has_key?(&1, "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_content(_), do: ""

  defp extract_tool_calls(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts
    |> Enum.filter(&Map.has_key?(&1, "functionCall"))
    |> Enum.map(fn part ->
      fc = part["functionCall"]

      %{
        id: generate_id(),
        name: fc["name"],
        arguments: fc["args"] || %{}
      }
    end)
  end

  defp extract_tool_calls(_), do: []

  # Guarded: a non-binary `message` (nested object, validation list) would
  # otherwise reach a string interpolation at the call sites and raise
  # Protocol.UndefinedError instead of producing a classifiable error.
  defp extract_error(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body), do: inspect(body)

  # Extract token usage from Gemini's usageMetadata so Accounting/Pricing record
  # real spend. Without this every Gemini turn recorded 0 tokens / $0, leaving
  # the hard budget cap permanently blind on Google.
  # `thoughtsTokenCount` is BILLED AS OUTPUT but is reported in its own field,
  # separate from `candidatesTokenCount`. Counting only the latter under-reports
  # spend on every thinking turn — and since thinking cannot be disabled on any
  # Gemini 3 model, that is every turn. On a high-effort turn the thought tokens
  # can exceed the visible answer, so this was not a rounding error.
  defp extract_usage(%{"usageMetadata" => meta}) when is_map(meta) do
    thoughts = meta["thoughtsTokenCount"] || 0

    %{
      input_tokens: meta["promptTokenCount"] || 0,
      output_tokens: (meta["candidatesTokenCount"] || 0) + thoughts
    }
  end

  defp extract_usage(_), do: %{}

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
