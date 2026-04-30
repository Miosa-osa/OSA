defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_grep`.

  Behaviour split mirrors `FileRead.Handler`:
    * `validate/2`           — type-checks input shape (cheap)
    * `check_permissions/2`  — path allowlist + sensitive-file deny
    * `execute/2`            — ripgrep with Elixir fallback

  Logic relocated verbatim from the original `file_grep.ex`. No semantic
  changes — just relocation + permission/validation split.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"pattern" => pattern} = input, _ctx) when is_binary(pattern),
    do: {:ok, input}

  def validate(%{"pattern" => _}, _ctx),
    do: {:error, "pattern must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: pattern", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    expanded = Path.expand(path)

    cond do
      sensitive?(expanded) ->
        {:deny, "Access denied: #{path} is a sensitive system file"}

      not allowed?(expanded) ->
        {:deny, "Access denied: #{path} is outside allowed paths"}

      true ->
        {:allow, input}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"pattern" => pattern} = params, _ctx) do
    path = Path.expand(params["path"] || ".")

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

  def execute(_, _ctx), do: {:error, "Missing required parameter: pattern"}

  # ── Private: ripgrep path ─────────────────────────────────────────────

  defp try_ripgrep(pattern, path, opts) do
    max = opts[:max_results] || Constants.default_max_results()

    args = ["--no-heading", "--color", "never"]

    args =
      case opts[:output_mode] do
        "files_with_matches" -> args ++ ["-l"]
        "count" -> args ++ ["-c"]
        _ -> args ++ ["-n"]
      end

    args = args ++ ["-m", to_string(max)]
    args = if opts[:case_insensitive], do: args ++ ["-i"], else: args

    args =
      if opts[:context_lines], do: args ++ ["-C", to_string(opts[:context_lines])], else: args

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

  # ── Private: Elixir fallback ──────────────────────────────────────────

  defp fallback_grep(pattern, path, opts) do
    regex_opts = if opts[:case_insensitive], do: "i", else: ""

    case Regex.compile(pattern, regex_opts) do
      {:error, _} ->
        {:error, "Invalid regex pattern: #{pattern}"}

      {:ok, r} ->
        files = collect_files(path, opts[:glob])
        max = opts[:max_results] || Constants.default_max_results()

        results =
          case opts[:output_mode] do
            "files_with_matches" ->
              Enum.filter(files, fn file ->
                case File.read(file) do
                  {:ok, content} -> Regex.match?(r, content)
                  _ -> false
                end
              end)

            "count" ->
              Enum.flat_map(files, fn file ->
                case File.read(file) do
                  {:ok, content} ->
                    count =
                      content |> String.split("\n") |> Enum.count(&Regex.match?(r, &1))

                    if count > 0, do: ["#{file}:#{count}"], else: []

                  _ ->
                    []
                end
              end)

            _ ->
              Enum.flat_map(files, fn file ->
                case File.read(file) do
                  {:ok, content} ->
                    content
                    |> String.split("\n")
                    |> Enum.with_index(1)
                    |> Enum.filter(fn {line, _} -> Regex.match?(r, line) end)
                    |> Enum.take(max)
                    |> Enum.map(fn {line, num} -> "#{file}:#{num}:#{line}" end)

                  _ ->
                    []
                end
              end)
          end

        case results do
          [] -> {:ok, "No matches found."}
          lines -> {:ok, truncate(Enum.join(lines, "\n"))}
        end
    end
  end

  defp collect_files(path, glob) do
    if File.regular?(path) do
      [path]
    else
      file_pattern = glob || "**/*"

      Path.wildcard(Path.join(path, file_pattern))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(fn p ->
        Enum.any?(Constants.sensitive_paths(), &String.contains?(p, &1))
      end)
      |> Enum.take(Constants.max_fallback_files())
    end
  end

  @max_output_bytes Constants.max_output_bytes()

  defp truncate(output) when byte_size(output) > @max_output_bytes do
    String.slice(output, 0, @max_output_bytes) <> "\n...[truncated]"
  end

  defp truncate(output), do: output

  defp sensitive?(expanded_path) do
    Enum.any?(Constants.sensitive_paths(), fn p -> String.contains?(expanded_path, p) end)
  end

  defp allowed?(expanded_path) do
    check =
      if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

    Enum.any?(allowed_paths(), fn a -> String.starts_with?(check, a) end)
  end

  defp allowed_paths do
    Application.get_env(
      :optimal_system_agent,
      :allowed_read_paths,
      Constants.default_allowed_paths()
    )
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end
end
