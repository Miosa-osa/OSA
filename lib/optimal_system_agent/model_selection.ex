defmodule OptimalSystemAgent.ModelSelection do
  @moduledoc """
  Shared persistence for the "sticky" default provider/model.

  A model switch that only mutates the live `Loop` struct is forgotten the
  moment a new session starts or the daemon restarts - the next boot falls back
  to the compiled default (glm-5.2:cloud). `persist/2` is the single place that
  makes a selection survive: it sets the runtime app-env keys the request/boot
  path reads AND merges the choice into `~/.osa/config.json` so it outlives the
  process.

  Callers (the `/models` HTTP routes and the session hot-swap route) delegate
  here so the write mechanism lives in exactly one place.
  """

  require Logger

  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.System.JsonStore

  @doc """
  Persist `provider`/`model` as the new default.

  Sets `:default_provider` (atom), `:default_model` and the scoped
  `:"\#{provider}_model"` app-env keys, then merges the pair into
  `~/.osa/config.json`. Both arguments are strings (as they arrive on the wire).
  A blank provider or model is a no-op - there is nothing meaningful to persist.
  """
  @spec persist(String.t(), String.t()) :: :ok
  def persist(provider, model)
      when is_binary(provider) and is_binary(model) and provider != "" and model != "" do
    Application.put_env(:optimal_system_agent, :default_provider, to_provider_atom(provider))
    Application.put_env(:optimal_system_agent, :default_model, model)

    # Providers read the scoped key :"#{provider}_model" (e.g. :openai_model,
    # :anthropic_model, :ollama_model), NOT :default_model - so set the scoped
    # key or the switch is a silent no-op for every non-ollama provider.
    Application.put_env(:optimal_system_agent, :"#{provider}_model", model)

    persist_to_config(provider, model)
    :ok
  rescue
    e ->
      Logger.warning("[Models] Config persist error: #{Exception.message(e)}")
      :ok
  end

  def persist(_provider, _model), do: :ok

  # Providers are registered atoms, so the atom already exists; fall back to a
  # dynamic atom only if a caller somehow passes an unregistered name.
  defp to_provider_atom(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> String.to_atom(provider)
  end

  # Persist provider/model selection to ~/.osa/config.json so it survives restarts.
  # Reads existing config (if any), merges the two keys, and writes back atomically.
  defp persist_to_config(provider, model) do
    config_path =
      Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
      |> Path.expand()
      |> Path.join("config.json")

    # An unreadable config used to degrade to `%{}` here, so a model switch
    # rewrote ~/.osa/config.json containing only "provider" and "model" and
    # discarded everything else in it. Refuse instead - the merge is only
    # meaningful if the read succeeded.
    case JsonStore.read_map_for_write(config_path) do
      {:error, :corrupt} ->
        Logger.error("[Models] #{JsonStore.corrupt_message("model selection", config_path)}")

      {:ok, existing} ->
        updated = Map.merge(existing, %{"provider" => provider, "model" => model})

        case Jason.encode(updated, pretty: true) do
          {:ok, json} ->
            File.mkdir_p!(Path.dirname(config_path))
            AtomicFile.write!(config_path, json)

          {:error, reason} ->
            Logger.warning("[Models] Failed to persist model selection: #{inspect(reason)}")
        end
    end
  end
end
