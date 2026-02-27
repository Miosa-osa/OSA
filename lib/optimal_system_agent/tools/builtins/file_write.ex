defmodule OptimalSystemAgent.Tools.Builtins.FileWrite do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @default_allowed_write_paths ["~", "/tmp"]

  @blocked_write_paths [
    ".ssh/",
    ".gnupg/",
    "/etc/",
    "/boot/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/var/",
    ".aws/",
    ".env"
  ]

  @impl true
  def name, do: "file_write"

  @impl true
  def description, do: "Write content to a file"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to write to"},
        "content" => %{"type" => "string", "description" => "Content to write"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}) do
    expanded = Path.expand(path)

    if write_allowed?(expanded) do
      case File.mkdir_p(Path.dirname(expanded)) do
        :ok ->
          case File.write(expanded, content) do
            :ok -> {:ok, "Written to #{expanded}"}
            {:error, reason} -> {:error, "Error writing file: #{reason}"}
          end

        {:error, reason} ->
          {:error, "Cannot create directory: #{:file.format_error(reason)}"}
      end
    else
      {:error, "Access denied: #{path} is outside allowed paths or targets a protected location"}
    end
  end

  defp allowed_write_paths do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :allowed_write_paths,
        @default_allowed_write_paths
      )

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  defp osa_path do
    Path.expand("~/.osa") <> "/"
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")
    # A dotfile is any path directly under ~ starting with a dot component
    # e.g. ~/.bashrc, ~/.zshrc, ~/.config/..., ~/.ssh/config
    # but NOT paths under ~/.osa/ (those are OSA's own config)
    relative =
      case String.split_at(expanded_path, byte_size(home)) do
        {^home, rest} -> rest
        _ -> nil
      end

    case relative do
      "/" <> rest ->
        first_component = rest |> String.split("/") |> List.first()
        starts_with_dot = String.starts_with?(first_component, ".")
        under_osa = String.starts_with?(expanded_path, osa_path())
        starts_with_dot and not under_osa

      _ ->
        false
    end
  end

  defp write_allowed?(expanded_path) do
    # Block dotfiles outside ~/.osa/
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked =
        Enum.any?(@blocked_write_paths, fn pattern ->
          String.contains?(expanded_path, pattern)
        end)

      if blocked do
        false
      else
        check_path =
          if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

        Enum.any?(allowed_write_paths(), fn allowed ->
          String.starts_with?(check_path, allowed)
        end)
      end
    end
  end
end
