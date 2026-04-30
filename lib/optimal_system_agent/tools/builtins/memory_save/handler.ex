defmodule OptimalSystemAgent.Tools.Builtins.MemorySave.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `memory_save`.

  Split:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — category allowlist check
    * `execute/2`           — delegates to `OptimalSystemAgent.Memory.save/2`

  Logic moved verbatim from the original `memory_save.ex`. No semantic
  changes in Phase 1 — just relocation + the validate/check_permissions split.
  """

  alias OptimalSystemAgent.Tools.Builtins.MemorySave.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"content" => content} = input, _ctx) when is_binary(content) and content != "" do
    case input["category"] do
      nil ->
        {:ok, input}

      cat when is_binary(cat) ->
        if cat in Constants.valid_categories() do
          {:ok, input}
        else
          valid = Enum.join(Constants.valid_categories(), ", ")
          {:error, "Invalid category #{inspect(cat)}. Must be one of: #{valid}", -32_602}
        end

      _ ->
        {:error, "category must be a string", -32_602}
    end
  end

  def validate(%{"content" => ""}, _ctx),
    do: {:error, "content must not be empty", -32_602}

  def validate(%{"content" => _}, _ctx),
    do: {:error, "content must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: content", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx) do
    # Memory saves are always permitted — the agent writes to its own store.
    {:allow, input}
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"content" => content} = args, _ctx) do
    opts =
      []
      |> maybe_add(:category, args["category"])
      |> maybe_add(:tags, args["tags"])
      |> maybe_add(:session_id, args["__session_id__"])

    case OptimalSystemAgent.Memory.save(content, opts) do
      {:ok, entry} ->
        link_count = count_links(entry)
        link_info = if link_count > 0, do: " · linked to #{link_count} memories", else: ""
        {:ok, "Saved · #{entry.category} (#{entry.scope})#{link_info}\n#{content}"}

      {:error, :duplicate} ->
        {:ok, "Already saved · memory exists with same content"}

      {:error, reason} ->
        {:error, "Failed to save memory: #{inspect(reason)}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val), do: [{key, val} | opts]

  defp count_links(%{links: links}) when is_binary(links) do
    case Jason.decode(links) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp count_links(_), do: 0
end
