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
  def name, do: "file_read"

  @impl true
  def description, do: "Read a file from the filesystem. Supports images (.png, .jpg, .gif, .webp) — returns base64 for vision analysis."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"}
      },
      "required" => ["path"]
    }
  end

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp .tiff)
  @max_image_bytes 10 * 1024 * 1024

  @impl true
  def execute(%{"path" => path}) do
    expanded = Path.expand(path)

    if path_allowed?(expanded) do
      ext = Path.extname(expanded) |> String.downcase()

      if ext in @image_extensions do
        read_image(expanded, path, ext)
      else
        case File.read(expanded) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Error reading file: #{reason}"}
        end
      end
    else
      {:error, "Access denied: #{path} is outside allowed paths or is a sensitive file"}
    end
  end

  defp read_image(expanded, display_path, ext) do
    case File.stat(expanded) do
      {:ok, %{size: size}} when size > @max_image_bytes ->
        {:error, "Image too large: #{display_path} (#{div(size, 1024)}KB, max #{div(@max_image_bytes, 1024)}KB)"}

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
