defmodule OptimalSystemAgent.Providers.Bedrock do
  @moduledoc """
  Amazon Bedrock, signed with SigV4 against the operator's own AWS account.

  ## Why Converse and not `/invoke`

  Bedrock exposes two runtime shapes:

    * `POST /model/{id}/invoke` passes a **model-family-native** body straight
      through. An Anthropic model wants the Anthropic Messages body, Nova
      wants Amazon's, Llama wants a `prompt` string, Mistral wants something
      else again. Supporting Bedrock through `invoke` therefore means writing
      and maintaining one request/response adapter *per family*, and getting
      tool-calling right N times — for models OSA cannot test against.
    * `POST /model/{id}/converse` is AWS's own normalisation of exactly that
      problem: one request shape, one response shape, one tool-use
      representation, for every family that supports them.

  This module uses **Converse**. The staging asked for — non-streaming first,
  the binary event-stream parser as a separate second step — is unchanged by
  that choice, because `converse-stream` uses the same
  `application/vnd.amazon.eventstream` framing that
  `invoke-with-response-stream` does. What changes is that OSA gets every
  Bedrock model family from one adapter instead of one family from one
  adapter. That is the whole reason.

  ## Streaming is deliberately absent, for now

  `chat_stream/3` is not implemented. `Providers.Registry` treats a module
  without it as sync-only and calls `chat/2`, so Bedrock works end to end
  today — it simply delivers its answer in one piece. Shipping a half-parsed
  binary frame format would be worse than shipping no streaming: the failure
  mode of a mis-framed event stream is truncated or duplicated model output,
  which is indistinguishable from the model behaving badly.

  ## Authentication

  There is no API key in the usual sense. Two modes, both handled here:

    * **Account** — the AWS credential chain, SigV4-signed per request. OSA
      holds nothing; see `Auth.Providers.Bedrock`.
    * **Bearer key** — `AWS_BEARER_TOKEN_BEDROCK`, sent as
      `Authorization: Bearer …`, which AWS added so a Bedrock credential can
      be used without an AWS SDK. Same host, same models, same body — only the
      credential differs, which is why they are two modes of one provider
      rather than two providers.

  Precedence is **explicit key first**: a user who pasted a bearer token is
  stating an intent, and an auto-discovered `~/.aws/credentials` must never
  silently outrank it and bill a different account.
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Auth.AwsSigV4
  alias OptimalSystemAgent.Auth.Providers.Bedrock, as: Auth
  alias OptimalSystemAgent.Providers.CacheAttribution
  alias OptimalSystemAgent.Providers.ImageBudget
  alias OptimalSystemAgent.Providers.PromptCache

  # A concrete, currently-served cross-region inference profile rather than a
  # bare model id: Bedrock increasingly requires the `<geo>.` prefixed profile
  # for on-demand access to newer models, and a plain id returns a
  # ValidationException that reads like the model does not exist.
  @default_model "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  @impl true
  def name, do: :bedrock

  # Tool schemas ride in a dedicated field of the request body, not in the
  # system-prompt text. See Providers.Behaviour.native_tool_schemas?/0.
  @impl true
  def native_tool_schemas?, do: true

  @impl true
  # Matched on shape, not on `Application.get_env/3`'s default argument:
  # `config/runtime.exs` sets this key to `System.get_env("BEDROCK_MODEL")`,
  # which is `nil` when unset — and a key that EXISTS with a nil value never
  # reaches the third-argument default. Reading it this way is what keeps an
  # unset override from resolving the model to `nil`.
  def default_model do
    case Application.get_env(:optimal_system_agent, :bedrock_model) do
      v when is_binary(v) and v != "" -> v
      _ -> @default_model
    end
  end

  @impl true
  def available_models, do: [default_model()]

  @doc """
  The model ids this AWS account can actually call, from the control plane.

  Returns `{:ok, []}` rather than a guess when the account has nothing
  enabled, and never falls back to a hardcoded list — a picker offering models
  the account cannot invoke produces a failure at the first turn, several
  screens away from the mistake.
  """
  @spec list_models() :: {:ok, [map()]} | {:error, term()}
  def list_models do
    with {:ok, %{credentials: creds, region: region}} <- Auth.credential(),
         {:ok, summaries} <- Auth.list_foundation_models(creds, region) do
      {:ok,
       summaries
       |> Enum.filter(&text_capable?/1)
       |> Enum.map(fn m ->
         %{
           id: m["modelId"],
           name: "#{m["providerName"]} #{m["modelName"]}",
           ctx: 0,
           tools: true
         }
       end)}
    end
  end

  # `ctx: 0` above is not an unfilled placeholder — ListFoundationModels does
  # not report context windows, and the picker's contract is that 0 means
  # "unknown, do not display" rather than "zero tokens". Inventing a number
  # per family would be a guess rendered as a fact.
  defp text_capable?(%{"outputModalities" => out} = m) when is_list(out) do
    "TEXT" in out and "TEXT" in (m["inputModalities"] || ["TEXT"])
  end

  defp text_capable?(_), do: true

  # ── chat ──────────────────────────────────────────────────────────────────

  @impl true
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model) || default_model()

    case resolve_auth() do
      {:ok, auth} -> do_chat(auth, model, messages, opts)
      {:error, reason} -> {:error, auth_error(reason)}
    end
  end

  @doc """
  True — Converse turns carry `image` blocks (see `content_blocks/1`).

  Asked by `Registry.normalize_message_content/3` before it decides whether to
  flatten an image block into a text placeholder.
  """
  @spec supports_image_content?() :: boolean()
  def supports_image_content?, do: true

  @doc """
  Test seam: the exact Converse request body for `messages`, without a live
  HTTP call or credentials.
  """
  @spec build_request_body(list(), String.t(), keyword()) :: map()
  def build_request_body(messages, model, opts \\ []) do
    {system, conversation} = split_system(messages)

    %{"messages" => format_messages(conversation)}
    |> maybe_put_service_tier(Keyword.get(opts, :service_tier))
    |> put_unless_empty("system", Enum.map(system, &%{"text" => &1}))
    |> put_inference_config(opts)
    |> put_tool_config(opts)
    |> put_reasoning_config(model, opts)
    # AFTER the system blocks and the tool list both exist — this appends a
    # marker to each of them and cannot run before they are assembled.
    |> put_cache_points(model, opts)
    # Every provider gets the image byte-budget, not just Anthropic. Without it
    # an oversized image body is a hard provider error instead of a
    # degraded-but-honest request.
    |> ImageBudget.gate_unsupported(:bedrock, model)
    |> ImageBudget.apply(provider: :bedrock)
  end

  # Bedrock Converse expects a tagged object, not the bare tier string used by
  # OpenAI-compatible and Gemini APIs.
  defp maybe_put_service_tier(body, nil), do: body
  defp maybe_put_service_tier(body, tier), do: Map.put(body, "serviceTier", %{"type" => tier})

  defp do_chat(auth, model, messages, opts) do
    body = build_request_body(messages, model, opts)
    payload = Jason.encode!(body)
    cache_fp = CacheAttribution.fingerprint(attribution_view(body, model))
    cache_scope = CacheAttribution.scope(opts)

    # The model id goes in the PATH, so it must be percent-encoded for the
    # wire — except that a colon is a legal path character and AWS's own SDKs
    # send it literally. `AwsSigV4` re-encodes for the canonical request only,
    # which is why nothing is pre-encoded here.
    url = "#{auth.base_url}/model/#{model}/converse"

    headers = sign(auth, "POST", url, payload)

    request =
      Keyword.merge(
        [
          url: url,
          headers: headers,
          body: payload,
          receive_timeout: Keyword.get(opts, :receive_timeout, 300_000),
          retry: false,
          decode_body: true
        ],
        # Test seam. Kept separate from `:auth_req_options` on purpose: the
        # auth key stubs the CONTROL plane (the free capability check) and
        # this one stubs the RUNTIME plane (billed inference). A test that
        # could accidentally point one at the other would be able to assert
        # that a metered call was free.
        Application.get_env(:optimal_system_agent, :bedrock_req_options, [])
      )

    case Req.post(request) do
      {:ok, %{status: 200, body: resp}} ->
        usage = extract_usage(resp)

        # Diagnostics only — cannot fail the request (see CacheAttribution).
        # Bedrock is the second route to carry this. Before the `cachePoint`
        # above there was nothing here to attribute: the cache read it watches
        # was structurally pinned at 0, so a break could never be observed and
        # a cache that never warmed could never be reported.
        CacheAttribution.observe(cache_scope, cache_fp, usage)

        {:ok,
         %{
           content: extract_text(resp),
           tool_calls: extract_tool_calls(resp),
           usage: usage,
           # Converse's terminal `stopReason` — `"max_tokens"` on truncation.
           # `Providers.StopReason` owns the mapping; the raw value is published
           # unchanged. UNVERIFIED live — documented shape, synthetic tests only.
           stop_reason: resp["stopReason"]
         }}

      {:ok, %{status: status, body: resp}} ->
        detail = Auth.aws_message(resp)
        Logger.warning("Bedrock returned #{status}: #{detail}")
        {:error, http_error(status, detail)}

      {:error, e} ->
        {:error, "Bedrock connection failed: #{Exception.message(e)}"}
    end
  rescue
    e -> {:error, "Bedrock unexpected error: #{Exception.message(e)}"}
  end

  # `CacheAttribution.fingerprint/1` keys on `:model` / `:system` / `:tools` /
  # `:messages`. A Converse body carries the model in the URL and its tools one
  # level down under `toolConfig`, so a raw body would fingerprint as "no model,
  # no tools" and a tool-schema edit — the single most common real cache break —
  # would be attributed to "request params changed". This is the same body,
  # named the way the attributor reads.
  defp attribution_view(body, model) do
    %{
      model: model,
      system: Map.get(body, "system", []),
      tools: attribution_tools(get_in(body, ["toolConfig", "tools"]) || []),
      messages: Map.get(body, "messages", []),
      inference_config: Map.get(body, "inferenceConfig"),
      additional_model_request_fields: Map.get(body, "additionalModelRequestFields")
    }
  end

  # `tools_fingerprint/1` reads `name` off each tool so it can tell "tool added"
  # from "this tool's schema changed". Converse nests both a level down inside
  # `toolSpec`, so unlifted every Bedrock tool would fingerprint with the name
  # `""` and a schema edit would be reported as a whole tool-set change.
  # The trailing `cachePoint` marker is a tool-list ENTRY, so it is lifted too —
  # under its own stable name, which is what makes a marker appearing or
  # disappearing (the `:below_minimum` boundary) show up as its own cause.
  defp attribution_tools(tools) do
    Enum.map(tools, fn
      %{"toolSpec" => spec} -> Map.put(spec, "name", spec["name"] || "")
      %{"cachePoint" => cp} -> %{"name" => "__cachePoint__", "cachePoint" => cp}
      other -> other
    end)
  end

  # ── auth ──────────────────────────────────────────────────────────────────

  # Explicit bearer key beats the auto-discovered credential chain. See the
  # moduledoc: this ordering is the "explicit user intent wins" rule, and
  # inverting it bills a different AWS account than the one the user named.
  defp resolve_auth do
    case bearer_token() do
      token when is_binary(token) ->
        with {:ok, region} <- bearer_region() do
          {:ok,
           %{mode: :bearer, token: token, region: region, base_url: Auth.runtime_url(region)}}
        end

      nil ->
        case Auth.credential() do
          {:ok, cred} -> {:ok, Map.put(cred, :mode, :sigv4)}
          err -> err
        end
    end
  end

  defp bearer_token do
    case Application.get_env(:optimal_system_agent, :bedrock_api_key) ||
           OptimalSystemAgent.Onboarding.live_env("AWS_BEARER_TOKEN_BEDROCK") do
      v when is_binary(v) -> if String.trim(v) == "", do: nil, else: String.trim(v)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp bearer_region do
    case OptimalSystemAgent.Auth.AwsCredentials.region() do
      {:ok, region} ->
        {:ok, region}

      {:error, _} ->
        # A bearer token carries no region, and Bedrock has no global
        # endpoint. Rather than guessing an account's region, say what is
        # missing — this is the one field a bearer-key user must still supply.
        {:error, {:aws_no_region_for_key}}
    end
  end

  defp sign(%{mode: :bearer, token: token}, _method, _url, _payload) do
    [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp sign(%{mode: :sigv4} = auth, method, url, payload) do
    AwsSigV4.sign(
      method,
      url,
      [{"content-type", "application/json"}, {"accept", "application/json"}],
      payload,
      auth.credentials,
      region: auth.region,
      service: auth.service
    )
  end

  defp auth_error({:aws_no_region_for_key}),
    do:
      "An Amazon Bedrock API key is set but no region is. Bedrock has no global endpoint — " <>
        "export AWS_REGION (e.g. `export AWS_REGION=us-east-1`)."

  defp auth_error(reason), do: Auth.message(reason)

  # A 403 on the RUNTIME plane after a successful connect almost always means
  # the model itself is not enabled for the account, not that the credential
  # is bad — Bedrock gates model access per-model, per-region. Saying "check
  # your credentials" here sends the user to the wrong screen.
  defp http_error(403, detail),
    do:
      "Bedrock refused this model (403): #{detail} " <>
        "Most often the model is not enabled for your account in this region — " <>
        "enable it under Bedrock → Model access in the AWS console."

  defp http_error(400, detail),
    do:
      "Bedrock rejected the request (400): #{detail} " <>
        "If this names the model id, try the cross-region inference profile form " <>
        "(`us.` / `eu.` / `apac.` prefix), which newer models require for on-demand use."

  defp http_error(429, detail),
    do: "Bedrock is throttling this account (429): #{detail}"

  defp http_error(status, detail), do: "Bedrock returned #{status}: #{detail}"

  # ── request shaping ───────────────────────────────────────────────────────

  # Converse takes system prompts in their own top-level field, not as a
  # message with `role: "system"`. Leaving them in the message list is
  # rejected outright rather than ignored.
  defp split_system(messages) do
    Enum.reduce(messages, {[], []}, fn msg, {sys, conv} ->
      case role(msg) do
        "system" -> {sys ++ [flatten_text(content(msg))], conv}
        _ -> {sys, conv ++ [msg]}
      end
    end)
  end

  defp format_messages(messages) do
    messages
    |> Enum.map(&format_message/1)
    |> merge_adjacent()
  end

  defp format_message(%{role: "tool"} = msg), do: tool_result(msg)
  defp format_message(%{"role" => "tool"} = msg), do: tool_result(msg)

  defp format_message(msg) do
    blocks =
      content_blocks(content(msg)) ++
        Enum.map(tool_calls_of(msg), fn tc ->
          %{
            "toolUse" => %{
              "toolUseId" => to_string(tc[:id] || tc["id"]),
              "name" => to_string(tc[:name] || tc["name"]),
              "input" => tc[:arguments] || tc["arguments"] || %{}
            }
          }
        end)

    # Converse rejects a message with an empty content array. An assistant
    # turn that produced only tool calls and no prose is a normal, common
    # shape, so the empty case gets one empty text block rather than being
    # dropped — dropping it would break the tool_use/tool_result pairing the
    # very next message depends on.
    %{
      "role" => converse_role(role(msg)),
      "content" => if(blocks == [], do: [%{"text" => ""}], else: blocks)
    }
  end

  defp tool_result(msg) do
    id = msg[:tool_call_id] || msg["tool_call_id"]

    %{
      "role" => "user",
      "content" => [
        %{
          "toolResult" => %{
            "toolUseId" => to_string(id),
            "content" => [%{"text" => flatten_text(content(msg))}]
          }
        }
      ]
    }
  end

  # Converse requires strictly alternating user/assistant turns. OSA emits one
  # message per tool result, so a turn with three tool calls produces three
  # consecutive `user` messages — which Bedrock rejects with a
  # ValidationException that says nothing about tools. Merging them here is
  # not a nicety; without it, parallel tool use never works.
  defp merge_adjacent(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case acc do
        [%{"role" => role, "content" => prev} = last | rest]
        when role == :erlang.map_get("role", msg) ->
          [%{last | "content" => prev ++ Map.fetch!(msg, "content")} | rest]

        _ ->
          [msg | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp converse_role("assistant"), do: "assistant"
  defp converse_role(_), do: "user"

  # Converse content blocks. `flatten_text/1` alone matched only text shapes and
  # ended `_ -> ""`, so an `image` block from `MessageHandler.build_messages/3`
  # was SILENTLY DROPPED and the model answered as though nothing were attached
  # — a confident answer about an image it never received. Converse has a real
  # image block, so images are carried rather than discarded.
  defp content_blocks(content) when is_list(content) do
    content
    |> Enum.map(&content_block/1)
    |> Enum.reject(&is_nil/1)
    |> merge_text_runs()
  end

  defp content_blocks(content), do: text_blocks(content)

  defp content_block(block) when is_binary(block), do: text_block(block)

  defp content_block(%{type: "image", source: source}), do: image_block(source)
  defp content_block(%{"type" => "image", "source" => source}), do: image_block(source)

  defp content_block(%{"image" => _} = block), do: block

  defp content_block(block) do
    case flatten_text([block]) do
      "" -> nil
      text -> text_block(text)
    end
  end

  defp text_block(""), do: nil
  defp text_block(text), do: %{"text" => text}

  # Converse names the format, not a MIME type, and accepts exactly these four.
  # An unknown media type is refused with an explicit note rather than dropped.
  @bedrock_formats %{
    "image/png" => "png",
    "image/jpeg" => "jpeg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @image_unsupported "[An image was attached but could not be sent to this model in a format it accepts. Do not describe or reason about it; ask the user to re-share it as PNG, JPEG, GIF or WebP.]"

  defp image_block(source) when is_map(source) do
    media_type = Map.get(source, :media_type, Map.get(source, "media_type"))
    data = Map.get(source, :data, Map.get(source, "data"))

    case {Map.get(@bedrock_formats, media_type), data} do
      {fmt, d} when is_binary(fmt) and is_binary(d) and d != "" ->
        %{"image" => %{"format" => fmt, "source" => %{"bytes" => d}}}

      _ ->
        text_block(@image_unsupported)
    end
  end

  defp image_block(_), do: text_block(@image_unsupported)

  # Adjacent text blocks are concatenated into one, with NO separator — exactly
  # what the old `flatten_text/1` (`Enum.map_join(content, "", ..)`) produced, so
  # a text-only turn is byte-identical to the request Bedrock received before.
  defp merge_text_runs(blocks) do
    blocks
    |> Enum.reduce([], fn
      %{"text" => t}, [%{"text" => prev} | rest] -> [%{"text" => prev <> t} | rest]
      block, acc -> [block | acc]
    end)
    |> Enum.reverse()
  end

  defp text_blocks(content) do
    case flatten_text(content) do
      "" -> []
      text -> [%{"text" => text}]
    end
  end

  defp put_inference_config(body, opts) do
    config =
      %{}
      |> maybe_put("maxTokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("topP", Keyword.get(opts, :top_p))

    if config == %{}, do: body, else: Map.put(body, "inferenceConfig", config)
  end

  @doc """
  Whether this turn asks Bedrock for extended reasoning, and why.

  `{budget_tokens | nil, source}` — source is `:opt`, `:effort`,
  `:disabled_by_config`, `:fast_mode`, `:effort_off` or `:model_unsupported`.

  ## Why this exists

  Bedrock had **no reasoning path at all**. The whole `Agent.Effort` ladder was
  a silent no-op here: five tiers produced five byte-identical requests, on a
  provider whose default model is `us.anthropic.claude-sonnet-4-5` — a model
  built around extended thinking. Same defect class as the Google `:budget`
  branch and the Anthropic-native gate, and the same cost: reasoning is worth
  roughly 10-11 points (cline's published Terminal-Bench 2.0 run on glm-5.2:
  68.5% with, 57.3% without).

  ## Wire shape

  Converse carries model-specific parameters in `additionalModelRequestFields`,
  and Anthropic models on Bedrock take:

      "additionalModelRequestFields": {
        "reasoning_config": {"type": "enabled", "budget_tokens": N}
      }

  Two constraints come with it, both enforced in `put_reasoning_config/3`:
  `budget_tokens` must be >= 1024 and strictly less than
  `inferenceConfig.maxTokens`, and `temperature` / `topP` must not be sent —
  Bedrock rejects the request otherwise. That is why this runs AFTER
  `put_inference_config/2`: it has to be able to take those keys back out.

  > #### Unverified against a live call {: .warning}
  >
  > There are no Bedrock credentials on this machine. This is implemented
  > against AWS's documented Converse request shape and tested against
  > synthetic payloads through `build_request_body/3` only. **No request built
  > by this code has been sent to Bedrock.** Treat the wire shape as inferred,
  > not confirmed.
  """
  @spec reasoning_decision(String.t() | nil, keyword()) :: {pos_integer() | nil, atom()}
  # Anthropic's minimum. Below it Bedrock refuses the request.
  @min_reasoning_budget 1_024

  def reasoning_decision(model, opts \\ []) do
    alias OptimalSystemAgent.Agent.Effort

    cond do
      not reasoning_model?(model) ->
        {nil, :model_unsupported}

      is_integer(explicit = Keyword.get(opts, :thinking_budget)) and explicit > 0 ->
        {max(explicit, @min_reasoning_budget), :opt}

      not Application.get_env(:optimal_system_agent, :thinking_enabled, true) ->
        {nil, :disabled_by_config}

      Effort.fast_mode?() ->
        {nil, :fast_mode}

      true ->
        case Effort.thinking_budget() do
          n when is_integer(n) and n > 0 -> {max(n, @min_reasoning_budget), :effort}
          # The `:off` rung is thinking_budget: 0 — an explicit "no thinking",
          # not an accident, so it is honoured rather than floored up.
          _ -> {nil, :effort_off}
        end
    end
  end

  # Only Anthropic models on Bedrock take `reasoning_config`. Nova and Titan use
  # different fields, and DeepSeek-R1 reasons with no request field at all —
  # sending them an Anthropic-shaped one is a ValidationException, so an
  # unrecognised model gets nothing. This is the narrow case where an unknown
  # must NOT default the capability on: the field is provider-proprietary and
  # the failure is a hard 400 rather than a degraded answer, which is exactly
  # the distinction `openai_compat.maybe_add_provider_thinking/4` draws.
  defp reasoning_model?(model) when is_binary(model) do
    name = String.downcase(model)
    String.contains?(name, "anthropic.") or String.contains?(name, "claude")
  end

  defp reasoning_model?(_), do: false

  defp put_reasoning_config(body, model, opts) do
    case reasoning_decision(model, opts) do
      {nil, _source} ->
        body

      {budget, source} ->
        max_tokens = get_in(body, ["inferenceConfig", "maxTokens"])

        # `budget_tokens` must be strictly less than `maxTokens`. When the caller
        # asked for fewer output tokens than the reasoning budget, the budget
        # yields — a clamped-but-thinking request beats a rejected one.
        budget =
          if is_integer(max_tokens),
            do: min(budget, max_tokens - 1),
            else: budget

        if budget < @min_reasoning_budget do
          report_reasoning(model, nil, :max_tokens_too_small)
          body
        else
          report_reasoning(model, budget, source)

          body
          # Bedrock refuses `temperature`/`topP` alongside reasoning.
          |> update_in_inference_config(&Map.drop(&1, ["temperature", "topP"]))
          |> Map.put("additionalModelRequestFields", %{
            "reasoning_config" => %{"type" => "enabled", "budget_tokens" => budget}
          })
        end
    end
  end

  defp update_in_inference_config(body, fun) do
    case Map.get(body, "inferenceConfig") do
      config when is_map(config) ->
        case fun.(config) do
          empty when map_size(empty) == 0 -> Map.delete(body, "inferenceConfig")
          kept -> Map.put(body, "inferenceConfig", kept)
        end

      _ ->
        body
    end
  end

  # Reasoning was absent here for the whole life of the provider and nothing
  # said so. Telemetry on every decision, and a one-off :info per {model,
  # source} so the state is legible in a log rather than only in a request dump.
  defp report_reasoning(model, budget, source) do
    :telemetry.execute(
      [:osa, :bedrock, :reasoning],
      %{budget_tokens: budget || 0},
      %{model: model, reason: source, enabled: not is_nil(budget)}
    )

    key = {model, source, budget}

    if Process.get(:osa_bedrock_reasoning) != key do
      Process.put(:osa_bedrock_reasoning, key)

      case budget do
        nil ->
          Logger.info("[Bedrock] reasoning off for #{model} (#{source})")

        n ->
          Logger.info("[Bedrock] reasoning on for #{model}: budget_tokens=#{n} (#{source})")
      end
    end
  end

  # ── prompt caching ────────────────────────────────────────────────────────

  @doc """
  Whether this turn asks Bedrock to cache its static prefix, and why.

  `{[:system | :tools], source}` — the scopes that get a `cachePoint`, and one
  of `:enabled`, `:disabled_by_config`, `:model_unsupported` or `:below_minimum`.

  ## Why this exists

  **No `cachePoint` appeared anywhere in `lib/`.** Bedrock serves Anthropic
  models and supports the same prompt cache the native Anthropic path uses —
  `extract_usage/1` right below even parses `cacheReadInputTokens` and files it
  under `:cache_read_input_tokens`, and `:bedrock` sits in `Accounting`'s
  `@disjoint_prompt_slices` on the strength of that. Without a request-side
  marker that counter reads **0 on every turn, forever**, and the two things
  that read it — session cost and `Providers.CacheAttribution` — were describing
  a cache that could not exist.

  This is the same defect as the rest of the sweep pointed at the request rather
  than a guard: a capability asserted on the response side with no path on the
  request side, reporting a plausible zero instead of an error. The measured
  win on the paths that DO carry it is 92.8% of the static prefix served from
  cache; here it was 0%.

  ## Wire shape

  `cachePoint` is a content block, not a parameter. It marks the END of a
  cacheable prefix and is legal in three places in a Converse body:

      "system":  [{"text": "…"}, {"cachePoint": {"type": "default"}}]
      "toolConfig": {"tools": [{"toolSpec": {…}}, {"cachePoint": {"type": "default"}}]}
      "messages": [{"role": …, "content": [{"text": "…"}, {"cachePoint": …}]}]

  OSA marks **system and tools only**. Those two are the static prefix — the
  same two scopes `Anthropic.maybe_add_system/2` and its tools-side sibling
  mark — and they are stable across a session. A marker inside `messages` would
  have to move every turn, which writes a new cache entry per turn and bills the
  write premium for a prefix that is never read back.

  ## The minimum is real and silent

  Anthropic models refuse to cache a prefix below roughly 1,024 tokens, and the
  refusal is not an error: the request succeeds and the marker is ignored. So a
  marker on a short prefix costs the cache-write premium for nothing. The byte
  threshold is `PromptCache.min_cacheable_bytes/0` — the ONE named constant the
  Anthropic system side, the Anthropic tools side and this route all read, after
  a period in which the same minimum existed as three separate numbers (4,000,
  4,500 and 4,500) held equal by comment — and a prefix under it is skipped WITH
  a line saying so.

  > #### Unverified against a live call {: .warning}
  >
  > There are no Bedrock credentials on this machine. Implemented against AWS's
  > documented Converse `cachePoint` shape and tested against synthetic payloads
  > through `build_request_body/3`. **No request built by this code has been
  > sent to Bedrock**, so neither the field name nor the resulting
  > `cacheReadInputTokens` has been observed. Treat the wire shape as inferred.
  """
  @spec cache_point_decision(String.t() | nil, keyword()) :: {[atom()], atom()}

  @cache_point %{"cachePoint" => %{"type" => "default"}}

  def cache_point_decision(model, opts \\ []) do
    cond do
      not cache_point_model?(model) ->
        {[], :model_unsupported}

      not PromptCache.enabled?() ->
        {[], :disabled_by_config}

      true ->
        {Keyword.get(opts, :__scopes__, [:system, :tools]), :enabled}
    end
  end

  # ~1,024 tokens of prefix. Read from the shared constant rather than restated:
  # a comment promising to hold two numbers equal is not a mechanism.
  defp min_cacheable_bytes, do: PromptCache.min_cacheable_bytes()

  # Only Anthropic models on Bedrock are known to honour `cachePoint` with the
  # 1,024-token minimum OSA's threshold is calibrated to. Amazon Nova supports
  # it too but with different minimums, and an unknown family gets nothing:
  # an ignored marker is cheap, but a marker that splits a prefix the model
  # would otherwise have cached whole is not. Same asymmetry `reasoning_model?/1`
  # applies one function up.
  defp cache_point_model?(model) when is_binary(model) do
    name = String.downcase(model)
    String.contains?(name, "anthropic.") or String.contains?(name, "claude")
  end

  defp cache_point_model?(_), do: false

  defp put_cache_points(body, model, opts) do
    case cache_point_decision(model, opts) do
      {[], source} ->
        report_cache_points(model, [], source)
        body

      {scopes, source} ->
        {body, marked} =
          Enum.reduce(scopes, {body, []}, fn scope, {acc, marked} ->
            case mark_scope(acc, scope) do
              {:ok, acc} -> {acc, [scope | marked]}
              :skip -> {acc, marked}
            end
          end)

        marked = Enum.reverse(marked)
        report_cache_points(model, marked, if(marked == [], do: :below_minimum, else: source))
        body
    end
  end

  defp mark_scope(body, :system) do
    case Map.get(body, "system") do
      blocks when is_list(blocks) and blocks != [] ->
        if serialized_bytes(blocks) >= min_cacheable_bytes() and not marked?(blocks),
          do: {:ok, Map.put(body, "system", blocks ++ [@cache_point])},
          else: :skip

      _ ->
        :skip
    end
  end

  defp mark_scope(body, :tools) do
    case get_in(body, ["toolConfig", "tools"]) do
      tools when is_list(tools) and tools != [] ->
        if serialized_bytes(tools) >= min_cacheable_bytes() and not marked?(tools),
          do: {:ok, put_in(body, ["toolConfig", "tools"], tools ++ [@cache_point])},
          else: :skip

      _ ->
        :skip
    end
  end

  defp mark_scope(_body, _scope), do: :skip

  defp marked?(list), do: Enum.any?(list, &is_map_key(&1, "cachePoint"))

  defp serialized_bytes(term) do
    term |> Jason.encode_to_iodata!() |> IO.iodata_length()
  end

  # The whole point of the fix is that a cache which never warms must be
  # legible without a request dump. `:below_minimum` and `:model_unsupported`
  # are reported as loudly as success — they are the arms under which
  # `cacheReadInputTokens` stays 0, and an unexplained 0 is what this cost us.
  defp report_cache_points(model, scopes, source) do
    :telemetry.execute(
      [:osa, :bedrock, :prompt_cache],
      %{scopes: length(scopes)},
      %{model: model, scopes: scopes, reason: source, enabled: scopes != []}
    )

    key = {model, scopes, source}

    if Process.get(:osa_bedrock_cache_points) != key do
      Process.put(:osa_bedrock_cache_points, key)

      case {scopes, source} do
        {[], :below_minimum} ->
          Logger.info(
            "[Bedrock] prompt cache NOT marked for #{model}: static prefix is under " <>
              "#{min_cacheable_bytes()} bytes, below the ~1,024-token minimum Anthropic " <>
              "models cache. cache_read_input_tokens will stay 0."
          )

        {[], reason} ->
          Logger.info(
            "[Bedrock] prompt cache off for #{model} (#{reason}); " <>
              "cache_read_input_tokens will stay 0"
          )

        {marked, _} ->
          Logger.info(
            "[Bedrock] prompt cache marked for #{model}: cachePoint on #{Enum.join(marked, "+")}"
          )
      end
    end

    :ok
  end

  defp put_tool_config(body, opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) and tools != [] ->
        Map.put(body, "toolConfig", %{"tools" => Enum.map(tools, &tool_spec/1)})

      _ ->
        body
    end
  end

  # OSA's canonical tool shape is OpenAI's (`%{type: "function", function:
  # %{name, description, parameters}}`), with a flat variant also in
  # circulation. Both are accepted so a caller never has to know which
  # provider is downstream.
  defp tool_spec(%{"function" => f}), do: tool_spec_from(f)
  defp tool_spec(%{function: f}), do: tool_spec_from(f)
  defp tool_spec(tool), do: tool_spec_from(tool)

  defp tool_spec_from(f) do
    schema = f[:parameters] || f["parameters"] || f[:input_schema] || f["input_schema"] || %{}

    %{
      "toolSpec" => %{
        "name" => to_string(f[:name] || f["name"]),
        "description" => to_string(f[:description] || f["description"] || ""),
        "inputSchema" => %{"json" => schema}
      }
    }
  end

  # ── response parsing ──────────────────────────────────────────────────────

  defp extract_text(%{"output" => %{"message" => %{"content" => blocks}}}) when is_list(blocks) do
    blocks
    |> Enum.filter(&is_map_key(&1, "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_text(_), do: ""

  defp extract_tool_calls(%{"output" => %{"message" => %{"content" => blocks}}})
       when is_list(blocks) do
    for %{"toolUse" => use} <- blocks do
      %{
        id: to_string(use["toolUseId"]),
        name: to_string(use["name"]),
        arguments: use["input"] || %{}
      }
    end
  end

  defp extract_tool_calls(_), do: []

  # Bedrock reports usage on every Converse response. Passed through rather
  # than recomputed — a locally estimated token count that disagrees with the
  # bill is worse than none.
  #
  # The KEY NAMES are the whole point. `Loop.Accounting.normalize_usage/1` reads
  # exactly four keys — `:input_tokens`, `:output_tokens`,
  # `:cache_creation_input_tokens`, `:cache_read_input_tokens` — and nothing
  # else. This used to emit `:prompt_tokens` / `:completion_tokens` /
  # `:total_tokens`, none of which it looks at, so **every Bedrock turn
  # accounted as 0 tokens and $0.00**: the session cost, the `max_budget_usd`
  # cap, the spend sidecar and `$/task` were all blind on this provider, exactly
  # the way Google was before `extract_usage/1` was added there.
  #
  # Cache slices: Bedrock serves Anthropic models and supports the same
  # `cache_control` blocks, and the Converse response reports
  # `cacheReadInputTokens` / `cacheWriteInputTokens` alongside `inputTokens`.
  # They are DISJOINT from `inputTokens` (Anthropic's convention, which Bedrock
  # mirrors) — which is why `:bedrock` sits in `Accounting`'s
  # `@disjoint_prompt_slices` list and must stay there. If AWS ever made
  # `inputTokens` inclusive, the fix is to move the atom to
  # `@inclusive_prompt_slices`, NOT to subtract here.
  #
  # UNVERIFIED against a live Bedrock call — implemented against the documented
  # Converse response shape and covered by synthetic-payload tests only. The
  # field names are the risk; the arithmetic is not.
  defp extract_usage(%{"usage" => u}) when is_map(u) do
    %{
      input_tokens: u["inputTokens"] || 0,
      output_tokens: u["outputTokens"] || 0,
      cache_read_input_tokens: u["cacheReadInputTokens"] || 0,
      cache_creation_input_tokens: u["cacheWriteInputTokens"] || 0
    }
  end

  defp extract_usage(_),
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }

  # ── small helpers ─────────────────────────────────────────────────────────

  defp role(%{role: r}), do: to_string(r)
  defp role(%{"role" => r}), do: to_string(r)
  defp role(_), do: "user"

  defp content(%{content: c}), do: c
  defp content(%{"content" => c}), do: c
  defp content(_), do: ""

  defp tool_calls_of(%{tool_calls: tc}) when is_list(tc), do: tc
  defp tool_calls_of(%{"tool_calls" => tc}) when is_list(tc), do: tc
  defp tool_calls_of(_), do: []

  defp flatten_text(content) when is_binary(content), do: content

  defp flatten_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{type: "text", text: t} -> to_string(t)
      %{"type" => "text", "text" => t} -> to_string(t)
      %{text: t} -> to_string(t)
      %{"text" => t} -> to_string(t)
      other when is_binary(other) -> other
      _ -> ""
    end)
  end

  defp flatten_text(nil), do: ""
  defp flatten_text(other), do: to_string(other)

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
