defmodule Canopy.Adapters.Cursor do
  @moduledoc "Cursor background agent adapter (P2 — placeholder)."
  @behaviour Canopy.Adapter

  @impl true
  def type, do: "cursor"

  @impl true
  def name, do: "Cursor"

  @impl true
  def supports_session?, do: true

  @impl true
  def supports_concurrent?, do: false

  @impl true
  def capabilities, do: [:chat, :code_execution, :file_edit]

  @impl true
  def start(_config), do: {:ok, %{status: :placeholder}}

  @impl true
  def stop(_), do: :ok

  @impl true
  def execute_heartbeat(_params), do: stub_stream("Cursor")

  @impl true
  def send_message(_session, _message), do: stub_stream("Cursor")

  defp stub_stream(name) do
    Stream.resource(
      fn -> :once end,
      fn
        :once ->
          {[
             %{
               event_type: "run.failed",
               data: %{"error" => "#{name} adapter not yet implemented"},
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
