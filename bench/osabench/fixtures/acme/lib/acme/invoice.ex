defmodule Acme.Invoice do
  @moduledoc "Plain-text invoices."

  alias Acme.{Billing, Legacy, Order}
  alias Acme.Util.Strings

  def render(%Order{} = order) do
    total = Billing.calc_total(order)
    Acme.Metrics.emit("invoice.rendered", 1)

    [
      "Invoice #{Legacy.new_format(order.id)}",
      "Customer: #{Strings.titlecase(order.customer)}",
      "Total: $#{Billing.format_cents(total)}"
    ]
    |> Enum.join("\n")
  end
end
