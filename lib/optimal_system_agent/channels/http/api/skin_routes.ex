defmodule OptimalSystemAgent.Channels.HTTP.API.SkinRoutes do
  @moduledoc "HTTP API for skin/theme management."
  use Plug.Router

  alias OptimalSystemAgent.Skin.{Engine, Schema}

  plug(:match)
  plug(:dispatch)

  get "/" do
    skin = Engine.active_skin()
    json(conn, 200, Schema.to_json(skin))
  end

  get "/list" do
    skins = Engine.list_skins()
    json(conn, 200, %{"skins" => skins})
  end

  put "/" do
    case conn.body_params do
      %{"name" => name} when is_binary(name) ->
        case Engine.set_active(name) do
          :ok ->
            skin = Engine.active_skin()
            json(conn, 200, Schema.to_json(skin))

          {:error, reason} ->
            json(conn, 400, %{"error" => reason})
        end

      _ ->
        json(conn, 400, %{"error" => "Missing required field: name"})
    end
  end

  post "/reload" do
    Engine.reload()
    json(conn, 200, %{"status" => "reloaded"})
  end

  match _ do
    json(conn, 404, %{"error" => "Not found"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
