defmodule CanopyWeb.ChatChannel do
  use Phoenix.Channel

  @impl true
  def join("chat:" <> _session_id, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("message", %{"body" => body}, socket) do
    broadcast!(socket, "message", %{body: body, sender: socket.assigns.user_id})
    {:noreply, socket}
  end
end
