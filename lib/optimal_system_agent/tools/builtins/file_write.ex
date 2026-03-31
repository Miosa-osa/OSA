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
  def safety, do: :write_safe

  @impl true
  def name, do: "file_write"

  @impl true
  def description, do: "Write content to a file. Use relative paths (e.g. 'my-app/server.js') to write into the workspace at ~/.osa/workspace/. Absolute paths and ~ paths are also accepted."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to write to. Relative paths are rooted at ~/.osa/workspace/ automatically. Example: 'todo-app/server.js' writes to ~/.osa/workspace/todo-app/server.js"},
        "content" => %{"type" => "string", "description" => "Content to write"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}) do
    normalized =
      if relative_path?(path) do
        Path.join("~/.osa/workspace", path)
      else
        path
      end

    expanded = Path.expand(normalized)

    # Resolve symlinks BEFORE security checks to prevent symlink traversal attacks.
    # If the target file doesn't exist yet, resolve its parent directory instead,
    # then reconstruct the full resolved path with the filename appended.
    {resolved, symlink_traversal?} = resolve_for_write(expanded)

    cond do
      symlink_traversal? and not write_allowed?(resolved) ->
        {:error, "Access denied: #{path} resolves through a symlink to a protected location"}

      not write_allowed?(resolved) ->
        {:error, "Access denied: #{path} is outside allowed paths or targets a protected location"}

      true ->
        # Read existing content for diff generation (if file exists)
        old_content = case File.read(expanded) do
          {:ok, existing} -> existing
          {:error, _} -> nil
        end

        case File.mkdir_p(Path.dirname(expanded)) do
          :ok ->
            case File.write(expanded, content) do
              :ok ->
                # Reload Soul cache when agent writes to ~/.osa/ identity/personality files
                maybe_reload_soul(expanded)

                # Emit file_changed hook
                operation = if old_content, do: :overwrite, else: :create
                try do
                  OptimalSystemAgent.Agent.Hooks.run_async(:file_changed, %{
                    path: expanded, tool: "file_write", operation: operation
                  })
                rescue _ -> :ok end

                line_count = content |> String.split("\n") |> length()
                preview = content |> String.split("\n") |> Enum.take(10) |> Enum.join("\n")

                # Generate diff for event payload
                {diff_text, diff_stats} =
                  case old_content do
                    nil ->
                      OptimalSystemAgent.Utils.Diff.for_new_file(content, path)
                    old when old == content ->
                      {"", %{additions: 0, deletions: 0}}
                    old ->
                      OptimalSystemAgent.Utils.Diff.unified(old, content, path)
                  end

                result = "#{expanded}\n#{line_count} lines written\n---\n#{preview}"

                # Attach diff metadata for SSE consumers
                if diff_text != "" do
                  {:ok, result, %{diff: diff_text, stats: diff_stats, path: expanded}}
                else
                  {:ok, result}
                end
              {:error, reason} -> {:error, "Error writing file: #{reason}"}
            end

          {:error, reason} ->
            {:error, "Cannot create directory: #{:file.format_error(reason)}"}
        end
    end
  end

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end

  # Resolve symlinks for a write target path.
  # Returns {resolved_path, symlink_traversal?} where symlink_traversal? is true
  # when the resolved path differs from the original expanded path.
  #
  # For existing files: resolve the full path via :file.read_link_all.
  # For new files (don't exist yet): resolve the parent directory and reconstruct
  # the full path, so a symlinked parent directory is caught.
  defp resolve_for_write(expanded_path) do
    case resolve_real_path(expanded_path) do
      ^expanded_path ->
        # Path resolved to itself — check if parent resolves differently
        parent = Path.dirname(expanded_path)
        resolved_parent = resolve_real_path(parent)

        if resolved_parent == parent do
          {expanded_path, false}
        else
          # Parent resolved through a symlink — reconstruct the full path
          filename = Path.basename(expanded_path)
          resolved = Path.join(resolved_parent, filename)
          {resolved, resolved != expanded_path}
        end

      resolved ->
        # File itself resolved to a different path (it's a symlink or in a symlinked dir)
        {resolved, true}
    end
  end

  # Resolve all symlink components in a path to get the real filesystem path.
  # Uses :file.read_link_all which follows the full symlink chain (POSIX realpath).
  # Falls back to the original path if the path doesn't exist or has no symlinks.
  defp resolve_real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real} -> to_string(real)
      {:error, :einval} -> path
      {:error, _} -> path
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

  @soul_reload_files ~w(USER.md IDENTITY.md SOUL.md)

  defp maybe_reload_soul(expanded_path) do
    osa_dir = Path.expand("~/.osa")
    filename = Path.basename(expanded_path)

    if String.starts_with?(expanded_path, osa_dir) and filename in @soul_reload_files do
      try do
        OptimalSystemAgent.Soul.reload()
      rescue
        _ -> :ok
      end
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
