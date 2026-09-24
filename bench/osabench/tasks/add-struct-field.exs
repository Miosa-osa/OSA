%{
  id: "add-struct-field",
  title: "Thread a new field through three layers",
  category: "refactor",
  failure_mode: "multi-step change checked by a hidden test",
  prompt: """
  Add a currency to orders: Acme.Order gets a :currency field that Acme.Order.new/1 reads from \
  attrs (default "USD"), and Acme.Invoice.render/1 prints the total as "Total: $3.00 USD" (the \
  order's currency after the amount). Update test/invoice_test.exs for the new output and keep \
  the suite green (elixir scripts/run_tests.exs).
  """,
  check: [
    {:tests_pass},
    {:command, "elixir", ["-e", """
    root = File.cwd!()
    files = root |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.sort()
    {:ok, _, _} = Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
    o = Acme.Order.new(%{id: 7, customer: "bo", items: [{"a", 250, 2}], currency: "EUR"})
    "EUR" = o.currency
    "USD" = Acme.Order.new(%{id: 8}).currency
    true = String.contains?(Acme.Invoice.render(o), "Total: $5.00 EUR")
    """]}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/order.ex"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/invoice.ex"}},
     {"file_read", %{"path" => "$WORKDIR/test/invoice_test.exs"}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/order.ex", "old_string" => "defstruct id: nil, customer: nil, items: []", "new_string" => "defstruct id: nil, customer: nil, items: [], currency: \"USD\""}},
     {"file_edit", %{"path" => "$WORKDIR/lib/acme/invoice.ex", "old_string" => "\"Total: $\#{Billing.format_cents(total)}\"", "new_string" => "\"Total: $\#{Billing.format_cents(total)} \#{order.currency}\""}},
     {"file_edit", %{"path" => "$WORKDIR/test/invoice_test.exs", "old_string" => "assert text =~ \"Total: $3.00\"", "new_string" => "assert text =~ \"Total: $3.00 USD\""}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/order.ex", "old_string" => "      items: Map.get(attrs, :items, [])\n", "new_string" => "      items: Map.get(attrs, :items, []),\n      currency: Map.get(attrs, :currency, \"USD\")\n"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Orders carry a currency (default USD) and invoices print it after the total; tests pass."}
  ]
}
