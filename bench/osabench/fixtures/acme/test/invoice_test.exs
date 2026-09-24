defmodule Acme.InvoiceTest do
  use ExUnit.Case, async: true

  alias Acme.{Invoice, Order}

  test "render shows number, customer and total" do
    order = Order.new(%{id: 42, customer: "ada lovelace", items: [{"pen", 150, 2}]})
    text = Invoice.render(order)

    assert text =~ "Invoice INV-000042"
    assert text =~ "Customer: Ada Lovelace"
    assert text =~ "Total: $3.00"
  end
end
