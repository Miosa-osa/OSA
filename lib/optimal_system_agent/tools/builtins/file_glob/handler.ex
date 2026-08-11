defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_glob`.

  Split mirrors the FileRead.Handler pattern:
    * `validate/2`           — type checks input shape (cheap)
    * `check_permissions/2`  — path allowlist + sensitive-path deny
    * `execute/2`            — actual glob expansion

  Logic is verbatim from the original `file_glob.ex` — no semantic changes.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGlob.{Constants, Messages}
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"pattern" => pattern} = input, _ctx) when is_binary(pattern) do
    case Map.get(input, "path") do
      nil -> {:ok, input}
      p when is_binary(p) -> {:ok, input}
      other -> {:error, "path must be a string, got #{inspect(other)}", -32_602}
    end
  end

  def validate(%{"pattern" => _}, _ctx),
    do: {:error, "pattern must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: pattern", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"pattern" => _} = input, _ctx) do
    base = Path.expand(input["path"] || ".")

    cond do
      sensitive?(base) ->
        {:deny, "Access denied: #{base} is a sensitive path"}

      not allowed?(base) ->
        {:deny, "Access denied: #{base} is outside allowed paths"}

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"pattern" => pattern} = input, _ctx) do
    base = Path.expand(input["path"] || ".")

    # Classify the base BEFORE globbing. `Path.wildcard` returns `[]` for a
    # nonexistent base, an unreadable base and a genuinely unmatched pattern
    # alike; those three need three different next steps, and only a `stat`
    # can tell them apart.
    case File.stat(base) do
      {:ok, %{type: :directory}} -> glob_in(pattern, base)
      {:ok, %{type: :regular}} -> {:error, Messages.base_not_a_directory(base)}
      {:ok, %{type: _other}} -> {:error, Messages.base_not_a_directory(base)}
      {:error, :enoent} -> {:error, Messages.missing_base(base)}
      {:error, reason} -> {:error, Messages.base_unreadable(base, reason)}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp glob_in(pattern, base) do
    max = Constants.max_results()
    filter_git? = not references_noise_dir?(pattern)

    all =
      base
      |> Path.join(pattern)
      # `match_dot: true` is the whole reason dotfiles are visible at all.
      # Without it `Path.wildcard/2` refuses to match any component beginning
      # with `.`, so `**/*` skipped `.github/`, `.env.example`, `.gitignore`
      # and every dot-directory beneath them — not "returned them ranked low",
      # but never returned them under any pattern the caller could write.
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&sensitive?/1)
      |> Enum.reject(fn p -> filter_git? and in_noise_dir?(p) end)
      |> Enum.sort()

    total = length(all)
    shown = Enum.take(all, max)

    case shown do
      [] ->
        {:ok, Messages.no_matches(pattern, base, entry_count(base), filter_git?)}

      files ->
        header =
          if total > max do
            Messages.truncated(length(files), total, base)
          else
            "#{total} #{if total == 1, do: "file", else: "files"} found"
          end

        {:ok, "#{header}:\n#{files |> Enum.map(&decorate/1) |> Enum.join("\n")}"}
    end
  end

  # A glob can match directories as well as files, and a caller that pipes a
  # directory into `file_read` gets an avoidable error. Marking them costs one
  # character and mirrors how `FileRead.PathResolve` decorates its suggestions,
  # so the two tools describe the filesystem the same way.
  defp decorate(path) do
    if File.dir?(path), do: path <> "/", else: path
  end

  defp entry_count(base) do
    case File.ls(base) do
      {:ok, entries} -> length(entries)
      _ -> 0
    end
  end

  defp sensitive?(path) do
    Enum.any?(Constants.sensitive_paths(), &String.contains?(path, &1))
  end

  defp in_noise_dir?(path) do
    Enum.any?(Constants.noise_dirs(), fn dir ->
      String.contains?(path, "/" <> dir <> "/") or String.ends_with?(path, "/" <> dir)
    end)
  end

  defp references_noise_dir?(pattern) do
    Enum.any?(Constants.noise_dirs(), &String.contains?(pattern, &1))
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
