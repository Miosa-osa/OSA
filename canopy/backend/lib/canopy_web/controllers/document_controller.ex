defmodule CanopyWeb.DocumentController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.Workspace
  import Ecto.Query

  def index(conn, params) do
    with {:ok, ref_dir} <- resolve_reference_dir(params) do
      files =
        case File.ls(ref_dir) do
          {:ok, names} ->
            names
            |> Enum.filter(&(not String.starts_with?(&1, ".")))
            |> Enum.map(fn name ->
              path = Path.join(ref_dir, name)
              stat = File.stat!(path)

              %{
                name: name,
                path: name,
                size: stat.size,
                type: if(stat.type == :directory, do: "directory", else: "file"),
                modified_at: stat.mtime
              }
            end)
            |> Enum.sort_by(& &1.name)

          {:error, _} ->
            []
        end

      json(conn, %{files: files, directory: ref_dir})
    else
      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: reason})
    end
  end

  def show(conn, %{"path" => path_parts} = params) do
    with {:ok, ref_dir} <- resolve_reference_dir(params) do
      file_path = Path.join([ref_dir | path_parts])

      case File.read(file_path) do
        {:ok, content} ->
          json(conn, %{
            path: Path.join(path_parts),
            content: content,
            size: byte_size(content)
          })

        {:error, :enoent} ->
          conn |> put_status(404) |> json(%{error: "not_found"})

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: reason})
    end
  end

  def create(conn, %{"path" => relative_path, "content" => content} = params) do
    with {:ok, ref_dir} <- resolve_reference_dir(params) do
      file_path = Path.join(ref_dir, relative_path)
      dir = Path.dirname(file_path)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(file_path, content) do
        conn |> put_status(201) |> json(%{ok: true, path: relative_path})
      else
        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: reason})
    end
  end

  def update(conn, %{"path" => path_parts, "content" => content} = params) do
    with {:ok, ref_dir} <- resolve_reference_dir(params) do
      file_path = Path.join([ref_dir | path_parts])
      dir = Path.dirname(file_path)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(file_path, content) do
        json(conn, %{ok: true, path: Path.join(path_parts)})
      else
        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: reason})
    end
  end

  def delete(conn, %{"path" => path_parts} = params) do
    with {:ok, ref_dir} <- resolve_reference_dir(params) do
      file_path = Path.join([ref_dir | path_parts])

      case File.rm(file_path) do
        :ok ->
          json(conn, %{ok: true})

        {:error, :enoent} ->
          conn |> put_status(404) |> json(%{error: "not_found"})

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: reason})
    end
  end

  # --- Private helpers ---

  defp resolve_reference_dir(%{"workspace_id" => workspace_id}) when is_binary(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      nil ->
        {:error, "workspace_not_found"}

      workspace ->
        dir = Path.join([workspace.path, ".canopy", "reference"])
        File.mkdir_p!(dir)
        {:ok, dir}
    end
  end

  defp resolve_reference_dir(_params) do
    # Fall back to the active workspace (status = "active")
    case Repo.one(from w in Workspace, where: w.status == "active", limit: 1) do
      nil ->
        {:error, "no_active_workspace"}

      workspace ->
        dir = Path.join([workspace.path, ".canopy", "reference"])
        File.mkdir_p!(dir)
        {:ok, dir}
    end
  end
end
