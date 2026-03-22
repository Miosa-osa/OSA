defmodule CanopyWeb.CommentController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.Comment
  import Ecto.Query

  def index(conn, %{"issue_id" => issue_id}) do
    comments =
      Repo.all(
        from c in Comment,
          where: c.issue_id == ^issue_id,
          order_by: [asc: c.inserted_at]
      )

    json(conn, %{comments: Enum.map(comments, &serialize/1)})
  end

  def create(conn, %{"issue_id" => issue_id} = params) do
    attrs = Map.merge(params, %{"issue_id" => issue_id})

    changeset = Comment.changeset(%Comment{}, attrs)

    case Repo.insert(changeset) do
      {:ok, comment} ->
        Canopy.EventBus.broadcast(
          "issue:#{issue_id}",
          %{event: "issue.commented", issue_id: issue_id, comment_id: comment.id}
        )

        conn |> put_status(201) |> json(%{comment: serialize(comment)})

      {:error, cs} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(cs)})
    end
  end

  # --- Private helpers ---

  defp serialize(%Comment{} = c) do
    %{
      id: c.id,
      issue_id: c.issue_id,
      author_type: c.author_type,
      author_id: c.author_id,
      body: c.body,
      inserted_at: c.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
