defmodule OptimalSystemAgent.Channels.HTTP.API.RewindRoutes do
  @moduledoc """
  /rewind — list and restore rewind checkpoints (the /rewind UX).

  Forwarded from `/rewind` in the parent router.

  Effective routes:
    GET  /:session_id            — list recent rewind checkpoints (newest first)
    GET  /:session_id/:id        — full checkpoint entry (with messages)
    POST /restore                — restore code / conversation / both
                                   body: { session_id, checkpoint_id, scope }
                                   scope ∈ "code" | "conversation" | "both"
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop

  plug(:match)
  plug(:dispatch)

  # POST /restore — must be declared before the GET /:session_id/:id catch so
  # method routing stays unambiguous (different verbs, but keep it explicit).
  post "/restore" do
    with %{"session_id" => session_id, "checkpoint_id" => checkpoint_id} = body
         when is_binary(session_id) and is_binary(checkpoint_id) <- conn.body_params,
         {:ok, scope} <- parse_scope(body["scope"]) do
      case Checkpoint.restore_rewind(session_id, checkpoint_id, scope) do
        {:ok, result} ->
          # Apply the restored conversation to a live loop, if running.
          if result.messages != nil do
            Loop.rewind_conversation(session_id, result.messages, %{
              iteration: result.iteration,
              plan_mode: result.plan_mode,
              turn_count: result.turn_count
            })
          end

          json(conn, 200, %{
            id: result.id,
            scope: to_string(result.scope),
            code: result.code,
            conversation: result.conversation,
            message_count: result.messages && length(result.messages)
          })

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Checkpoint not found")

        {:error, reason} ->
          Logger.warning("[rewind] restore_failed: #{inspect(reason)}")
          json_error(conn, 400, "restore_failed", "Checkpoint could not be restored")
      end
    else
      {:error, :invalid_scope} ->
        json_error(conn, 400, "invalid_scope", "scope must be code, conversation, or both")

      _ ->
        json_error(conn, 400, "invalid_request", "session_id and checkpoint_id are required")
    end
  end

  get "/:session_id/:id" do
    case Checkpoint.get_rewind_checkpoint(session_id, id) do
      {:ok, entry} ->
        json(conn, 200, %{checkpoint: entry})

      {:error, _} ->
        json_error(conn, 404, "not_found", "Checkpoint not found")
    end
  end

  get "/:session_id" do
    conn = Plug.Conn.fetch_query_params(conn)
    limit = parse_positive_int(conn.query_params["limit"], 50)
    checkpoints = Checkpoint.list_rewind_checkpoints(session_id, limit)
    json(conn, 200, %{checkpoints: checkpoints, count: length(checkpoints)})
  end

  match _ do
    json_error(conn, 404, "not_found", "Rewind route not found")
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp parse_scope("code"), do: {:ok, :code}
  defp parse_scope("conversation"), do: {:ok, :conversation}
  defp parse_scope("both"), do: {:ok, :both}
  defp parse_scope(nil), do: {:ok, :both}
  defp parse_scope(_), do: {:error, :invalid_scope}
end
