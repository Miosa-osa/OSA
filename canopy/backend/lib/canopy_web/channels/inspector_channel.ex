defmodule CanopyWeb.InspectorChannel do
  use Phoenix.Channel

  @impl true
  def join("inspector:" <> _session_id, _payload, socket) do
    {:ok, socket}
  end
end
