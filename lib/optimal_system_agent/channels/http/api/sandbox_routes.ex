defmodule OptimalSystemAgent.Channels.HTTP.API.SandboxRoutes do
  @moduledoc """
  Sandbox backend introspection routes for the OSA HTTP API.

  Forwarded prefix: /sandboxes

  Effective routes:
    GET /  (forwarded as GET /sandboxes)
      Lists every registered sandbox execution backend with its display name
      and live availability, marks the currently-selected backend, and reports
      the enforcement mode. Sourced from `Sandbox.Router.list_backends/0`,
      `Sandbox.Router.backend/0`, and `Sandbox.Router.mode/0`.

      Atom values (names, mode) are stringified so the TUI receives clean JSON.
      No modules/PIDs are exposed. On any failure the call is wrapped in
      try/rescue and returns an empty backend list — the endpoint never 500s.

      Shape:
        {
          "backends": [
            {
              "name": "miosa",
              "display_name": "MIOSA Platform",
              "available": true,
              "current": true
            }
          ],
          "current": "miosa",
          "mode": "optional"
        }
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Sandbox.Router, as: SandboxRouter

  plug(:match)
  plug(:dispatch)

  # ── GET / — list sandbox backends + current + mode ──────────────────

  get "/" do
    payload =
      try do
        current_mod = SandboxRouter.backend()

        backends =
          SandboxRouter.list_backends()
          |> Enum.map(&serialize_backend(&1, current_mod))

        current =
          Enum.find_value(backends, fn b -> if b.current, do: b.name end)

        %{backends: backends, current: current, mode: stringify(SandboxRouter.mode())}
      rescue
        e ->
          Logger.warning("[SandboxRoutes] Failed to list backends: #{Exception.message(e)}")
          %{backends: [], current: nil, mode: nil}
      catch
        :exit, _ -> %{backends: [], current: nil, mode: nil}
      end

    json(conn, 200, payload)
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Sandbox endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # Normalize a backend map from list_backends/0 into a clean, JSON-safe map.
  # `name` is an atom and must be stringified; `module` is dropped (never
  # exposed). `current` compares the entry's module against the active one.
  defp serialize_backend(%{module: mod} = backend, current_mod) do
    %{
      name: stringify(backend[:name]),
      display_name: display_name(backend[:display_name]),
      available: backend[:available] == true,
      current: mod == current_mod
    }
  end

  defp serialize_backend(backend, _current_mod) when is_map(backend) do
    %{
      name: stringify(backend[:name]),
      display_name: display_name(backend[:display_name]),
      available: backend[:available] == true,
      current: false
    }
  end

  defp display_name(name) when is_binary(name), do: name
  defp display_name(nil), do: nil
  defp display_name(name), do: to_string(name)

  # Stringify atom values (nil-safe) so the TUI never sees raw atoms.
  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)
end
