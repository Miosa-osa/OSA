defmodule Acme.Metrics do
  @moduledoc "Counters. A no-op sink in this build."

  def emit(_name, _value), do: :ok
end
