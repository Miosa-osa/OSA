defmodule CanopyWeb.TemplateController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.Template
  import Ecto.Query

  def index(conn, params) do
    category = params["category"]

    query = from t in Template, order_by: [desc: t.is_builtin, asc: t.category, asc: t.name]
    query = if category, do: where(query, [t], t.category == ^category), else: query

    templates = Repo.all(query)
    json(conn, %{templates: Enum.map(templates, &serialize/1)})
  end

  def create(conn, params) do
    # User-created templates are never builtin
    attrs = Map.put(params, "is_builtin", false)
    changeset = Template.changeset(%Template{}, attrs)

    case Repo.insert(changeset) do
      {:ok, template} ->
        conn |> put_status(201) |> json(%{template: serialize(template)})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(changeset)})
    end
  end

  defp serialize(%Template{} = t) do
    %{
      id: t.id,
      name: t.name,
      description: t.description,
      category: t.category,
      agents: t.agents,
      skills: t.skills,
      schedules: t.schedules,
      is_builtin: t.is_builtin,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
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
