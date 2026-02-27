defmodule OptimalSystemAgent.Skills.Builtins.FileGrep do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]

  @max_output_bytes 8_000

  @impl true
  def name, do: "file_grep"

  @impl true
  def description, do: "Search file contents for a regex pattern. Returns matching lines with file:line format."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regex pattern to search for"},
        "path" => %{"type" => "string", "description" => "File or directory to search in (default: current directory)"},
        "glob" => %{"type" => "string", "description" => "File filter glob (e.g. '*.ex', '*.ts')"}
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
      case try_ripgrep(pattern, path, params["glob"]) do
        {:ok, output} -> {:ok, truncate(output)}
        {:fallback, _} -> fallback_grep(pattern, path, params["glob"])
      end
    end
  end
  def execute(_), do: {:error, "Missing required parameter: pattern"}

  defp try_ripgrep(pattern, path, glob) do
    args = ["-n", "--no-heading", "--color", "never", "-m", "50"]
    args = if glob, do: args ++ ["-g", glob], else: args
    args = args ++ [pattern, path]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, "No matches found."}
      {_, _} -> {:fallback, :rg_not_found}
    end
  rescue
    _ -> {:fallback, :rg_not_found}
  end

  defp fallback_grep(pattern, path, glob) do
    regex = case Regex.compile(pattern) do
      {:ok, r} -> r
      {:error, _} -> {:error, "Invalid regex pattern: #{pattern}"}
    end

    case regex do
      {:error, msg} -> {:error, msg}
      r ->
        files = if File.regular?(path) do
          [path]
        else
          file_pattern = glob || "**/*"
          Path.wildcard(Path.join(path, file_pattern))
          |> Enum.filter(&File.regular?/1)
          |> Enum.reject(fn p -> Enum.any?(@sensitive_paths, &String.contains?(p, &1)) end)
          |> Enum.take(500)
        end

        results = Enum.flat_map(files, fn file ->
          case File.read(file) do
            {:ok, content} ->
              content
              |> String.split("\n")
              |> Enum.with_index(1)
              |> Enum.filter(fn {line, _} -> Regex.match?(r, line) end)
              |> Enum.take(10)
              |> Enum.map(fn {line, num} -> "#{file}:#{num}:#{line}" end)
            _ -> []
          end
        end)

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
