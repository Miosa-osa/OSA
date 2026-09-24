defmodule Acme.BillingTest do
  use ExUnit.Case, async: true

  alias Acme.{Billing, Order}

  test "calc_total sums cents times quantity" do
    order = Order.new(%{id: 1, items: [{"pen", 150, 2}, {"pad", 300, 1}]})
    assert Billing.calc_total(order) == 600
  end

  test "format_cents pads the cents" do
    assert Billing.format_cents(1205) == "12.05"
  end
end
