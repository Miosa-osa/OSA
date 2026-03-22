defmodule CanopyWeb.PresenceChannel do
  use Phoenix.Channel

  @impl true
  def join("presence:" <> _workspace_id, _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:noreply, socket}
  end
end
