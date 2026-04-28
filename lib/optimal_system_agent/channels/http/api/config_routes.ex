defmodule OptimalSystemAgent.Channels.HTTP.API.ConfigRoutes do
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared, except: [parse_int: 1]

  # OptimalSystemAgent.Governance.ConfigRevisions not yet implemented.
  # All revision endpoints return 501 until the governance module is built.

  plug(:match)
  plug(:dispatch)

  get "/revisions/:entity_type/:entity_id" do
    _ = entity_type
    _ = entity_id
    json_error(conn, 501, "not_implemented", "Config revisions not yet available")
  end

  get "/revisions/:entity_type/:entity_id/:number" do
    _ = entity_type
    _ = entity_id
    _ = number
    json_error(conn, 501, "not_implemented", "Config revisions not yet available")
  end

  post "/revisions/:entity_type/:entity_id/rollback" do
    _ = entity_type
    _ = entity_id
    json_error(conn, 501, "not_implemented", "Config revisions not yet available")
  end

  get "/revisions/:entity_type/:entity_id/diff" do
    _ = entity_type
    _ = entity_id
    json_error(conn, 501, "not_implemented", "Config revisions not yet available")
  end

  match _ do
    json_error(conn, 404, "not_found", "Config route not found")
  end
end
