defmodule OptimalSystemAgent.Channels.HTTP.API.IssueRoutes do
  @moduledoc """
  Issue tracker routes for the OSA HTTP API.

  Forwarded prefix: /issues

  Effective endpoints:
    GET    /issues           → List all issues
    POST   /issues           → Create a new issue
    GET    /issues/:id       → Get issue by ID
    PATCH  /issues/:id       → Update issue fields
    DELETE /issues/:id       → Remove an issue
    POST   /issues/:id/comments → Add a comment to an issue

  Storage: ~/.osa/issues.json
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — list all issues ─────────────────────────────────────────

  get "/" do
    issues = read_data()
    json(conn, 200, %{issues: issues, count: length(issues)})
  end

  # ── POST / — create an issue ────────────────────────────────────────

  post "/" do
    try do
      case conn.body_params do
        %{"title" => title} when is_binary(title) and title != "" ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          issue = %{
            "id" => generate_id("iss"),
            "title" => title,
            "description" => Map.get(conn.body_params, "description", ""),
            "status" => "open",
            "priority" => Map.get(conn.body_params, "priority", "medium"),
            "labels" => Map.get(conn.body_params, "labels", []),
            "comments" => [],
            "created_at" => now,
            "updated_at" => now
          }

          issues = read_data()
          write_data([issue | issues])

          Logger.info("[IssueRoutes] Created issue #{issue["id"]}: #{title}")
          json(conn, 201, issue)

        _ ->
          json_error(conn, 400, "invalid_request", "Missing required field: title")
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to create issue")
    end
  end

  # ── GET /:id — get issue by ID ──────────────────────────────────────

  get "/:id" do
    id = conn.params["id"]

    case find_by_id(read_data(), id) do
      nil -> json_error(conn, 404, "not_found", "Issue not found")
      issue -> json(conn, 200, issue)
    end
  end

  # ── PATCH /:id — update issue ───────────────────────────────────────

  patch "/:id" do
    id = conn.params["id"]

    try do
      issues = read_data()

      case find_by_id(issues, id) do
        nil ->
          json_error(conn, 404, "not_found", "Issue not found")

        existing ->
          allowed = ~w(title description status priority labels)
          updates = Map.take(conn.body_params, allowed)

          if map_size(updates) == 0 do
            json_error(conn, 400, "invalid_request", "No updatable fields provided")
          else
            updated =
              Map.merge(existing, updates)
              |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

            new_issues = Enum.map(issues, fn i -> if i["id"] == id, do: updated, else: i end)
            write_data(new_issues)

            Logger.info("[IssueRoutes] Updated issue #{id}")
            json(conn, 200, updated)
          end
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to update issue")
    end
  end

  # ── DELETE /:id — remove issue ──────────────────────────────────────

  delete "/:id" do
    id = conn.params["id"]

    try do
      issues = read_data()

      case find_by_id(issues, id) do
        nil ->
          json_error(conn, 404, "not_found", "Issue not found")

        _ ->
          new_issues = Enum.reject(issues, fn i -> i["id"] == id end)
          write_data(new_issues)

          Logger.info("[IssueRoutes] Deleted issue #{id}")
          json(conn, 200, %{deleted: true, id: id})
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to delete issue")
    end
  end

  # ── POST /:id/comments — add comment ────────────────────────────────

  post "/:id/comments" do
    id = conn.params["id"]

    try do
      case conn.body_params do
        %{"text" => text} when is_binary(text) and text != "" ->
          issues = read_data()

          case find_by_id(issues, id) do
            nil ->
              json_error(conn, 404, "not_found", "Issue not found")

            existing ->
              now = DateTime.utc_now() |> DateTime.to_iso8601()

              comment = %{
                "id" => generate_id("cmt"),
                "text" => text,
                "author" => Map.get(conn.body_params, "author", "user"),
                "created_at" => now
              }

              updated =
                existing
                |> Map.update("comments", [comment], fn existing_comments ->
                  existing_comments ++ [comment]
                end)
                |> Map.put("updated_at", now)

              new_issues = Enum.map(issues, fn i -> if i["id"] == id, do: updated, else: i end)
              write_data(new_issues)

              Logger.info("[IssueRoutes] Added comment #{comment["id"]} to issue #{id}")
              json(conn, 201, comment)
          end

        _ ->
          json_error(conn, 400, "invalid_request", "Missing required field: text")
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to add comment")
    end
  end

  # ── catch-all ────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Issue endpoint not found")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp data_path do
    Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
    |> Path.expand()
    |> Path.join("issues.json")
  end

  defp read_data do
    path = data_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_list(parsed) do
      parsed
    else
      _ -> []
    end
  rescue
    e ->
      Logger.warning("[IssueRoutes] Failed to read issues: #{Exception.message(e)}")
      []
  end

  defp write_data(issues) do
    path = data_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(issues, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.warning("[IssueRoutes] Failed to encode issues: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[IssueRoutes] Failed to write issues: #{Exception.message(e)}")
  end

  defp find_by_id(issues, id) do
    Enum.find(issues, fn i -> i["id"] == id end)
  end

  defp generate_id(prefix) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    "#{prefix}_#{suffix}"
  end
end
