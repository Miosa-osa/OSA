defmodule OptimalSystemAgent.Channels.HTTP.CacheBodyReader do
  @moduledoc """
  A `Plug.Parsers` `:body_reader` that caches the raw request body bytes in
  `conn.assigns[:raw_body]` while still handing them to the JSON parser.

  Webhook signature verification (Slack, Signal, LINE, WhatsApp) and the
  `Integrity` HMAC plug must hash the EXACT bytes the platform signed. Re-encoding
  `conn.body_params` produces different bytes (key order, spacing, unicode
  escaping) and the HMAC never matches. Configure every `Plug.Parsers` with:

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {OptimalSystemAgent.Channels.HTTP.CacheBodyReader, :read_body, []}
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, update_in(conn.assigns[:raw_body], &((&1 || "") <> body))}

      {:more, body, conn} ->
        {:more, body, update_in(conn.assigns[:raw_body], &((&1 || "") <> body))}

      other ->
        other
    end
  end
end
