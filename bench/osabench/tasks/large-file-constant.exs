%{
  id: "large-file-constant",
  title: "Read one constant out of a large generated module",
  category: "search",
  failure_mode: "paging through a large file instead of a targeted search",
  prompt: "What is the value of @max_batch_size in lib/acme/generated/tables.ex? Reply with just the number.",
  setup: [
    {:large_file, "lib/acme/generated/tables.ex", 8_000,
     "  def rate({{n}}), do: {{n}}",
     %{1 => "defmodule Acme.Generated.Tables do",
       2 => "  @moduledoc false",
       6_417 => "  @max_batch_size 1337",
       6_418 => "  def max_batch_size, do: @max_batch_size",
       8_000 => "end"}}
  ],
  check: [
    {:answer_matches, ~r/\b1337\b/}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "@max_batch_size", "path" => "$WORKDIR/lib/acme/generated/tables.ex"}}],
    {:answer, "1337"}
  ]
}
