defmodule OptimalSystemAgent.Observability.OTel.Noop do
  @moduledoc """
  Default no-op OpenTelemetry adapter.

  Used whenever OTLP GenAI export is disabled (the default) or no exporter is
  configured. Every callback is a cheap `:ok` so the seam has zero runtime cost
  until a real exporter is wired in.
  """
  @behaviour OptimalSystemAgent.Observability.OTel

  @impl true
  def on_gen_ai(_operation, _attributes), do: :ok
end
