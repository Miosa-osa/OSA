defmodule OptimalSystemAgent.Providers.OpenAICodex do
  @moduledoc """
  The `openai_codex` provider: ChatGPT Plus/Pro plan inference over the
  Responses API.

  A **separate provider entry** from `openai`, not a second auth mode on it.
  That is the right split because the two differ in more than the credential:
  a different base URL (`chatgpt.com/backend-api/codex`), a different wire
  protocol (Responses, not chat/completions) and a different, Codex-only model
  catalogue. Folding them together would mean every call site branching on
  auth kind — the thing this design exists to avoid. OSA already uses this
  pattern for `ollama_cloud` / `ollama_local`.

  Credentials come only from `Auth.SubscriptionStore` via
  `Auth.Providers.OpenAICodex` — there is no API-key path here, because an
  OpenAI API key belongs on the `openai` provider where it is billed
  per-token against the correct endpoint.

  ## Plan limits are not billing limits

  A subscription's failure mode is the opposite of a key's. A key overspends
  and bills you; a plan hits a window and **stops**, then resets. So a 429
  here is not "slow down and retry with backoff", it is "you are out until
  the window rolls". `rate_limit_info/1` surfaces the `x-codex-*` headers that
  carry that state so the UI can show remaining quota rather than presenting a
  hard wait as a transient blip.
  """

  require Logger

  alias OptimalSystemAgent.Auth.Providers.OpenAICodex, as: Auth
  alias OptimalSystemAgent.Providers.OpenAIResponses

  @default_model "gpt-5.6-sol"

  # The Codex-only catalogue. These ids are NOT available on api.openai.com
  # and the plain `openai` provider's list is not available here, which is a
  # second reason the two providers stay separate.
  #
  # Transcribed from what the Codex CLI itself offers a signed-in ChatGPT plan
  # (its "Select Model and Effort" screen), NOT from a blog post or a guess.
  # The previous list — gpt-5.2-codex, gpt-5.1-codex-max, gpt-5.1-codex-mini,
  # gpt-5.2 — had aged out entirely: none of those ids appear in that screen
  # any more, so OSA was defaulting a freshly signed-in user onto a model their
  # plan no longer offers. Codex names its own current default `gpt-5.6-sol`,
  # which is why that is the default here too.
  #
  # This list needs re-checking whenever OpenAI moves the Codex line. The
  # authoritative source is the Codex CLI's own picker for a signed-in plan;
  # `codex -m <name>` still reaches older ids that the picker has dropped.
  @models [
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex-spark"
  ]

  @spec name() :: atom()
  def name, do: :openai_codex

  # Tool schemas ride in a dedicated field of the request body, not in the
  # system-prompt text. See Providers.Behaviour.native_tool_schemas?/0.
  def native_tool_schemas?, do: true

  @spec supports_image_content?() :: boolean()
  def supports_image_content?, do: true

  @spec default_model() :: String.t()
  def default_model,
    do: Application.get_env(:optimal_system_agent, :openai_codex_model, @default_model)

  @spec available_models() :: [String.t()]
  def available_models, do: @models

  @doc "True when a ChatGPT plan is connected. Pure read — never refreshes."
  @spec configured?() :: boolean()
  def configured?, do: Auth.status().connected?

  @spec chat(list(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    with_reauth(fn cred ->
      OpenAIResponses.chat(
        cred.base_url,
        cred.access_token,
        model(opts),
        messages,
        request_opts(cred, opts)
      )
    end)
  end

  @spec chat_stream(list(), function(), keyword()) :: :ok | {:error, term()}
  def chat_stream(messages, callback, opts \\ []) do
    with_reauth(fn cred ->
      OpenAIResponses.chat_stream(
        cred.base_url,
        cred.access_token,
        model(opts),
        messages,
        callback,
        request_opts(cred, opts)
      )
    end)
  end

  @doc false
  # Reactive re-authentication: run the request, and if the server says 401,
  # refresh once and run it exactly once more.
  #
  # ## Why "exactly once", and why it is safe to retry at all
  #
  # A 401 means the token OSA presented was not accepted, so the request never
  # reached the model — nothing was generated, nothing was billed, and no
  # partial output was streamed to the caller (the transport reports the status
  # before any body is consumed). That makes it one of the very few errors
  # where re-sending is not a duplicate.
  #
  # The retry is capped at one because a second 401 after a successful refresh
  # is not a token problem: the account has lost entitlement, or the request
  # itself is being rejected, and re-refreshing would loop while burning a
  # rotating refresh token each time. If the refresh itself fails, its reason
  # is surfaced — `Auth.Subscription.message/2` already distinguishes
  # "revoked, sign in again" from "quota exhausted, your sign-in is fine", and
  # this is precisely the path that used to flatten both into "HTTP 401".
  @spec with_reauth((map() -> result)) :: result | {:error, String.t()} when result: term()
  def with_reauth(run) when is_function(run, 1) do
    case Auth.credential() do
      {:ok, cred} ->
        case run.(cred) do
          {:error, {:unauthorized, detail}} -> retry_after_refresh(cred, run, detail)
          other -> other
        end

      {:error, reason} ->
        {:error, auth_error(reason)}
    end
  end

  defp retry_after_refresh(cred, run, detail) do
    Logger.info(
      "[Codex] Request rejected as unauthorized; refreshing the token and retrying once."
    )

    # Scoped to the token that was actually rejected: if another process
    # already rotated it, the fresh one is adopted with no network call and no
    # second spend of the refresh token. See `Auth.Providers.OpenAICodex.force_refresh/1`.
    case Auth.force_refresh(cred.access_token) do
      {:ok, _token} ->
        case Auth.credential() do
          {:ok, fresh} ->
            case run.(fresh) do
              # Still refused with a token minted seconds ago. This is not a
              # credential problem any more, and saying "sign in again" here
              # would be the misleading advice the error catalogue exists to
              # prevent.
              {:error, {:unauthorized, second}} ->
                {:error,
                 "#{Auth.display_name()} refused the request even after a successful token refresh " <>
                   "(#{describe(second)}). Your sign-in is valid; the account may have lost access to " <>
                   "this model or plan."}

              other ->
                other
            end

          {:error, reason} ->
            {:error, auth_error(reason)}
        end

      {:error, reason} ->
        Logger.warning("[Codex] Token refresh after a 401 failed: #{inspect(reason)}")
        {:error, auth_error(reason) <> refusal_suffix(detail)}
    end
  end

  defp describe(detail) when is_binary(detail) and detail != "", do: detail
  defp describe(_), do: "no detail given"

  # Keep the server's own words, which are frequently more specific than
  # anything OSA can infer, without letting them replace the actionable line.
  defp refusal_suffix(detail) when is_binary(detail) and detail != "",
    do: " (the server said: #{detail})"

  defp refusal_suffix(_), do: ""

  defp model(opts), do: Keyword.get(opts, :model) || default_model()

  # The account id and originator travel with the credential, so a call site
  # never assembles subscription identity headers by hand — and therefore can
  # never attach them to a provider the credential does not belong to.
  defp request_opts(cred, opts) do
    opts
    |> Keyword.put(:account_id, cred.account_id)
    |> Keyword.put(:originator, Auth.originator())
    |> Keyword.delete(:model)
    # The ChatGPT Codex endpoint rejects `max_output_tokens` outright (with an
    # empty HTTP 400), even though the public Responses API accepts it. The
    # agent loop supplies `max_tokens` for every provider, so strip it at this
    # provider boundary and let Codex enforce its own output ceiling.
    |> Keyword.delete(:max_tokens)
  end

  defp auth_error(reason) do
    OptimalSystemAgent.Auth.Subscription.message(reason, Auth.display_name())
  end

  @doc """
  Extract plan rate-limit state from response headers.

  Returns `nil` when the headers are absent, so callers can distinguish "not
  reported" from "reported as zero" — presenting an unknown quota as an
  exhausted one would be worse than showing nothing.
  """
  @spec rate_limit_info(map() | list()) :: map() | nil
  def rate_limit_info(headers) do
    get = fn key ->
      case headers do
        h when is_map(h) -> h |> Map.get(key, []) |> List.wrap() |> List.first()
        h when is_list(h) -> Enum.find_value(h, fn {k, v} -> if k == key, do: v end)
        _ -> nil
      end
    end

    used = get.("x-codex-primary-used-percent")

    if is_nil(used) do
      nil
    else
      %{
        used_percent: to_number(used),
        window_minutes: to_number(get.("x-codex-primary-window-minutes")),
        resets_at: get.("x-codex-primary-reset-at"),
        limit_name: get.("x-codex-limit-name")
      }
    end
  end

  defp to_number(nil), do: nil

  defp to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      _ -> nil
    end
  end

  defp to_number(v) when is_number(v), do: v
  defp to_number(_), do: nil
end
