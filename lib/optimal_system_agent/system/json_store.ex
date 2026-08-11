defmodule OptimalSystemAgent.System.JsonStore do
  @moduledoc """
  The one presence-aware read used by every JSON store that is later written
  back whole.

  ## The failure this exists to prevent

  A whole-file rewrite derived from a degraded read is a wipe. The shape that
  keeps reappearing is:

      existing =
        case File.read(path) do
          {:ok, raw} -> case Jason.decode(raw) do
                          {:ok, m} when is_map(m) -> m
                          _ -> %{}        # <-- here
                        end
          _ -> %{}                        # <-- and here
        end

      File.write!(path, Jason.encode!(Map.put(existing, key, value)))

  One BOM, one trailing comma, one truncated write from a previous crash, one
  `EACCES` — and the very next add rewrites the file containing ONLY the new
  entry. Every MCP server, every permission rule, every cron job, every stored
  API key: gone, with the operation reporting success.

  The distinction that matters is **absent vs. unreadable**:

    * absent (or empty) → `{:ok, %{}}`. A fresh start is legitimate; the first
      write creating the file is correct.
    * present but unparseable, or present but unreadable → `{:error, :corrupt}`.
      There is data here that we failed to understand. Refuse the write and say
      so. A store we cannot read is a store we must not overwrite.

  Callers must surface `{:error, :corrupt}` rather than swallowing it — the
  user needs to know their store needs attention, and needs their old entries
  still on disk when they go look.

  Pair this with `OptimalSystemAgent.System.AtomicFile` for the write half:
  this module stops a good file being replaced by a partial one, `AtomicFile`
  stops a good file being replaced by a half-written one.
  """

  @type reason :: :corrupt

  @doc """
  Read a JSON object for a read-modify-write cycle.

  Returns `{:ok, map}` when the file is missing, empty, or a valid JSON object.
  Returns `{:error, :corrupt}` when the file exists but is not readable as a
  JSON object — including non-object top-level JSON, which no caller of this
  function can merge into.
  """
  @spec read_map_for_write(Path.t()) :: {:ok, map()} | {:error, reason()}
  def read_map_for_write(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            {:ok, map}

          _ ->
            if String.trim(content) == "", do: {:ok, %{}}, else: {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, :corrupt}
    end
  end

  @doc """
  Read a list nested under `key` in a JSON object, for a read-modify-write
  cycle — the `%{"jobs" => [...]}` / `%{"triggers" => [...]}` shape.

  Returns `{:ok, list}` when the file is missing/empty (`[]`), or when `key`
  holds a list. A valid object that simply lacks `key` yields `{:ok, []}`.
  Returns `{:error, :corrupt}` when the file is unreadable/unparseable, or when
  `key` is present but is not a list.
  """
  @spec read_list_for_write(Path.t(), String.t()) :: {:ok, list()} | {:error, reason()}
  def read_list_for_write(path, key) when is_binary(path) and is_binary(key) do
    with {:ok, map} <- read_map_for_write(path) do
      case Map.fetch(map, key) do
        {:ok, list} when is_list(list) -> {:ok, list}
        :error -> {:ok, []}
        _ -> {:error, :corrupt}
      end
    end
  end

  @doc """
  A uniform, user-facing refusal message for `{:error, :corrupt}`.

  `what` names the store in the user's terms ("MCP config", "permission
  rules"). The message deliberately says nothing was written, because the point
  of refusing is that the old contents are still there to recover.
  """
  @spec corrupt_message(String.t(), Path.t()) :: String.t()
  def corrupt_message(what, path) do
    "Refusing to write #{what}: #{path} exists but could not be read as JSON. " <>
      "Nothing was changed — overwriting it would discard every entry already " <>
      "stored there. Repair or move the file, then retry."
  end
end
