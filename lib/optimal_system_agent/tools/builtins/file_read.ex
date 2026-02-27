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
  def description, do: "Read a file from the filesystem"

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

  @impl true
  def execute(%{"path" => path}) do
    expanded = Path.expand(path)

    if path_allowed?(expanded) do
      case File.read(expanded) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Error reading file: #{reason}"}
      end
    else
      {:error, "Access denied: #{path} is outside allowed paths or is a sensitive file"}
    end
  end

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
