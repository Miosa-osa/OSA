defmodule OptimalSystemAgent.Tools.Builtins.FileRead do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @default_allowed_paths ["~", "/tmp"]

  @sensitive_paths [
    ".ssh/id_rsa",
    ".ssh/id_ed25519",
    ".ssh/id_ecdsa",
    ".ssh/id_dsa",
    ".gnupg/",
    ".aws/credentials",
    ".env",
    "/etc/shadow",
    "/etc/sudoers",
    "/etc/master.passwd",
    ".netrc",
    ".npmrc",
    ".pypirc"
  ]

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "file_read"

  @impl true
  def description do
    "Reads a file from the local filesystem. You can access any file directly by using this tool.\n\n" <>
      "Usage:\n" <>
      "- The path parameter must be an absolute path, not a relative path\n" <>
      "- By default, reads the full file. Use offset and limit for large files.\n" <>
      "- This tool can read images (PNG, JPG, GIF, WEBP) — returns base64 for vision analysis.\n" <>
      "- This tool can only read files, not directories. Use dir_list for directories.\n" <>
      "- If you read a file that exists but has empty contents you will receive a warning.\n" <>
      "- ALWAYS read a file before editing it with file_edit or file_write."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"},
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-based). Optional."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read. Optional."
        }
      },
      "required" => ["path"]
    }
  end

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp .tiff)
  @max_image_bytes 10 * 1024 * 1024

  @impl true
  def execute(%{"path" => path} = params) when is_binary(path) do
    expanded = resolve_real_path(Path.expand(path))
    offset = params["offset"]
    limit = params["limit"]

    if path_allowed?(expanded) do
      ext = Path.extname(expanded) |> String.downcase()

      if ext in @image_extensions do
        read_image(expanded, path, ext)
      else
        if offset || limit do
          read_with_range(expanded, path, offset, limit)
        else
          case File.read(expanded) do
            {:ok, content} -> {:ok, content}
            {:error, reason} -> {:error, "Error reading file: #{reason}"}
          end
        end
      end
    else
      {:error, "Access denied: #{path} is outside allowed paths or is a sensitive file"}
    end
  end

  def execute(%{"path" => _}), do: {:error, "path must be a string"}
  def execute(_), do: {:error, "Missing required parameter: path"}

  defp read_with_range(expanded, display_path, offset, limit) do
    if not File.exists?(expanded) do
      {:error, "Error reading file: enoent"}
    else
      # offset is 1-based line number; drop (offset - 1) lines
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
          # Format with right-aligned line numbers and pipe separator
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
  end

  defp read_image(expanded, display_path, ext) do
    case File.stat(expanded) do
      {:ok, %{size: size}} when size > @max_image_bytes ->
        {:error,
         "Image too large: #{display_path} (#{div(size, 1024)}KB, max #{div(@max_image_bytes, 1024)}KB)"}

      {:ok, _stat} ->
        case File.read(expanded) do
          {:ok, bytes} ->
            b64 = Base.encode64(bytes)
            media_type = image_media_type(ext)
            # Return structured content that providers can send as image blocks
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
      Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  # Resolve symlinks before security checks to prevent symlink traversal attacks.
  defp resolve_real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real} -> to_string(real)
      {:error, :einval} -> path
      {:error, _} -> path
    end
  end

  defp path_allowed?(expanded_path) do
    sensitive =
      Enum.any?(@sensitive_paths, fn pattern ->
        String.contains?(expanded_path, pattern)
      end)

    if sensitive do
      false
    else
      # Normalize path with trailing slash to prevent prefix collisions
      # e.g. /tmp-evil/ must NOT match allowed path /tmp/
      check_path =
        if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

      Enum.any?(allowed_paths(), fn allowed ->
        String.starts_with?(check_path, allowed)
      end)
    end
  end
end
