defmodule CanopyWeb.UserSocket do
  use Phoenix.Socket

  channel "chat:*", CanopyWeb.ChatChannel
  channel "inspector:*", CanopyWeb.InspectorChannel
  channel "presence:*", CanopyWeb.PresenceChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Canopy.Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        {:ok, assign(socket, :user_id, claims["sub"])}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
