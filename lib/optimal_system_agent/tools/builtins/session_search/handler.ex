defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `session_search`.

  Split mirrors `FileRead.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (read-only, no sensitive side effects)
    * `execute/2`           — FTS5-backed search with Memory fallback
  """

  alias OptimalSystemAgent.Tools.Builtins.SessionSearch.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"query" => query} = input, _ctx) when is_binary(query),
    do: {:ok, input}

  def validate(%{"query" => _}, _ctx),
    do: {:error, "query must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: query", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"query" => query} = args, _ctx) do
    limit = args["limit"] || Constants.default_limit()

    results =
      try do
        OptimalSystemAgent.Store.SessionTranscript.search(query, limit: limit)
      rescue
        _ -> []
      end

    results =
      if results == [] do
        case OptimalSystemAgent.Memory.search_sessions(query, limit: limit) do
          {:ok, r} -> r
          _ -> []
        end
      else
        results
      end

    if results == [] do
      {:ok, "No past sessions found matching: #{query}"}
    else
      formatted =
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          highlight = Map.get(result, :highlight)

          content_preview =
            highlight ||
              String.slice(Map.get(result, :content, ""), 0, Constants.content_preview_chars())

          session = Map.get(result, :session_id, "unknown")
          role = Map.get(result, :role, "?")
          ts = Map.get(result, :inserted_at, "")
          "#{idx}. [#{session}] #{role} (#{ts})\n   #{content_preview}"
        end)
        |> Enum.join("\n\n")

      {:ok, "Found #{length(results)} match(es):\n\n#{formatted}"}
    end
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: query"}
end
