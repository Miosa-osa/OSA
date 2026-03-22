defmodule CanopyWeb.Plugs.Auth do
  @moduledoc "JWT authentication plug."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Canopy.Guardian.decode_and_verify(token),
         {:ok, user} <- Canopy.Guardian.resource_from_claims(claims) do
      conn
      |> assign(:current_user, user)
      |> assign(:claims, claims)
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "unauthorized", code: "INVALID_TOKEN"})
        |> halt()
    end
  end
end
