defmodule Canopy.Adapters.Gemini do
  @moduledoc "Gemini CLI adapter (P2 — placeholder)."
  @behaviour Canopy.Adapter

  @impl true
  def type, do: "gemini"

  @impl true
  def name, do: "Gemini CLI"

  @impl true
  def supports_session?, do: true

  @impl true
  def supports_concurrent?, do: true

  @impl true
  def capabilities, do: [:chat, :code_execution]

  @impl true
  def start(_config), do: {:ok, %{status: :placeholder}}

  @impl true
  def stop(_), do: :ok

  @impl true
  def execute_heartbeat(_params), do: stub_stream()

  @impl true
  def send_message(_session, _message), do: stub_stream()

  defp stub_stream do
    Stream.resource(
      fn -> :once end,
      fn
        :once ->
          {[
             %{
               event_type: "run.failed",
               data: %{"error" => "Gemini adapter not yet implemented"},
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
