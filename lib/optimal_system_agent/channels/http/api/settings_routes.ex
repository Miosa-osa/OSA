defmodule OptimalSystemAgent.Channels.HTTP.API.SettingsRoutes do
  @moduledoc """
  Settings routes for the OSA HTTP API.

  Forwarded prefix: /settings

  Effective routes:
    GET  /settings  → Return current settings (file + runtime merge)
    PATCH /settings → Update settings (merge, persist, apply runtime changes)
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — read current settings ──────────────────────────────────

  get "/" do
    settings = build_settings(read_config())
    json(conn, 200, settings)
  end

  # ── PATCH / — update settings ───────────────────────────────────────

  patch "/" do
    try do
      params = conn.body_params

      if not is_map(params) or params == %{} do
        json_error(conn, 400, "invalid_request", "Request body must be a non-empty JSON object")
      else
        existing = read_config()
        updated = Map.merge(existing, sanitize_params(params))

        apply_runtime_changes(existing, updated)

        write_config(updated)

        settings = build_settings(updated)
        json(conn, 200, settings)
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to update settings")
    end
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Settings endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp config_path do
    Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
    |> Path.expand()
    |> Path.join("config.json")
  end

  defp read_config do
    path = config_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_map(parsed) do
      parsed
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp write_config(config) do
    path = config_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.warning("[Settings] Failed to encode config: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[Settings] Config write error: #{Exception.message(e)}")
  end

  defp build_settings(file_config) do
    provider =
      Application.get_env(:optimal_system_agent, :default_provider, :ollama)
      |> to_string()

    model =
      (Application.get_env(:optimal_system_agent, :default_model) ||
         Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest"))
      |> to_string()

    working_dir = Map.get(file_config, "working_dir") || safe_cwd()
    agent_name = Map.get(file_config, "agent_name") || "OSA Agent"
    yolo_mode = Map.get(file_config, "yolo_mode", false)
    log_level = Logger.level() |> to_string()

    context_window =
      try do
        OptimalSystemAgent.Providers.Registry.context_window(model)
      rescue
        _ -> nil
      end

    %{
      provider: Map.get(file_config, "provider", provider),
      model: Map.get(file_config, "model", model),
      working_dir: working_dir,
      agent_name: agent_name,
      yolo_mode: yolo_mode,
      log_level: log_level,
      context_window: context_window
    }
  end

  # Only accept known, safe keys from the request body.
  defp sanitize_params(params) do
    allowed = ~w(provider model working_dir agent_name yolo_mode log_level)

    Map.take(params, allowed)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, k, v)
    end)
  end

  defp apply_runtime_changes(existing, updated) do
    apply_provider_model(existing, updated)
    apply_log_level(existing, updated)
  end

  defp apply_provider_model(existing, updated) do
    provider_changed = Map.get(existing, "provider") != Map.get(updated, "provider")
    model_changed = Map.get(existing, "model") != Map.get(updated, "model")

    if provider_changed or model_changed do
      new_provider = Map.get(updated, "provider")
      new_model = Map.get(updated, "model")

      if is_binary(new_provider) and new_provider != "" do
        provider_atom =
          try do
            String.to_existing_atom(new_provider)
          rescue
            _ -> String.to_atom(new_provider)
          end

        Application.put_env(:optimal_system_agent, :default_provider, provider_atom)
        Logger.info("[Settings] Provider set to #{new_provider}")
      end

      if is_binary(new_model) and new_model != "" do
        Application.put_env(:optimal_system_agent, :default_model, new_model)
        Logger.info("[Settings] Model set to #{new_model}")
      end
    end
  end

  defp apply_log_level(existing, updated) do
    old_level = Map.get(existing, "log_level")
    new_level = Map.get(updated, "log_level")

    if is_binary(new_level) and new_level != "" and new_level != old_level do
      try do
        level_atom = String.to_existing_atom(new_level)
        Logger.configure(level: level_atom)
        Logger.info("[Settings] Log level set to #{new_level}")
      rescue
        _ -> Logger.warning("[Settings] Ignoring unknown log_level: #{new_level}")
      end
    end
  end

  defp safe_cwd do
    File.cwd!()
  rescue
    _ -> "/"
  end
end
