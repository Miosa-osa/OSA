defmodule OptimalSystemAgent.Tools.Builtins.FileGrep do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]

  @max_output_bytes 8_000

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "file_grep"

  @impl true
  def description do
    "Search file contents for a regex pattern.\n\n" <>
    "Usage:\n" <>
    "- ALWAYS use file_grep for content search. NEVER use shell_execute with grep or rg.\n" <>
    "- Supports full regex syntax (e.g., \"log.*Error\", \"function\\\\s+\\\\w+\")\n" <>
    "- Filter files with glob parameter (e.g., \"*.js\", \"**/*.tsx\")\n" <>
    "- Output modes: 'content' shows matching lines, 'files' shows only file paths (default), 'count' shows match counts\n" <>
    "- Use context parameter to see surrounding code lines"
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regex pattern to search for"},
        "path" => %{"type" => "string", "description" => "File or directory to search in (default: current directory)"},
        "glob" => %{"type" => "string", "description" => "File filter glob (e.g. '*.ex', '*.ts')"},
        "case_insensitive" => %{"type" => "boolean", "description" => "Case-insensitive search (default: false)"},
        "context_lines" => %{"type" => "integer", "description" => "Lines of context before and after each match"},
        "output_mode" => %{
          "type" => "string",
          "enum" => ["content", "files_with_matches", "count"],
          "description" => "Output mode: content (matching lines), files_with_matches (file paths only), count (match counts)"
        },
        "max_results" => %{"type" => "integer", "description" => "Maximum matches per file (default: 50)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = params) do
    path = Path.expand(params["path"] || ".")

    if not path_allowed?(path) do
      {:error, "Access denied: #{path} is outside allowed paths"}
    else
      rg_opts = %{
        glob: params["glob"],
        case_insensitive: params["case_insensitive"] == true,
        context_lines: params["context_lines"],
        output_mode: params["output_mode"],
        max_results: params["max_results"]
      }

      case try_ripgrep(pattern, path, rg_opts) do
        {:ok, output} -> {:ok, truncate(output)}
        {:fallback, _} -> fallback_grep(pattern, path, rg_opts)
      end
    end
  end
  def execute(_), do: {:error, "Missing required parameter: pattern"}

  defp try_ripgrep(pattern, path, opts) do
    max = opts[:max_results] || 50

    args = ["--no-heading", "--color", "never"]

    # Output mode flags
    args = case opts[:output_mode] do
      "files_with_matches" -> args ++ ["-l"]
      "count" -> args ++ ["-c"]
      _ -> args ++ ["-n"]  # content mode (default) — show line numbers
    end

    args = args ++ ["-m", to_string(max)]
    args = if opts[:case_insensitive], do: args ++ ["-i"], else: args
    args = if opts[:context_lines], do: args ++ ["-C", to_string(opts[:context_lines])], else: args
    args = if opts[:glob], do: args ++ ["-g", opts[:glob]], else: args
    args = args ++ [pattern, path]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, "No matches found."}
      {_, _} -> {:fallback, :rg_not_found}
    end
  rescue
    _ -> {:fallback, :rg_not_found}
  end

  defp fallback_grep(pattern, path, opts) do
    regex_opts = if opts[:case_insensitive], do: "i", else: ""

    regex = case Regex.compile(pattern, regex_opts) do
      {:ok, r} -> r
      {:error, _} -> {:error, "Invalid regex pattern: #{pattern}"}
    end

    case regex do
      {:error, msg} -> {:error, msg}
      r ->
        files = if File.regular?(path) do
          [path]
        else
          file_pattern = opts[:glob] || "**/*"
          Path.wildcard(Path.join(path, file_pattern))
          |> Enum.filter(&File.regular?/1)
          |> Enum.reject(fn p -> Enum.any?(@sensitive_paths, &String.contains?(p, &1)) end)
          |> Enum.take(500)
        end

        max = opts[:max_results] || 50

        results = case opts[:output_mode] do
          "files_with_matches" ->
            files
            |> Enum.filter(fn file ->
              case File.read(file) do
                {:ok, content} -> Regex.match?(r, content)
                _ -> false
              end
            end)

          "count" ->
            Enum.flat_map(files, fn file ->
              case File.read(file) do
                {:ok, content} ->
                  count = content |> String.split("\n") |> Enum.count(&Regex.match?(r, &1))
                  if count > 0, do: ["#{file}:#{count}"], else: []
                _ -> []
              end
            end)

          _ ->  # "content" or nil
            Enum.flat_map(files, fn file ->
              case File.read(file) do
                {:ok, content} ->
                  content
                  |> String.split("\n")
                  |> Enum.with_index(1)
                  |> Enum.filter(fn {line, _} -> Regex.match?(r, line) end)
                  |> Enum.take(max)
                  |> Enum.map(fn {line, num} -> "#{file}:#{num}:#{line}" end)
                _ -> []
              end
            end)
        end

        case results do
          [] -> {:ok, "No matches found."}
          lines -> {:ok, truncate(Enum.join(lines, "\n"))}
        end
    end
  end

  defp truncate(output) when byte_size(output) > @max_output_bytes do
    String.slice(output, 0, @max_output_bytes) <> "\n...[truncated]"
  end
  defp truncate(output), do: output

  defp path_allowed?(expanded_path) do
    sensitive = Enum.any?(@sensitive_paths, fn p -> String.contains?(expanded_path, p) end)
    if sensitive do
      false
    else
      check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
      Enum.any?(allowed_paths(), fn a -> String.starts_with?(check, a) end)
    end
  end

  defp allowed_paths do
    Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end
end
