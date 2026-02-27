defmodule OptimalSystemAgent.Tools.Builtins.FileGlob do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]

  @max_results 200

  @impl true
  def name, do: "file_glob"

  @impl true
  def description, do: "Search for files matching a glob pattern (e.g. '**/*.ex'). Returns matching file paths."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Glob pattern (e.g. '**/*.ex', 'lib/**/*.ex')"},
        "path" => %{"type" => "string", "description" => "Base directory to search in (default: current directory)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = params) do
    base = Path.expand(params["path"] || ".")

    if not path_allowed?(base) do
      {:error, "Access denied: #{base} is outside allowed paths"}
    else
      results = Path.wildcard(Path.join(base, pattern))
        |> Enum.reject(fn p -> Enum.any?(@sensitive_paths, &String.contains?(p, &1)) end)
        |> Enum.sort()
        |> Enum.take(@max_results)

      case results do
        [] -> {:ok, "No files matched pattern: #{pattern}"}
        files ->
          count_msg = if length(files) >= @max_results, do: " (showing first #{@max_results})", else: ""
          {:ok, "#{length(files)} files found#{count_msg}:\n#{Enum.join(files, "\n")}"}
      end
    end
  end
  def execute(_), do: {:error, "Missing required parameter: pattern"}

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
