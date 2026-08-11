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

  # A concrete, currently-served cross-region inference profile rather than a
  # bare model id: Bedrock increasingly requires the `<geo>.` prefixed profile
  # for on-demand access to newer models, and a plain id returns a
  # ValidationException that reads like the model does not exist.
  @default_model "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  @impl true
  def name, do: :bedrock

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

  defp do_chat(auth, model, messages, opts) do
    {system, conversation} = split_system(messages)

    body =
      %{"messages" => format_messages(conversation)}
      |> put_unless_empty("system", Enum.map(system, &%{"text" => &1}))
      |> put_inference_config(opts)
      |> put_tool_config(opts)

    payload = Jason.encode!(body)

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
        {:ok,
         %{
           content: extract_text(resp),
           tool_calls: extract_tool_calls(resp),
           usage: extract_usage(resp)
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
      text_blocks(content(msg)) ++
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
  defp extract_usage(%{"usage" => u}) when is_map(u) do
    %{
      prompt_tokens: u["inputTokens"] || 0,
      completion_tokens: u["outputTokens"] || 0,
      total_tokens: u["totalTokens"] || 0
    }
  end

  defp extract_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

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
