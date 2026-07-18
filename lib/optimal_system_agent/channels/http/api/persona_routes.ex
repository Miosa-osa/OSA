defmodule OptimalSystemAgent.Channels.HTTP.API.PersonaRoutes do
  @moduledoc """
  Personality-preset introspection routes for the OSA HTTP API.

  Forwarded prefix: /personas

  Effective routes:
    GET /  (forwarded as GET /) — all switchable personality presets + the
                                  currently-active one.

  Response shape:

      {
        "personas": [
          {"name": "architect", "display": "Architect",
           "description": "Big picture, trade-offs, system thinking"},
          ...
        ],
        "current": "default"
      }

  Backs the TUI `/persona` picker. `Personality.list/0` returns preset maps
  keyed by atoms (`:name`, `:display`, `:description`, `:overlay`); we project
  to the string-keyed subset the picker needs and drop `:overlay` so the full
  system-prompt text never reaches the client. On any failure the call is
  wrapped in try/rescue and returns an empty list — the endpoint never 500s.
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Personality

  plug(:match)
  plug(:dispatch)

  # ── GET / — presets + active preset ─────────────────────────────────

  get "/" do
    {personas, current} =
      try do
        {project_personas(Personality.list()), to_string(Personality.current())}
      rescue
        _ -> {[], "default"}
      catch
        :exit, _ -> {[], "default"}
      end

    json(conn, 200, %{personas: personas, current: current})
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Persona endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # Project each preset map to the string-keyed, overlay-free JSON shape.
  defp project_personas(presets) when is_list(presets) do
    Enum.map(presets, fn preset ->
      %{
        name: to_string(Map.get(preset, :name, "")),
        display: to_string(Map.get(preset, :display, Map.get(preset, :name, ""))),
        description: to_string(Map.get(preset, :description, ""))
      }
    end)
  end

  defp project_personas(_), do: []
end
