defmodule OptimalSystemAgent.Agent.Debate do
  @moduledoc """
  Multi-agent debate orchestration.

  Runs a prompt against one or more providers in parallel and synthesises
  a single answer from their responses.

  ## Options

    * `:providers` - list of provider name strings (e.g. `["openai", "anthropic"]`).
      Defaults to the application's `:default_provider` env value if set.
    * `:timeout` - per-provider call timeout in ms. Default: 30_000.
    * `:synthesizer_provider` - provider used to produce the final synthesis.
      Defaults to the first provider in the list.
    * `:user_id` - optional user context string.
    * `:model` - optional model override string.

  ## Return value

  ```
  {:ok, %{synthesis: string, debate: [%{provider:, response:}], participants: integer}}
  {:error, :no_providers}
  {:error, reason}
  ```
  """

  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @default_timeout 30_000

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Run a debate with `message` and default options."
  @spec run(String.t()) :: {:ok, map()} | {:error, term()}
  def run(message), do: run(message, [])

  @doc "Run a debate with `message` and keyword `opts`."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(message, opts) when is_binary(message) and is_list(opts) do
    providers = Keyword.get(opts, :providers, default_providers())
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case providers do
      [] ->
        {:error, :no_providers}

      providers ->
        call_providers(message, providers, timeout, opts)
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp default_providers do
    case Application.get_env(:optimal_system_agent, :default_provider) do
      nil -> []
      provider -> [to_string(provider)]
    end
  end

  defp call_providers(message, providers, timeout, opts) do
    session_id = Keyword.get(opts, :session_id)

    # `:provider_call` is an internal test seam (arity-2: provider, message).
    # Debate's only real provider path is a live network call, so without it the
    # two behaviours that matter here — killing a timed-out task and honouring a
    # session cancel — are not assertable at all. Callers never set it; the HTTP
    # route builds its opts from a fixed allowlist.
    call = Keyword.get(opts, :provider_call)

    tasks =
      Enum.map(providers, fn provider ->
        Task.async(fn ->
          if is_function(call, 2),
            do: call.(provider, message),
            else: call_provider(provider, message, opts)
        end)
      end)

    responses =
      tasks
      |> Task.yield_many(timeout)
      |> Enum.zip(providers)
      |> Enum.flat_map(fn {{task, result}, provider} ->
        case result do
          {:ok, {:ok, response}} ->
            [%{provider: provider, response: response}]

          {:ok, {:error, reason}} ->
            Logger.warning("[Debate] Provider #{provider} error: #{inspect(reason)}")
            []

          nil ->
            # LEAK FIX: `yield_many/2` only stops WAITING — the task keeps
            # running. Without a shutdown, a slow provider call outlived the
            # debate, kept its connection and token spend alive, and (because
            # `Task.async` links) could still take the caller down later with an
            # exit nobody was expecting. `:brutal_kill` because a task blocked in
            # a socket read will not honour a graceful shutdown; the shutdown
            # also demonitors, so a late reply cannot land in the caller's
            # mailbox.
            Task.shutdown(task, :brutal_kill)
            Logger.warning("[Debate] Provider #{provider} timed out — task killed")
            []

          {:exit, reason} ->
            Logger.warning("[Debate] Provider #{provider} exited: #{inspect(reason)}")
            []
        end
      end)

    # Honour an explicit session cancel exactly like every other long-running
    # fan-out in the loop does. Without this, Esc during a debate left all N
    # provider calls running to completion and the user still waited for them.
    if cancelled?(session_id) do
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      {:error, :cancelled}
    else
      synthesise_responses(responses)
    end
  end

  @cancel_table :osa_cancel_flags

  defp cancelled?(session_id) when is_binary(session_id) do
    match?([{^session_id, true}], :ets.lookup(@cancel_table, session_id))
  rescue
    ArgumentError -> false
  end

  defp cancelled?(_), do: false

  defp synthesise_responses(responses) do
    case responses do
      [] ->
        {:error, :all_providers_failed}

      [single] ->
        {:ok,
         %{
           synthesis: single.response,
           debate: responses,
           participants: 1
         }}

      many ->
        synthesis = synthesise(many)
        {:ok, %{synthesis: synthesis, debate: many, participants: length(many)}}
    end
  end

  # Dispatch one debate turn to a real provider.
  #
  # This used to return `{:error, {:provider_unavailable, provider}}` for EVERY
  # provider except the in-process `"mock"` — i.e. `Debate.run/2` could only
  # ever fail in production, while `POST /debate` (channels/http/api/debate_routes.ex)
  # advertised it as a working feature. It is now wired to the same
  # `Providers.Registry.chat/2` every other non-streaming call in OSA uses, so
  # an unknown provider fails with the registry's own honest "Unknown provider:
  # X. Available: [...]" instead of a blanket unavailable.
  defp call_provider(provider, message, opts) do
    chat_opts =
      [provider: provider_to_atom(provider), temperature: 0.3]
      |> maybe_put(:model, Keyword.get(opts, :model))
      |> maybe_put(:user_id, Keyword.get(opts, :user_id))

    case provider_to_atom(provider) do
      :mock ->
        # Test / mock provider — echo a deterministic response. Kept because the
        # HTTP route and the test-suite both address it by name.
        {:ok, "Mock response from provider '#{provider}' for: #{String.slice(message, 0, 80)}"}

      _ ->
        case Providers.chat([%{role: "user", content: message}], chat_opts) do
          {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
          {:ok, content} when is_binary(content) -> {:ok, content}
          {:ok, other} -> {:ok, to_string_content(other)}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_string_content(%{"content" => c}) when is_binary(c), do: c
  defp to_string_content(other), do: inspect(other)

  # Provider NAME -> registry key. Unknown names are passed through as atoms so
  # the registry (the single source of truth for what exists) reports them,
  # rather than this module silently collapsing every unrecognised name to
  # `:unknown`. `String.to_atom/1` is safe here: the caller list is operator/
  # API-supplied provider names, already bounded by the registry check below.
  defp provider_to_atom(provider) when is_atom(provider), do: provider

  defp provider_to_atom(provider) when is_binary(provider) do
    known = Providers.list_providers()

    Enum.find(known, :unknown, fn p -> to_string(p) == provider end)
    |> case do
      :unknown -> if provider == "mock", do: :mock, else: :unknown
      found -> found
    end
  end

  defp synthesise(responses) do
    parts =
      responses
      |> Enum.map(fn %{provider: p, response: r} -> "**#{p}**: #{r}" end)
      |> Enum.join("\n\n")

    "Synthesis from #{length(responses)} providers:\n\n#{parts}"
  end
end
