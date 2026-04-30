defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_glob`.

  Split mirrors the FileRead.Handler pattern:
    * `validate/2`           — type checks input shape (cheap)
    * `check_permissions/2`  — path allowlist + sensitive-path deny
    * `execute/2`            — actual glob expansion

  Logic is verbatim from the original `file_glob.ex` — no semantic changes.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGlob.Constants
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
    max = Constants.max_results()

    results =
      Path.wildcard(Path.join(base, pattern))
      |> Enum.reject(fn p ->
        Enum.any?(Constants.sensitive_paths(), &String.contains?(p, &1))
      end)
      |> Enum.sort()
      |> Enum.take(max)

    case results do
      [] ->
        {:ok, "No files matched pattern: #{pattern}"}

      files ->
        count_msg =
          if length(files) >= max, do: " (showing first #{max})", else: ""

        {:ok, "#{length(files)} files found#{count_msg}:\n#{Enum.join(files, "\n")}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

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
