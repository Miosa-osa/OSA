defmodule Acme.Http.Client do
  @moduledoc "Outbound HTTP. Reads its timeout from config/settings.json."

  def timeout(settings), do: Map.fetch!(settings, "request_timeout_ms")
end
