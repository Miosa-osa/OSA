%{
  id: "rename-function",
  title: "Rename a function across files",
  category: "refactor",
  failure_mode: "find every call site in one search, edit each, verify once",
  prompt: "Rename Acme.Billing.calc_total/1 to compute_total/1 everywhere in lib/ and test/. Keep the suite green (elixir scripts/run_tests.exs).",
  check: [
    {:tree_lacks, "{lib,test}/**/*.{ex,exs}", "calc_total"},
    {:file_contains, "lib/acme/billing.ex", "def compute_total("},
    {:tests_pass}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "calc_total", "path" => "$WORKDIR"}}],
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/billing.ex"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/invoice.ex"}},
     {"file_read", %{"path" => "$WORKDIR/test/billing_test.exs"}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/billing.ex", "old_string" => "def calc_total(", "new_string" => "def compute_total("}},
     {"file_edit", %{"path" => "$WORKDIR/lib/acme/invoice.ex", "old_string" => "Billing.calc_total(", "new_string" => "Billing.compute_total("}},
     {"file_edit", %{"path" => "$WORKDIR/test/billing_test.exs", "old_string" => "test \"calc_total sums", "new_string" => "test \"compute_total sums"}}],
    [{"file_edit", %{"path" => "$WORKDIR/test/billing_test.exs", "old_string" => "Billing.calc_total(order)", "new_string" => "Billing.compute_total(order)"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Renamed calc_total/1 to compute_total/1 in billing.ex, invoice.ex and billing_test.exs; tests pass."}
  ]
}
