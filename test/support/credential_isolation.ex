defmodule OptimalSystemAgent.Test.CredentialIsolation do
  @moduledoc """
  Clears every provider credential source `Providers.provider_configured?/1`
  reads for the providers the advisor can auto-resolve to, for the duration
  of one test, and restores them afterwards.

  Advisor auto-resolution asks "is Anthropic / the Claude subscription /
  OpenAI / Codex reachable?". The answer comes from app env keys AND live OS
  environment variables. Other test files set those variables, and one that
  forgets to restore them makes an "unconfigured" advisor test resolve a real
  provider, so these tests must not depend on the rest of the suite being
  tidy.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @providers [:anthropic, :claude_cli, :openai, :openai_codex]

  @doc "Call from a `setup` block. Returns `:ok`."
  @spec isolate() :: :ok
  def isolate do
    app_keys = Enum.map(@providers, &:"#{&1}_api_key")

    env_vars =
      Enum.map(@providers, fn p ->
        p |> Atom.to_string() |> String.upcase() |> Kernel.<>("_API_KEY")
      end)

    prev_app = Enum.map(app_keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})
    prev_env = Enum.map(env_vars, &{&1, System.get_env(&1)})

    Enum.each(app_keys, &Application.delete_env(:optimal_system_agent, &1))
    Enum.each(env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(prev_app, fn
        {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
        {k, :error} -> Application.delete_env(:optimal_system_agent, k)
      end)

      Enum.each(prev_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end
end
