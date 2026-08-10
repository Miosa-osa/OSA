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

  @default_model "gpt-5.2-codex"

  # The Codex-only catalogue. These ids are NOT available on api.openai.com
  # and the plain `openai` provider's list is not available here, which is a
  # second reason the two providers stay separate.
  @models [
    "gpt-5.2-codex",
    "gpt-5.1-codex-max",
    "gpt-5.1-codex-mini",
    "gpt-5.2"
  ]

  @spec name() :: atom()
  def name, do: :openai_codex

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
    with {:ok, cred} <- Auth.credential() do
      OpenAIResponses.chat(
        cred.base_url,
        cred.access_token,
        model(opts),
        messages,
        request_opts(cred, opts)
      )
    else
      {:error, reason} -> {:error, auth_error(reason)}
    end
  end

  @spec chat_stream(list(), function(), keyword()) :: :ok | {:error, term()}
  def chat_stream(messages, callback, opts \\ []) do
    with {:ok, cred} <- Auth.credential() do
      OpenAIResponses.chat_stream(
        cred.base_url,
        cred.access_token,
        model(opts),
        messages,
        callback,
        request_opts(cred, opts)
      )
    else
      {:error, reason} -> {:error, auth_error(reason)}
    end
  end

  defp model(opts), do: Keyword.get(opts, :model) || default_model()

  # The account id and originator travel with the credential, so a call site
  # never assembles subscription identity headers by hand — and therefore can
  # never attach them to a provider the credential does not belong to.
  defp request_opts(cred, opts) do
    opts
    |> Keyword.put(:account_id, cred.account_id)
    |> Keyword.put(:originator, Auth.originator())
    |> Keyword.delete(:model)
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
