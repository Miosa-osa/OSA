%{
  id: "rename-module",
  title: "Rename a module and move its file",
  category: "refactor",
  failure_mode: "multi-file rename including the file move and the test module",
  prompt: """
  Rename the module Acme.Util.Strings to Acme.Text. Move it to lib/acme/text.ex, update every \
  reference in lib/ and test/, and keep the suite green (elixir scripts/run_tests.exs).
  """,
  check: [
    {:tree_lacks, "{lib,test}/**/*.{ex,exs}", "Util.Strings"},
    {:file_absent, "lib/acme/util/strings.ex"},
    {:file_contains, "lib/acme/text.ex", "defmodule Acme.Text do"},
    {:tests_pass}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "Util\\.Strings", "path" => "$WORKDIR"}}],
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/util/strings.ex"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/invoice.ex"}},
     {"file_read", %{"path" => "$WORKDIR/test/strings_test.exs"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && mv lib/acme/util/strings.ex lib/acme/text.ex"}}],
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/text.ex"}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/text.ex", "old_string" => "defmodule Acme.Util.Strings do", "new_string" => "defmodule Acme.Text do"}},
     {"file_edit", %{"path" => "$WORKDIR/lib/acme/invoice.ex", "old_string" => "  alias Acme.Util.Strings\n", "new_string" => "  alias Acme.Text, as: Strings\n"}},
     {"file_edit", %{"path" => "$WORKDIR/test/strings_test.exs", "old_string" => "defmodule Acme.Util.StringsTest do", "new_string" => "defmodule Acme.TextTest do"}}],
    [{"file_edit", %{"path" => "$WORKDIR/test/strings_test.exs", "old_string" => "  alias Acme.Util.Strings\n", "new_string" => "  alias Acme.Text, as: Strings\n"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Acme.Util.Strings is now Acme.Text in lib/acme/text.ex; references updated; tests pass."}
  ]
}
