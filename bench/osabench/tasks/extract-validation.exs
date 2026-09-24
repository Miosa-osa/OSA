%{
  id: "extract-validation",
  title: "Extract duplicated validation into one module",
  category: "refactor",
  failure_mode: "long multi-step refactor: create a module, rewrite three callers, verify",
  prompt: """
  The same email regex is copy-pasted in lib/acme/users.ex, lib/acme/accounts.ex and \
  lib/acme/newsletter.ex. Extract it into a new module Acme.Validation (lib/acme/validation.ex) \
  with a function valid_email?/1, make all three use it, and keep the suite green \
  (elixir scripts/run_tests.exs). The regex literal should appear exactly once in lib/.
  """,
  check: [
    {:file_contains, "lib/acme/validation.ex", "def valid_email?("},
    {:tree_count, "lib/**/*.ex", "[a-z]{2,}$/i", 1},
    {:file_contains, "lib/acme/users.ex", "valid_email?("},
    {:file_contains, "lib/acme/accounts.ex", "valid_email?("},
    {:file_contains, "lib/acme/newsletter.ex", "valid_email?("},
    {:tests_pass}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/users.ex"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/accounts.ex"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/newsletter.ex"}}],
    [{"file_write", %{"path" => "$WORKDIR/lib/acme/validation.ex", "content" => """
    defmodule Acme.Validation do
      @moduledoc "Shared input validation."

      @email ~r/^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$/i

      def valid_email?(email) when is_binary(email), do: Regex.match?(@email, email)
      def valid_email?(_), do: false
    end
    """}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/users.ex", "old_string" => "Regex.match?(~r/^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$/i, email)", "new_string" => "Acme.Validation.valid_email?(email)"}},
     {"file_edit", %{"path" => "$WORKDIR/lib/acme/accounts.ex", "old_string" => "Regex.match?(~r/^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$/i, email)", "new_string" => "Acme.Validation.valid_email?(email)"}},
     {"file_edit", %{"path" => "$WORKDIR/lib/acme/newsletter.ex", "old_string" => "Regex.match?(~r/^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$/i, email)", "new_string" => "Acme.Validation.valid_email?(email)"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Added Acme.Validation.valid_email?/1 and switched users, accounts and newsletter to it; tests pass."}
  ]
}
