defmodule OptimalSystemAgent.Providers.MiosaGateway do
  @moduledoc """
  MIOSA AI Gateway platform mode.

  A MIOSA sandbox run hands OSA a run-scoped gateway endpoint instead of a
  vendor key:

    * `MIOSA_AI_GATEWAY_URL` - OpenAI-compatible base URL; requests go to
      `<url>/chat/completions`.
    * `MIOSA_AI_GATEWAY_KEY` - run-scoped bearer key the gateway accepts.

  The gateway holds the vendor credentials and routes by model name, so any
  gateway model (Ollama Cloud models included) runs with no key of OSA's own.

  `config/runtime.exs` turns these into the `:openai` provider's URL and key
  at boot (it inlines the same parsing as `from_env/1`, because runtime config
  must not depend on application modules). This module answers the request
  time questions:

    * `active?/0` - is this process running in platform mode? A
      platform-managed machine has nothing for the setup wizard to configure.
    * `routes_openai?/0` - does the `:openai` provider currently dial the
      gateway? The gateway serves Chat Completions only, so OpenAI's
      Responses-API transport must not be chosen for it.
  """

  @url_env "MIOSA_AI_GATEWAY_URL"
  @key_env "MIOSA_AI_GATEWAY_KEY"

  @type t :: %{url: String.t(), key: String.t()}

  @doc "Name of the gateway base URL environment variable."
  @spec url_env() :: String.t()
  def url_env, do: @url_env

  @doc "Name of the gateway key environment variable."
  @spec key_env() :: String.t()
  def key_env, do: @key_env

  @doc """
  Read the gateway configuration from the environment.

  Returns `{:ok, %{url: url, key: key}}` only when BOTH variables are present
  and non-blank; the URL loses any trailing slash. Anything else is `:none`,
  which leaves OSA's existing provider behavior untouched.

  `get_env` is injectable so callers and tests never have to mutate the real
  process environment.
  """
  @spec from_env((String.t() -> String.t() | nil)) :: {:ok, t()} | :none
  def from_env(get_env \\ &System.get_env/1) when is_function(get_env, 1) do
    with url when is_binary(url) <- get_env.(@url_env),
         key when is_binary(key) <- get_env.(@key_env),
         url = url |> String.trim() |> String.trim_trailing("/"),
         key = String.trim(key),
         true <- url != "" and key != "" do
      {:ok, %{url: url, key: key}}
    else
      _ -> :none
    end
  end

  @doc "True when the process environment carries a complete gateway configuration."
  @spec active?((String.t() -> String.t() | nil)) :: boolean()
  def active?(get_env \\ &System.get_env/1), do: from_env(get_env) != :none

  @doc """
  True when the `:openai` provider's configured base URL is the gateway that
  `config/runtime.exs` recorded at boot.
  """
  @spec routes_openai?() :: boolean()
  def routes_openai? do
    with gateway when is_binary(gateway) and gateway != "" <-
           Application.get_env(:optimal_system_agent, :miosa_ai_gateway_url),
         url when is_binary(url) <- Application.get_env(:optimal_system_agent, :openai_url) do
      url |> String.trim() |> String.trim_trailing("/") == gateway
    else
      _ -> false
    end
  end
end
