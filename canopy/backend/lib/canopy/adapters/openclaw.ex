defmodule Canopy.Adapters.OpenClaw do
  @moduledoc "OpenClaw WebSocket adapter (P2 — placeholder)."
  @behaviour Canopy.Adapter

  @impl true
  def type, do: "openclaw"

  @impl true
  def name, do: "OpenClaw"

  @impl true
  def supports_session?, do: true

  @impl true
  def supports_concurrent?, do: false

  @impl true
  def capabilities, do: [:chat, :tools]

  @impl true
  def start(_config), do: {:ok, %{status: :placeholder}}

  @impl true
  def stop(_), do: :ok

  @impl true
  def execute_heartbeat(_params), do: placeholder_stream()

  @impl true
  def send_message(_session, _message), do: placeholder_stream()

  defp placeholder_stream do
    Stream.resource(
      fn -> :once end,
      fn
        :once ->
          {[
             %{
               event_type: "run.failed",
               data: %{"error" => "OpenClaw adapter not yet implemented"},
               tokens: 0
             }
           ], :done}

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end
end
