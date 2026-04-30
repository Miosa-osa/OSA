defmodule OptimalSystemAgent.Tools.Builtins.DirList.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `dir_list`.

  Behaviour split:
    * `validate/2`           — type checks input shape (cheap, no I/O)
    * `check_permissions/2`  — path allowlist + sensitive-directory deny
    * `execute/2`            — actual directory listing

  Logic is migrated verbatim from the original `dir_list.ex` flat module.
  No semantic changes — just relocation into the structured layout and the
  validate / check_permissions / execute three-stage split.
  """

  alias OptimalSystemAgent.Tools.Builtins.DirList.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path),
    do: {:ok, input}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "path must be a string", -32_602}

  # path is optional — default to "." when absent
  def validate(input, _ctx) when is_map(input),
    do: {:ok, input}

  def validate(_input, _ctx),
    do: {:error, "Input must be a map", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx) do
    path = Map.get(input, "path") || "."
    expanded = Path.expand(path)

    cond do
      sensitive?(expanded) ->
        {:deny, "Access denied: #{path} matches a sensitive path pattern"}

      not allowed?(expanded) ->
        {:deny, "Access denied: #{path} is outside allowed read paths"}

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(input, _ctx) do
    path = Map.get(input, "path") || "."
    expanded = Path.expand(path)

    case File.ls(expanded) do
      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.map(fn entry ->
            full = Path.join(expanded, entry)

            {type, size} =
              case File.stat(full) do
                {:ok, %{type: :directory}} -> {"dir", 0}
                {:ok, %{type: :regular, size: s}} -> {"file", s}
                {:ok, %{type: t, size: s}} -> {to_string(t), s}
                _ -> {"?", 0}
              end

            "#{type}\t#{format_size(size)}\t#{entry}"
          end)

        {:ok, Enum.join(lines, "\n")}

      {:error, :enoent} ->
        {:error, "Directory not found: #{expanded}"}

      {:error, reason} ->
        {:error, "Cannot list #{expanded}: #{reason}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp format_size(0), do: "-"
  defp format_size(n) when n < 1_024, do: "#{n}B"
  defp format_size(n) when n < 1_048_576, do: "#{Float.round(n / 1_024, 1)}K"
  defp format_size(n), do: "#{Float.round(n / 1_048_576, 1)}M"

  defp allowed_paths do
    Application.get_env(
      :optimal_system_agent,
      :allowed_read_paths,
      Constants.default_allowed_paths()
    )
    |> Enum.map(fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  defp sensitive?(expanded_path) do
    Enum.any?(Constants.sensitive_paths(), fn pattern ->
      String.contains?(expanded_path, pattern)
    end)
  end

  defp allowed?(expanded_path) do
    check_path =
      if String.ends_with?(expanded_path, "/"),
        do: expanded_path,
        else: expanded_path <> "/"

    Enum.any?(allowed_paths(), fn allowed ->
      String.starts_with?(check_path, allowed)
    end)
  end
end
