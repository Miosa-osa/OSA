defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `memory_recall`.

  Split:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (read-only operation)
    * `execute/2`           — delegates to `OptimalSystemAgent.Memory.recall/2`

  Logic moved verbatim from the original `memory_recall.ex`. No semantic
  changes in Phase 1 — just relocation + the validate/check_permissions split.
  """

  alias OptimalSystemAgent.Tools.Builtins.MemoryRecall.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"query" => query} = input, _ctx) when is_binary(query) and query != "" do
    with :ok <- validate_category(input["category"]),
         :ok <- validate_limit(input["limit"]) do
      {:ok, input}
    end
  end

  def validate(%{"query" => ""}, _ctx),
    do: {:error, "query must not be empty", -32_602}

  def validate(%{"query" => _}, _ctx),
    do: {:error, "query must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: query", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx) do
    # Memory recall is always permitted — read-only operation on the agent's own store.
    {:allow, input}
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"query" => query} = args, _ctx) do
    opts =
      [limit: args["limit"] || Constants.default_limit()]
      |> maybe_add(:category, args["category"])

    case OptimalSystemAgent.Memory.recall(query, opts) do
      {:ok, []} ->
        {:ok, "No memories found for: #{query}"}

      {:ok, entries} ->
        formatted =
          entries
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, idx} ->
            rel =
              if is_float(entry.relevance),
                do: Float.round(entry.relevance, 2),
                else: entry.relevance

            "#{idx}. [#{entry.category}] #{entry.content} (#{entry.scope}, relevance: #{rel})"
          end)
          |> Enum.join("\n")

        {:ok, "Found #{length(entries)} memories\n---\n#{formatted}"}

      {:error, reason} ->
        {:error, "Memory recall failed: #{inspect(reason)}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp validate_category(nil), do: :ok

  defp validate_category(cat) when is_binary(cat) do
    if cat in Constants.valid_categories() do
      :ok
    else
      valid = Enum.join(Constants.valid_categories(), ", ")
      {:error, "Invalid category #{inspect(cat)}. Must be one of: #{valid}", -32_602}
    end
  end

  defp validate_category(_), do: {:error, "category must be a string", -32_602}

  defp validate_limit(nil), do: :ok
  defp validate_limit(n) when is_integer(n) and n > 0, do: :ok
  defp validate_limit(_), do: {:error, "limit must be a positive integer", -32_602}

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val), do: [{key, val} | opts]
end
