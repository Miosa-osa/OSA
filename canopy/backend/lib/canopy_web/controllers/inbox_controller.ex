defmodule CanopyWeb.InboxController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.ActivityEvent
  import Ecto.Query

  # Inbox messages are ActivityEvents with level="notification".
  # "Read" state is tracked in metadata["read"] = true.

  def index(conn, params) do
    workspace_id = params["workspace_id"]
    unread_only = params["unread"] == "true"
    limit = min(String.to_integer(params["limit"] || "50"), 200)
    offset = String.to_integer(params["offset"] || "0")

    query =
      from e in ActivityEvent,
        where: e.level == "notification",
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        offset: ^offset

    query = if workspace_id, do: where(query, [e], e.workspace_id == ^workspace_id), else: query

    query =
      if unread_only do
        where(
          query,
          [e],
          fragment("COALESCE((?->>'read')::boolean, false) = false", e.metadata)
        )
      else
        query
      end

    messages = Repo.all(query)
    total = Repo.aggregate(from(e in ActivityEvent, where: e.level == "notification"), :count)

    unread_count =
      Repo.aggregate(
        from(e in ActivityEvent,
          where:
            e.level == "notification" and
              fragment("COALESCE((?->>'read')::boolean, false) = false", e.metadata)
        ),
        :count
      )

    json(conn, %{
      messages: Enum.map(messages, &serialize/1),
      total: total,
      unread_count: unread_count
    })
  end

  def read(conn, %{"id" => id}) do
    case Repo.get(ActivityEvent, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      event ->
        updated_metadata = Map.put(event.metadata || %{}, "read", true)

        {:ok, updated} =
          event
          |> Ecto.Changeset.change(metadata: updated_metadata)
          |> Repo.update()

        json(conn, %{message: serialize(updated)})
    end
  end

  def read_all(conn, params) do
    workspace_id = params["workspace_id"]

    query = from e in ActivityEvent, where: e.level == "notification"
    query = if workspace_id, do: where(query, [e], e.workspace_id == ^workspace_id), else: query

    # Fetch and individually mark read — avoids raw SQL fragment in update_all set clause
    events = Repo.all(query)

    count =
      Enum.reduce(events, 0, fn event, acc ->
        updated_metadata = Map.put(event.metadata || %{}, "read", true)

        event
        |> Ecto.Changeset.change(metadata: updated_metadata)
        |> Repo.update!()

        acc + 1
      end)

    json(conn, %{ok: true, updated: count})
  end

  def perform_action(conn, %{"id" => id} = params) do
    action_type = params["action"] || "acknowledge"

    case Repo.get(ActivityEvent, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      event ->
        updated_metadata =
          (event.metadata || %{})
          |> Map.put("read", true)
          |> Map.put("action", action_type)
          |> Map.put("actioned_at", DateTime.to_iso8601(DateTime.utc_now()))

        {:ok, updated} =
          event
          |> Ecto.Changeset.change(metadata: updated_metadata)
          |> Repo.update()

        Canopy.EventBus.broadcast(
          Canopy.EventBus.activity_topic(),
          %{event: "inbox.actioned", message_id: id, action: action_type}
        )

        json(conn, %{ok: true, message: serialize(updated), action: action_type})
    end
  end

  defp serialize(%ActivityEvent{} = e) do
    %{
      id: e.id,
      event_type: e.event_type,
      message: e.message,
      metadata: e.metadata,
      level: e.level,
      workspace_id: e.workspace_id,
      agent_id: e.agent_id,
      inserted_at: e.inserted_at,
      read: get_in(e.metadata || %{}, ["read"]) == true
    }
  end
end
