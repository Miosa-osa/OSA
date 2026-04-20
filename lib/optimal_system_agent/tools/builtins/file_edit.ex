defmodule OptimalSystemAgent.Tools.Builtins.FileEdit do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  # Copy the EXACT security constants from FileRead AND FileWrite
  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]
  @blocked_write_paths [".ssh/", ".gnupg/", "/etc/", "/boot/", "/usr/",
    "/bin/", "/sbin/", "/var/", ".aws/", ".env"]

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "file_edit"

  @impl true
  def description do
    "Performs exact string replacements in files.\n\n" <>
    "Usage:\n" <>
    "- You must use file_read at least once before editing. This tool will error if you attempt an edit without reading the file.\n" <>
    "- When editing text, ensure you preserve the exact indentation (tabs/spaces) as it appears in the file.\n" <>
    "- ALWAYS prefer editing existing files. NEVER write new files unless explicitly required.\n" <>
    "- The edit will FAIL if old_string is not unique in the file. Provide a larger string with more surrounding context to make it unique, or use replace_all to change every instance.\n" <>
    "- Use replace_all for renaming strings across the file (e.g., renaming a variable).\n" <>
    "- Only use emojis if the user explicitly requests it."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Absolute path to the file"},
        "old_string" => %{"type" => "string", "description" => "Exact text to find (must be unique unless replace_all is true)"},
        "new_string" => %{"type" => "string", "description" => "Text to replace it with"},
        "replace_all" => %{"type" => "boolean", "description" => "Replace all occurrences (default: false)"}
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(%{"path" => path, "old_string" => old, "new_string" => new} = params) do
    expanded = Path.expand(path)
    replace_all = params["replace_all"] == true

    # Resolve symlinks BEFORE security checks to prevent symlink traversal attacks.
    # file_edit only operates on existing files, so we always resolve the full path.
    resolved = resolve_real_path(expanded)
    symlink_traversal? = resolved != expanded

    cond do
      symlink_traversal? and (not read_allowed?(resolved) or not write_allowed?(resolved)) ->
        {:error, "Access denied: #{path} resolves through a symlink to a protected location"}

      not read_allowed?(resolved) ->
        {:error, "Access denied: #{path} is outside allowed paths or is a sensitive file"}

      not write_allowed?(resolved) ->
        {:error, "Access denied: #{path} targets a protected location"}

      old == new ->
        {:error, "old_string and new_string are identical"}

      old == "" ->
        {:error, "old_string cannot be empty"}

      true ->
        do_edit(resolved, path, old, new, replace_all)
    end
  end
  def execute(_), do: {:error, "Missing required parameters: path, old_string, new_string"}

  defp do_edit(expanded, display_path, old, new, replace_all) do
    case File.read(expanded) do
      {:ok, content} ->
        occurrences = count_occurrences(content, old)
        cond do
          occurrences == 0 ->
            {:error, "old_string not found in #{display_path}"}
          occurrences > 1 and not replace_all ->
            {:error, "old_string found #{occurrences} times — must be unique. Add more surrounding context or use replace_all."}
          true ->
            new_content = String.replace(content, old, new, global: replace_all)
            File.write!(expanded, new_content)

            # Emit file_changed hook
            try do
              OptimalSystemAgent.Agent.Hooks.run_async(:file_changed, %{
                path: expanded, tool: "file_edit", operation: :edit
              })
            rescue _ -> :ok end

            # Generate unified diff
            {diff_text, diff_stats} = OptimalSystemAgent.Utils.Diff.unified(content, new_content, display_path)

            result =
              if replace_all and occurrences > 1 do
                "Replaced #{occurrences} occurrences in #{display_path}"
              else
                "Replaced in #{display_path}\n#{format_diff(old, new, content, display_path)}"
              end

            # Attach diff metadata for SSE consumers
            if diff_text != "" do
              {:ok, result, %{diff: diff_text, stats: diff_stats, path: expanded}}
            else
              {:ok, result}
            end
        end
      {:error, :enoent} -> {:error, "File not found: #{display_path}"}
      {:error, reason} -> {:error, "Cannot read #{display_path}: #{reason}"}
    end
  end

  defp count_occurrences(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end

  # Build a minimal unified diff showing the change with context lines
  defp format_diff(old, new, content, path) do
    lines = String.split(content, "\n")
    old_lines = String.split(old, "\n")
    first_old_line = List.first(old_lines) || ""

    # Find the line number where the match starts
    start_idx = Enum.find_index(lines, fn l -> String.contains?(l, first_old_line) end) || 0

    # Context: 2 lines before and after
    ctx_before = Enum.slice(lines, max(start_idx - 2, 0), min(2, start_idx))
    ctx_after = Enum.slice(lines, start_idx + length(old_lines), 2)

    removed = old_lines |> Enum.map(fn l -> "- #{l}" end)
    added = String.split(new, "\n") |> Enum.map(fn l -> "+ #{l}" end)
    context_b = ctx_before |> Enum.map(fn l -> "  #{l}" end)
    context_a = ctx_after |> Enum.map(fn l -> "  #{l}" end)

    header = "--- #{path}\n+++ #{path}"
    hunk = "@@ -#{max(start_idx - 1, 1)},#{length(old_lines) + 4} @@"

    diff_lines = [header, hunk] ++ context_b ++ removed ++ added ++ context_a
    Enum.join(diff_lines, "\n")
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

  # Security: copy exact patterns from FileRead and FileWrite
  defp read_allowed?(expanded_path) do
    sensitive = Enum.any?(@sensitive_paths, fn p -> String.contains?(expanded_path, p) end)
    if sensitive do
      false
    else
      check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
      Enum.any?(allowed_read_paths(), fn a -> String.starts_with?(check, a) end)
    end
  end

  defp write_allowed?(expanded_path) do
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked = Enum.any?(@blocked_write_paths, fn p -> String.contains?(expanded_path, p) end)
      if blocked do
        false
      else
        check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
        Enum.any?(allowed_write_paths(), fn a -> String.starts_with?(check, a) end)
      end
    end
  end

  defp allowed_read_paths do
    Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp allowed_write_paths do
    Application.get_env(:optimal_system_agent, :allowed_write_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")
    osa = Path.expand("~/.osa") <> "/"
    case String.split_at(expanded_path, byte_size(home)) do
      {^home, "/" <> rest} ->
        first = rest |> String.split("/") |> List.first()
        String.starts_with?(first, ".") and not String.starts_with?(expanded_path, osa)
      _ -> false
    end
  end
end
