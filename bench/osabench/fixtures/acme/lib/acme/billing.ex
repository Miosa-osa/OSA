defmodule Acme.Billing do
  @moduledoc "Pricing."

  alias Acme.Order

  @doc "Total of an order in cents."
  def calc_total(%Order{items: items}) do
    total = Enum.reduce(items, 0, fn {_name, cents, qty}, acc -> acc + cents * qty end)
    Acme.Metrics.emit("billing.total", total)
    total
  end

  @doc "Formats cents as dollars, e.g. 1234 -> \"12.34\"."
  def format_cents(cents) do
    dollars = div(cents, 100)
    rest = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{dollars}.#{rest}"
  end
end
