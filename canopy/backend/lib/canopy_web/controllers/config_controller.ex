defmodule CanopyWeb.ConfigController do
  use CanopyWeb, :controller

  # Reads/writes runtime configuration from Application env.
  # Non-persistent — survives only for the lifetime of the node.

  @readable_keys ~w(
    default_model
    max_concurrent_agents
    session_timeout_minutes
    log_level
    telemetry_enabled
    budget_enforcement
    activity_retention_days
  )a

  def show(conn, _params) do
    config =
      @readable_keys
      |> Enum.map(fn key ->
        val = Application.get_env(:canopy, key, default_for(key))
        {key, val}
      end)
      |> Map.new()

    json(conn, %{config: config})
  end

  def update(conn, params) do
    allowed_updates =
      params
      |> Map.take(Enum.map(@readable_keys, &to_string/1))
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)

    if Enum.empty?(allowed_updates) do
      conn
      |> put_status(400)
      |> json(%{error: "no_valid_keys", allowed_keys: @readable_keys})
    else
      Enum.each(allowed_updates, fn {key, value} ->
        Application.put_env(:canopy, key, coerce(key, value))
      end)

      updated_config =
        @readable_keys
        |> Enum.map(fn key ->
          {key, Application.get_env(:canopy, key, default_for(key))}
        end)
        |> Map.new()

      json(conn, %{config: updated_config, updated_keys: Enum.map(allowed_updates, &elem(&1, 0))})
    end
  end

  defp default_for(:default_model), do: "claude-3-5-sonnet-20241022"
  defp default_for(:max_concurrent_agents), do: 10
  defp default_for(:session_timeout_minutes), do: 60
  defp default_for(:log_level), do: "info"
  defp default_for(:telemetry_enabled), do: true
  defp default_for(:budget_enforcement), do: true
  defp default_for(:activity_retention_days), do: 30
  defp default_for(_), do: nil

  defp coerce(:max_concurrent_agents, v) when is_binary(v), do: String.to_integer(v)
  defp coerce(:session_timeout_minutes, v) when is_binary(v), do: String.to_integer(v)
  defp coerce(:activity_retention_days, v) when is_binary(v), do: String.to_integer(v)
  defp coerce(:telemetry_enabled, "true"), do: true
  defp coerce(:telemetry_enabled, "false"), do: false
  defp coerce(:budget_enforcement, "true"), do: true
  defp coerce(:budget_enforcement, "false"), do: false
  defp coerce(_key, value), do: value
end
