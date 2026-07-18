defmodule OptimalSystemAgent.Channels.HTTP.API.PermissionRulesRoutes do
  @moduledoc """
  Read-only permission-rule introspection route (CC-parity, WS3).

  Forwarded prefix: /permission-rules

  Effective route:
    GET /  (forwarded as GET /)
      Exposes `OptimalSystemAgent.Permissions.rules/0` — every permission rule
      from the settings cascade plus the legacy store, in evaluation-priority
      order (session → flag → local → project → user → legacy).

  Response shape:

      {"rules": [
        {"behavior": "allow" | "deny" | "ask",
         "rule": "Tool(content)",
         "source": "session" | "flag" | "local" | "project" | "user" | "legacy"}
      ]}

  `behavior` and `source` are atoms in the source map and are stringified here
  so the TUI receives clean strings. On any failure the endpoint returns 200
  with an empty list (never 500s the TUI).

  NOTE for the integrator: `/permissions` is already forwarded to
  `API.ToolRoutes` (POST /permissions/respond — the interactive round-trip),
  so this read route mounts at `/permission-rules` to avoid the overlap.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — all permission rules with provenance ─────────────────────

  get "/" do
    rules =
      try do
        OptimalSystemAgent.Permissions.rules()
        |> Enum.map(fn %{behavior: behavior, rule: rule, source: source} ->
          %{
            behavior: stringify(behavior),
            rule: rule,
            source: stringify(source)
          }
        end)
      rescue
        e ->
          Logger.warning(
            "[PermissionRulesRoutes] Failed to load permission rules: #{Exception.message(e)}"
          )

          []
      catch
        :exit, _ -> []
      end

    json(conn, 200, %{rules: rules})
  end

  # ── catch-all ────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Permission-rules endpoint not found")
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp stringify(nil), do: nil
  defp stringify(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify(other), do: other
end