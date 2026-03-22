defmodule CanopyWeb.Plugs.ErrorHandler do
  @moduledoc "Catches unhandled exceptions and returns JSON error responses."
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
  rescue
    _e in Ecto.NoResultsError ->
      conn |> put_status(404) |> json_error("not_found", "Resource not found")

    _e in Ecto.Query.CastError ->
      conn |> put_status(400) |> json_error("invalid_id", "Invalid ID format")

    _e in Phoenix.Router.NoRouteError ->
      conn |> put_status(404) |> json_error("not_found", "Endpoint not found")

    e ->
      Logger.error(
        "[ErrorHandler] Unhandled: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      conn |> put_status(500) |> json_error("internal_error", Exception.message(e))
  end

  defp json_error(conn, code, message) do
    body = Jason.encode!(%{error: code, details: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 500, body)
    |> halt()
  end
end
