defmodule OptimalSystemAgent.Providers.ConfiguredModel do
  @moduledoc """
  One nil-safe answer to "which model name goes on this request?".

  ## The bug this module exists to make unrepresentable

  `config/runtime.exs` reads every provider's model override straight from the
  environment:

      xai_model: System.get_env("XAI_MODEL"),

  When `XAI_MODEL` is unset that key is **present with the value `nil`** — and
  `Application.get_env/3` only substitutes its third argument when the key is
  *absent*, never when it is present-and-nil. So the idiom every provider used:

      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :xai_model, default_model())

  resolves to `nil` — not to `default_model()` — for any caller that did not
  name a model itself. `OpenAICompat.do_chat/5` then puts that straight into
  the request body as `model: nil`, which serialises to `"model": null`, and
  xAI answers:

      HTTP 422: failed to deserialize the JSON body into the target type
      model: invalid type: null, expected a string at line 1, column 171659

  MEASURED live on `grok-4.6`: `Application.get_env(:optimal_system_agent,
  :xai_model, "grok-4.6")` returned `nil` while
  `OpenAICompatProvider.default_model(:xai)` returned `"grok-4.6"`.

  The 170KB body in that column number is the point: the payload was assembled
  perfectly and only the model field was missing, so the request costs a full
  serialisation and a round-trip before failing.

  ## Why it presented as "compaction is broken"

  Turn requests always name a model — the Loop pins `state.model` at session
  start and passes it as `opts[:model]`, which short-circuits the broken half
  of the `||`. The compaction subsystem does not: `Agent.Compactor.bounded_chat/2`
  is called as `bounded_chat(msgs, temperature: 0.2, max_tokens: 400)` with no
  `:model` at all, so it is the one caller that reaches the app-env lookup on
  every single call. Compaction was therefore the only surface where the defect
  was reachable — and on it, it was reachable 100% of the time.

  ## Which providers were exposed

  Only those whose key is present-and-nil, i.e. read from the environment with
  no `config/config.exs` literal behind it:

      google, deepseek, mistral, replicate, cohere, bedrock, xai, together,
      fireworks, perplexity, qwen, zhipu, moonshot, volcengine, baichuan,
      cerebras, sambanova, hyperbolic, lmstudio, llamacpp

  `anthropic`, `openai`, `openrouter` and `ollama` carry literals in
  `config/config.exs`, which is why the same code was correct for them and the
  defect stayed invisible until a provider from the first list became the
  default. `b186f605` moved the xAI default to `grok-4.6` hours before the
  report.

  ## The rule

  A configured override is a *string or nothing*. `nil`, `""` and anything
  non-binary all mean "not configured" and must fall through to the fallback —
  they must never become the answer. `resolve/3` is the only sanctioned way to
  ask, and `ensure/2` is the loud gate for anything that still comes back
  empty, so an unresolvable model fails by name here instead of as `null` in a
  provider's JSON parser.
  """

  @app :optimal_system_agent

  @doc """
  The configured override for `provider`, or `nil` when there isn't a usable one.

  Treats a present-but-`nil` key, an empty string, and any non-binary value
  identically to an absent key. This is the *whole* fix — every other function
  here is built on it.
  """
  @spec configured(atom() | String.t()) :: String.t() | nil
  def configured(provider) when is_atom(provider) or is_binary(provider) do
    case Application.get_env(@app, :"#{provider}_model") do
      model when is_binary(model) -> presence(model)
      _ -> nil
    end
  end

  def configured(_), do: nil

  @doc """
  Resolve the model for a request: explicit option, then configured override,
  then the provider's compiled-in fallback.

  `fallback` may be a value or a zero-arity fun, so callers can pass
  `&default_model/0` without paying for it when an override is present.

  Returns `nil` only when all three are empty, which `ensure/2` then reports.
  """
  @spec resolve(keyword() | map(), atom() | String.t(), String.t() | (-> String.t()) | nil) ::
          String.t() | nil
  def resolve(opts, provider, fallback) do
    explicit(opts) || configured(provider) || presence(unwrap(fallback))
  end

  @doc """
  Gate a resolved model before it is written into a request body.

  Returns `{:ok, model}` for a usable name, or `{:error, message}` naming the
  provider and the environment variable that would fix it. Callers must not
  build a body from an `:error` — sending `nil` is what produced the 422 this
  module documents, and a request that cannot name its model has no correct
  behaviour left except to say so.
  """
  @spec ensure(term(), atom() | String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure(model, provider) do
    case presence(model) do
      nil ->
        {:error,
         "no model resolved for provider #{inspect(provider)} — refusing to send a request " <>
           "with a null model. Set #{env_var(provider)} (or " <>
           "config :optimal_system_agent, :#{provider}_model) to a model name. " <>
           "Got: #{inspect(model)}"}

      model ->
        {:ok, model}
    end
  end

  @doc "The environment variable that configures `provider`'s model."
  @spec env_var(atom() | String.t()) :: String.t()
  def env_var(provider), do: "#{provider}" |> String.upcase() |> Kernel.<>("_MODEL")

  defp explicit(opts) when is_list(opts), do: presence(Keyword.get(opts, :model))
  defp explicit(opts) when is_map(opts), do: presence(Map.get(opts, :model))
  defp explicit(_), do: nil

  defp unwrap(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> nil
  end

  defp unwrap(other), do: other

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp presence(_), do: nil
end
