defmodule CanopyWeb.FallbackController do
  use CanopyWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn |> put_status(404) |> json(%{error: "not_found"})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn |> put_status(422) |> json(%{error: "validation_failed", details: errors})
  end

  def call(conn, {:error, :unauthorized}) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end
end
