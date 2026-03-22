defmodule CanopyWeb.Plugs.Audit do
  @moduledoc """
  Audit trail plug — logs all mutating API actions to the audit_events table.

  Captures: action (HTTP method + path), actor (user_id or "anonymous"),
  actor_type (user/system), entity_type/entity_id (from path params),
  response status.

  Immutable — audit_events table has no UPDATE or DELETE.
  """
  import Plug.Conn
  require Logger

  alias Canopy.Repo
  alias Canopy.Schemas.AuditEvent

  @mutating_methods ~w(POST PUT PATCH DELETE)

  def init(opts), do: opts

  def call(%{method: method} = conn, _opts) when method in @mutating_methods do
    register_before_send(conn, fn conn ->
      # Only log successful mutations (2xx/3xx)
      if conn.status in 200..399 do
        log_audit_event(conn)
      end

      conn
    end)
  end

  def call(conn, _opts), do: conn

  defp log_audit_event(conn) do
    actor_id =
      case conn.assigns[:current_user] do
        %{id: id} -> to_string(id)
        _ -> "anonymous"
      end

    {entity_type, entity_id} = extract_entity(conn)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %AuditEvent{
      action: "#{conn.method} #{conn.request_path}",
      actor: actor_id,
      actor_type: if(actor_id == "anonymous", do: "system", else: "user"),
      entity_type: entity_type,
      entity_id: parse_uuid(entity_id),
      details: %{
        "status" => conn.status,
        "params" => sanitize_params(conn.params)
      },
      inserted_at: now
    }
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Audit] Failed to log event: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[Audit] Error logging audit event: #{Exception.message(e)}")
  end

  defp extract_entity(conn) do
    case conn.path_info do
      ["api", "v1", resource | rest] ->
        entity_type = singularize(resource)

        entity_id =
          case rest do
            [id | _] when byte_size(id) == 36 -> id
            _ -> nil
          end

        {entity_type, entity_id}

      _ ->
        {nil, nil}
    end
  end

  defp singularize("workspaces"), do: "workspace"
  defp singularize("agents"), do: "agent"
  defp singularize("sessions"), do: "session"
  defp singularize("schedules"), do: "schedule"
  defp singularize("issues"), do: "issue"
  defp singularize("goals"), do: "goal"
  defp singularize("projects"), do: "project"
  defp singularize("skills"), do: "skill"
  defp singularize("webhooks"), do: "webhook"
  defp singularize("budgets"), do: "budget"
  defp singularize("users"), do: "user"
  defp singularize("gateways"), do: "gateway"
  defp singularize("templates"), do: "template"
  defp singularize("memory"), do: "memory_entry"
  defp singularize(other), do: other

  defp parse_uuid(nil), do: nil

  defp parse_uuid(str) when is_binary(str) do
    case Ecto.UUID.cast(str) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  @sensitive_keys ~w(password password_hash token secret api_key)

  defp sanitize_params(params) when is_map(params) do
    params
    |> Map.drop(@sensitive_keys)
    |> Map.new(fn
      {k, _v} when k in @sensitive_keys -> {k, "[REDACTED]"}
      {k, v} when is_map(v) -> {k, sanitize_params(v)}
      pair -> pair
    end)
    |> Map.take(~w(id name title status priority slug scope_type scope_id))
  end

  defp sanitize_params(_), do: %{}
end
