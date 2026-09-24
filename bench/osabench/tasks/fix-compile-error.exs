%{
  id: "fix-compile-error",
  title: "The suite does not even load",
  category: "fix",
  failure_mode: "read the compiler's own error instead of searching the tree",
  prompt: "elixir scripts/run_tests.exs fails before running any test. Fix it.",
  setup: [
    {:replace, "lib/acme/legacy.ex", "  def old_format(id), do: \"#\" <> Integer.to_string(id)\n",
     "  def old_format(id) do\n    \"#\" <> Integer.to_string(id)\n"}
  ],
  check: [
    {:tests_pass}
  ],
  reference: [
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/legacy.ex"}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/legacy.ex",
                     "old_string" => "    \"#\" <> Integer.to_string(id)\n",
                     "new_string" => "    \"#\" <> Integer.to_string(id)\n  end\n"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "old_format/1 was missing its `end`; the suite loads and passes."}
  ]
}
