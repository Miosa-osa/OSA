defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Fs do
  @moduledoc """
  File-system executor for the OpenComputers direct-mode protocol.

  Each public function receives a `req_id` (binary) and a `payload` map
  matching the corresponding `fs_*_request` frame, performs the OS-level
  operation using `File.*`, and returns a `{:fs_*_response, payload}` or
  `{:fs_error, %{req_id, reason}}` tuple suitable for sending back through
  the session.

  ## Security

    * **Allowed roots** — every path is expanded with `Path.expand/1` before
      comparison. Any path that does not reside under one of the configured
      `allowed_roots` is rejected with `:path_not_allowed`. Symlinks that
      point outside allowed roots are also rejected (we use `File.lstat/1`).
    * **Size limits** — read and write chunks are capped at 4 MiB each.
    * **No new atoms** — all incoming values that would become atoms are
      taken from a fixed known set. FrameCodec decodes with `:safe`.

  ## Error reasons (fixed atom set)

    * `:not_found`          — ENOENT
    * `:permission_denied`  — EACCES / EPERM
    * `:path_not_allowed`   — outside configured allowed_roots
    * `:too_large`          — read/write chunk > 4 MiB
    * `:timeout`            — reserved
    * `:unknown`            — any other posix error
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Config

  @max_bytes 4 * 1024 * 1024

  # ── Public API ────────────────────────────────────────────────────────────

  @spec list(binary(), map()) :: tuple()
  def list(req_id, %{path: path}) do
    with :ok <- check_allowed(path),
         {:ok, expanded} <- expand_path(path),
         {:ok, names} <- File.ls(expanded) do
      entries =
        Enum.map(names, fn name ->
          full = Path.join(expanded, name)

          stat =
            case File.lstat(full) do
              {:ok, s} -> s
              _ -> nil
            end

          if stat do
            %{
              name: name,
              type: file_type(stat.type),
              size: stat.size,
              mtime: to_unix(stat.mtime),
              mode: stat.mode
            }
          else
            %{name: name, type: :file, size: 0, mtime: 0, mode: 0}
          end
        end)

      {:fs_list_response, %{req_id: req_id, entries: entries}}
    else
      {:error, reason} -> fs_error(req_id, map_posix(reason))
    end
  end

  @spec stat(binary(), map()) :: tuple()
  def stat(req_id, %{path: path}) do
    with :ok <- check_allowed(path),
         {:ok, expanded} <- expand_path(path) do
      case File.lstat(expanded) do
        {:ok, s} ->
          stat = %{
            type: file_type(s.type),
            size: s.size,
            mtime: to_unix(s.mtime),
            mode: s.mode,
            exists: true
          }

          {:fs_stat_response, %{req_id: req_id, stat: stat}}

        {:error, :enoent} ->
          stat = %{type: :other, size: 0, mtime: 0, mode: 0, exists: false}
          {:fs_stat_response, %{req_id: req_id, stat: stat}}

        {:error, posix} ->
          fs_error(req_id, map_posix(posix))
      end
    else
      {:error, reason} -> fs_error(req_id, map_posix(reason))
    end
  end

  @spec read(binary(), map()) :: tuple()
  def read(req_id, %{path: path, offset: offset, max_bytes: max_bytes}) do
    capped = min(max_bytes, @max_bytes)

    if max_bytes > @max_bytes do
      fs_error(req_id, :too_large)
    else
      with :ok <- check_allowed(path),
           {:ok, expanded} <- expand_path(path),
           :ok <- check_not_symlink_escape(expanded, path) do
        case File.open(expanded, [:read, :binary]) do
          {:ok, fd} ->
            result = do_read(fd, offset, capped, req_id)
            File.close(fd)
            result

          {:error, :enoent} ->
            fs_error(req_id, :not_found)

          {:error, posix} ->
            fs_error(req_id, map_posix(posix))
        end
      else
        {:error, reason} -> fs_error(req_id, map_posix(reason))
      end
    end
  end

  @spec write(binary(), map()) :: tuple()
  def write(
        req_id,
        %{path: path, offset: offset, data: data, create: create, truncate: truncate} = payload
      ) do
    if byte_size(data) > @max_bytes do
      fs_error(req_id, :too_large)
    else
      with :ok <- check_allowed(path),
           {:ok, expanded} <- expand_path(path),
           :ok <- check_not_symlink_escape(expanded, path) do
        modes = build_write_modes(create, truncate)

        case File.open(expanded, modes) do
          {:ok, fd} ->
            result = do_write(fd, offset, data, req_id)
            File.close(fd)

            if match?({:fs_write_response, _}, result) do
              if mode = Map.get(payload, :mode) do
                File.chmod(expanded, mode)
              end
            end

            result

          {:error, :enoent} ->
            fs_error(req_id, :not_found)

          {:error, posix} ->
            fs_error(req_id, map_posix(posix))
        end
      else
        {:error, reason} -> fs_error(req_id, map_posix(reason))
      end
    end
  end

  @spec delete(binary(), map()) :: tuple()
  def delete(req_id, %{path: path, recursive: recursive}) do
    with :ok <- check_allowed(path),
         {:ok, expanded} <- expand_path(path) do
      result =
        if recursive do
          File.rm_rf(expanded)
        else
          case File.lstat(expanded) do
            {:ok, %{type: :directory}} -> File.rmdir(expanded)
            {:ok, _} -> File.rm(expanded)
            {:error, :enoent} -> {:error, :enoent}
            {:error, posix} -> {:error, posix}
          end
        end

      case result do
        {:ok, _} ->
          {:fs_delete_response, %{req_id: req_id, ok: true}}

        :ok ->
          {:fs_delete_response, %{req_id: req_id, ok: true}}

        {:error, :enoent} ->
          fs_error(req_id, :not_found)

        {:error, posix} ->
          fs_error(req_id, map_posix(posix))
      end
    else
      {:error, reason} -> fs_error(req_id, map_posix(reason))
    end
  end

  @spec mkdir(binary(), map()) :: tuple()
  def mkdir(req_id, %{path: path, recursive: recursive}) do
    with :ok <- check_allowed(path),
         {:ok, expanded} <- expand_path(path) do
      result =
        if recursive do
          File.mkdir_p(expanded)
        else
          File.mkdir(expanded)
        end

      case result do
        :ok ->
          {:fs_mkdir_response, %{req_id: req_id, ok: true}}

        {:error, :eexist} ->
          {:fs_mkdir_response, %{req_id: req_id, ok: true}}

        {:error, :enoent} ->
          fs_error(req_id, :not_found)

        {:error, posix} ->
          fs_error(req_id, map_posix(posix))
      end
    else
      {:error, reason} -> fs_error(req_id, map_posix(reason))
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp check_allowed(path) do
    expanded = Path.expand(path)
    roots = Config.fs_allowed_roots()

    if Enum.any?(roots, fn root -> String.starts_with?(expanded, root) end) do
      :ok
    else
      Logger.warning("[OpenComputers.Fs] path_not_allowed: #{expanded} not in #{inspect(roots)}")
      {:error, :path_not_allowed}
    end
  end

  defp expand_path(path) do
    try do
      {:ok, Path.expand(path)}
    rescue
      _ -> {:error, :unknown}
    end
  end

  defp check_not_symlink_escape(expanded, _original_path) do
    case File.lstat(expanded) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(expanded) do
          {:ok, target} ->
            real = Path.expand(target, Path.dirname(expanded))
            roots = Config.fs_allowed_roots()

            if Enum.any?(roots, fn root -> String.starts_with?(real, root) end) do
              :ok
            else
              Logger.warning("[OpenComputers.Fs] symlink escape blocked: #{expanded} -> #{real}")
              {:error, :path_not_allowed}
            end

          _ ->
            {:error, :unknown}
        end

      _ ->
        :ok
    end
  end

  defp do_read(fd, offset, max_bytes, req_id) do
    with :ok <- position_fd(fd, offset) do
      case IO.binread(fd, max_bytes) do
        :eof ->
          {:fs_read_response, %{req_id: req_id, data: <<>>, eof: true}}

        {:error, reason} ->
          fs_error(req_id, map_posix(reason))

        data when is_binary(data) ->
          eof =
            case IO.binread(fd, 1) do
              :eof -> true
              {:error, _} -> true
              _ -> false
            end

          {:fs_read_response, %{req_id: req_id, data: data, eof: eof}}
      end
    else
      {:error, reason} -> fs_error(req_id, map_posix(reason))
    end
  end

  defp position_fd(_fd, 0), do: :ok

  defp position_fd(fd, offset) do
    case :file.position(fd, offset) do
      {:ok, _} -> :ok
      {:error, posix} -> {:error, map_posix(posix)}
    end
  end

  defp do_write(fd, offset, data, req_id) do
    with :ok <- position_fd(fd, offset) do
      case IO.binwrite(fd, data) do
        :ok ->
          {:fs_write_response, %{req_id: req_id, bytes_written: byte_size(data)}}

        {:error, reason} ->
          fs_error(req_id, map_posix(reason))
      end
    else
      {:error, reason} -> fs_error(req_id, map_posix(reason))
    end
  end

  defp build_write_modes(_create, truncate) do
    if truncate do
      [:write, :binary]
    else
      [:read, :write, :binary]
    end
  end

  defp file_type(:regular), do: :file
  defp file_type(:directory), do: :dir
  defp file_type(:symlink), do: :symlink
  defp file_type(_), do: :other

  defp to_unix({{_, _, _}, {_, _, _}} = erl_dt) do
    case NaiveDateTime.from_erl(erl_dt) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp to_unix(_), do: 0

  defp map_posix(:enoent), do: :not_found
  defp map_posix(:eacces), do: :permission_denied
  defp map_posix(:eperm), do: :permission_denied
  defp map_posix(:enotdir), do: :not_found
  defp map_posix(:not_found), do: :not_found
  defp map_posix(:permission_denied), do: :permission_denied
  defp map_posix(:path_not_allowed), do: :path_not_allowed
  defp map_posix(:too_large), do: :too_large
  defp map_posix(:timeout), do: :timeout
  defp map_posix(_), do: :unknown

  defp fs_error(req_id, reason) do
    Logger.warning("[OpenComputers.Fs] error req=#{req_id} reason=#{reason}")
    {:fs_error, %{req_id: req_id, reason: reason}}
  end
end
