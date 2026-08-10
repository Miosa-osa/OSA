defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_read`.

  Three-stage pipeline:
    * `validate/2`            — type checks input shape (cheap)
    * `check_permissions/2`   — path allowlist + sensitive-file deny
    * `execute/2`              — actual file read

  Logic was moved verbatim from the original `file_read.ex` (allowlist check,
  symlink resolution, image handling, range read). No semantic changes
  in Phase 1 — just relocation + permission/validation split.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Constants
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path),
    do: {:ok, input}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "path must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    expanded = path |> Path.expand() |> resolve_real_path()

    cond do
      sensitive?(expanded) ->
        {:deny, "Access denied: #{path} is a sensitive system file"}

      not allowed?(expanded) ->
        {:deny, "Access denied: #{path} is outside allowed read paths"}

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:ok, {:image, map()}} | {:error, String.t()}
  def execute(%{"path" => path} = input, ctx) do
    result = do_read(input)

    # Record read-state for read-before-edit / stale-write enforcement (P0-1).
    # Only successful reads of an actual file are recorded; canonical() inside
    # FileState re-stats the path, so a directory/enoent that slipped through is
    # a harmless no-op.
    if match?({:ok, _}, result) do
      expanded = path |> Path.expand() |> resolve_real_path()
      FileState.record_read(session_id(ctx), expanded)
    end

    result
  end

  defp do_read(%{"path" => path} = input) do
    expanded = path |> Path.expand() |> resolve_real_path()
    offset = input["offset"]
    limit = input["limit"]
    ext = expanded |> Path.extname() |> String.downcase()

    cond do
      # Pre-flight: surface a clear actionable error when the model points
      # `file_read` at a directory or a non-existent path. Without this,
      # the model gets back raw `:eisdir` / `:enoent` and tends to retry the
      # same failing call instead of switching tools.
      File.dir?(expanded) ->
        {:error,
         "#{path} is a directory, not a file. Use `dir_list` with `path: \"#{path}\"` to list its contents, or use `file_glob`/`file_grep` to search inside it."}

      not File.exists?(expanded) ->
        {:error,
         "#{path} does not exist. Use `dir_list` on its parent directory or `file_glob` to find the right path."}

      ext in Constants.image_extensions() ->
        read_image(expanded, path, ext)

      offset || limit ->
        read_with_range(expanded, path, offset, limit)

      too_large?(expanded) ->
        {mb, cap_mb} = size_report(expanded)

        {:error,
         "#{path} is too large to read whole (#{mb} MB, cap #{cap_mb} MB). " <>
           "Read a slice with `offset`/`limit`, or use `file_grep` to search inside it."}

      true ->
        case File.read(expanded) do
          {:ok, content} ->
            if String.valid?(content) do
              {:ok, content}
            else
              {:error,
               "#{path} appears to be a binary or non-UTF-8 file; file_read only returns text and images. Use `shell_execute` with an appropriate tool if you need its bytes."}
            end

          {:error, :eisdir} ->
            {:error,
             "#{path} is a directory, not a file. Use `dir_list` instead."}

          {:error, :enoent} ->
            {:error,
             "#{path} does not exist. Use `dir_list` or `file_glob` to find the right path."}

          {:error, reason} ->
            {:error, "Error reading file #{path}: #{reason}"}
        end
    end
  end

  # True when a whole-file read would exceed the byte cap. Slices (offset/limit)
  # never reach here, so they remain unbounded-by-lines but streamed.
  defp too_large?(expanded) do
    case File.stat(expanded) do
      {:ok, %{size: size}} -> size > Constants.max_read_bytes()
      _ -> false
    end
  end

  defp size_report(expanded) do
    mb =
      case File.stat(expanded) do
        {:ok, %{size: size}} -> Float.round(size / (1024 * 1024), 1)
        _ -> 0.0
      end

    {mb, div(Constants.max_read_bytes(), 1024 * 1024)}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  defp read_with_range(expanded, display_path, offset, limit) do
    cond do
      File.dir?(expanded) ->
        {:error,
         "#{display_path} is a directory, not a file. Use `dir_list` to list contents."}

      not File.exists?(expanded) ->
        {:error,
         "#{display_path} does not exist. Use `dir_list` on its parent directory or `file_glob` to find the right path."}

      true ->
        read_with_range_inner(expanded, display_path, offset, limit)
    end
  end

  defp read_with_range_inner(expanded, display_path, offset, limit) do
    drop_count = if offset && offset > 1, do: offset - 1, else: 0
    start_line = if offset && offset > 0, do: offset, else: 1

    lines =
      expanded
      |> File.stream!()
      |> Stream.drop(drop_count)
      |> then(fn stream ->
        if limit && limit > 0, do: Stream.take(stream, limit), else: stream
      end)
      |> Stream.with_index(start_line)
      |> Enum.map(fn {line, line_num} ->
        num_str = line_num |> Integer.to_string() |> String.pad_leading(5)
        "#{num_str}| #{String.trim_trailing(line, "\n")}"
      end)
      |> Enum.join("\n")

    if lines == "" do
      {:error, "No lines in range for #{display_path}"}
    else
      {:ok, lines}
    end
  end

  defp read_image(expanded, display_path, ext) do
    max_bytes = Constants.max_image_bytes()

    case File.stat(expanded) do
      {:ok, %{size: size}} when size > max_bytes ->
        {:error,
         "Image too large: #{display_path} (#{div(size, 1024)}KB, max #{div(max_bytes, 1024)}KB)"}

      {:ok, _stat} ->
        case File.read(expanded) do
          {:ok, bytes} ->
            b64 = Base.encode64(bytes)
            media_type = image_media_type(ext)
            {:ok, {:image, %{media_type: media_type, data: b64, path: display_path}}}

          {:error, reason} ->
            {:error, "Error reading image: #{reason}"}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{display_path}"}

      {:error, reason} ->
        {:error, "Cannot stat #{display_path}: #{reason}"}
    end
  end

  defp image_media_type(".png"), do: "image/png"
  defp image_media_type(".jpg"), do: "image/jpeg"
  defp image_media_type(".jpeg"), do: "image/jpeg"
  defp image_media_type(".gif"), do: "image/gif"
  defp image_media_type(".webp"), do: "image/webp"
  defp image_media_type(".bmp"), do: "image/bmp"
  defp image_media_type(".tiff"), do: "image/tiff"
  defp image_media_type(_), do: "application/octet-stream"

  defp allowed_paths do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :allowed_read_paths,
        Constants.default_allowed_paths()
      )

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  # Resolve symlinks before security checks to prevent symlink traversal.
  defp resolve_real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real} ->
        real_str = to_string(real)
        if String.starts_with?(real_str, "/"), do: real_str, else: "/" <> real_str

      {:error, :einval} ->
        path

      {:error, _} ->
        path
    end
  end

  defp sensitive?(expanded_path) do
    Enum.any?(Constants.sensitive_paths(), fn pattern ->
      String.contains?(expanded_path, pattern)
    end) or expanded_path == subscription_store_path()
  end

  # The literal patterns above assume the credential store lives under a
  # directory named `.osa`. It usually does — but `OSA_HOME` can move it
  # anywhere, and a substring deny that silently stops applying when a user
  # relocates their config is worse than no deny at all, because nothing
  # announces it. Ask the store where it actually is.
  defp subscription_store_path do
    OptimalSystemAgent.Auth.SubscriptionStore.path()
  rescue
    _ -> "\0"
  end

  defp allowed?(expanded_path) do
    check_path =
      if String.ends_with?(expanded_path, "/"),
        do: expanded_path,
        else: expanded_path <> "/"

    Enum.any?(allowed_paths(), fn allowed ->
      String.starts_with?(check_path, allowed)
    end)
  end
end
