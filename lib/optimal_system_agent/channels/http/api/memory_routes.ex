defmodule OptimalSystemAgent.Channels.HTTP.API.MemoryRoutes do
  @moduledoc """
  Read-only listing of persistent agent memory for the TUI `/memory` browser.

  The existing `/memory` prefix (DataRoutes) exposes `GET /recall` (a single
  joined string) and `GET /search` (keyword results), but there is no clean
  "list every stored memory entry" endpoint — `GET /memory` there actually
  falls through to the models handler. This module fills that gap under its own
  prefix so nothing existing is disturbed.

  Forwarded prefix (integrator-wired): /memories

  Effective routes:
    GET /  (forwarded as GET /) — the most-recent memory entries, newest first

  Response shape:

      {
        "entries": [
          {
            "id": "mem_...",
            "content": "User always prefers tabs over spaces",
            "category": "preference",
            "scope": "global",
            "source": "user",
            "description": null,
            "tags": ["style"],
            "relevance": 0.8,
            "created_at": "2026-07-16 09:00:00"
          },
          ...
        ],
        "count": N
      }

  Data comes from `OptimalSystemAgent.Memory.recent/1` (Ecto/SQLite store).
  Each entry map (see `Memory.Store.struct_to_map/1`) is projected to a stable,
  JSON-safe subset here: atoms/structs are stringified so `created_at` and the
  category/scope atoms never leak as non-JSON terms. The whole read is wrapped
  in try/rescue/catch and degrades to an empty list — the endpoint never 500s
  the TUI.
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Memory

  plug(:match)
  plug(:dispatch)

  # Cap the listing so a large store can't produce an unbounded payload.
  @limit 200

  # ── GET / — recent memory entries, newest first ─────────────────────

  get "/" do
    entries = list_entries()
    json(conn, 200, %{entries: entries, count: length(entries)})
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Memory endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp list_entries do
    case Memory.recent(@limit) do
      {:ok, entries} when is_list(entries) -> Enum.map(entries, &present/1)
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Project a store entry map (atom keys) down to the JSON-safe subset the
  # browser renders. Reads are lenient about atom vs string keys just in case.
  defp present(entry) when is_map(entry) do
    %{
      id: stringify(fetch(entry, :id)),
      content: stringify(fetch(entry, :content)),
      category: stringify(fetch(entry, :category)),
      scope: stringify(fetch(entry, :scope)),
      source: stringify(fetch(entry, :source)),
      description: stringify(fetch(entry, :description)),
      tags: tags(fetch(entry, :tags)),
      relevance: number(fetch(entry, :relevance)),
      created_at: stringify(fetch(entry, :created_at))
    }
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: to_string(v)

  defp tags(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp tags(_), do: []

  defp number(v) when is_number(v), do: v
  defp number(_), do: nil
end
