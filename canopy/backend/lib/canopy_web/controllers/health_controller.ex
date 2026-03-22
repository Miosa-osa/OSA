defmodule CanopyWeb.HealthController do
  use CanopyWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      version: "1.0.0",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
