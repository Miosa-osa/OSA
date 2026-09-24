defmodule Acme.Order do
  @moduledoc "An order: an id, a customer and line items of {name, cents, qty}."

  defstruct id: nil, customer: nil, items: []

  def new(attrs) do
    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      customer: Map.get(attrs, :customer, "anonymous"),
      items: Map.get(attrs, :items, [])
    }
  end
end
