---
name: elixir-otp
description: "Write, review, and repair Elixir or Erlang code with verified syntax, exact API arities, OTP lifecycle handling, and executable checks. Use for .ex/.exs, mix.exs, GenServer, supervision, Ecto, Phoenix, and BEAM runtime bugs."
category: development
triggers:
  - "elixir"
  - "erlang"
  - "otp"
  - "genserver"
  - "mix compile"
  - "ecto"
  - "phoenix"
tools:
  - file_read
  - file_grep
  - file_edit
  - file_write
  - shell_execute
  - web_fetch
---

# Elixir and OTP: verify the code path

## Workflow

1. Read the repository instructions, `.tool-versions`, `mix.exs`, and relevant
   existing modules/tests. Use its matched Elixir/OTP pair; run `elixir --version`
   and `mix --version`. Do not hardcode another developer's installation path.
2. Read [syntax and API examples](references/syntax.md) for matching, guards,
   strings, maps, pipes, and error handling. Read [OTP and integration
   pitfalls](references/gotchas.md) for servers, tasks, configuration, and Ecto.
3. Verify external calls against the installed dependency source or its pinned
   HexDocs version. `Code.ensure_loaded!/1` followed by `function_exported?/3`
   checks functions; use `macro_exported?/3` for macros. A missing module is not
   evidence that its documented API does not exist.
4. Write the smallest implementation following the project's conventions.
   Use explicit success/error return contracts at boundaries, validate external
   data, and keep arbitrary input as strings rather than creating atoms.
5. Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, and the
   narrowest relevant `mix test test/path_test.exs`. Existing unrelated warnings
   must be reported accurately; a plain compile is not a warning-free check.
6. Exercise both success and failure paths. For OTP changes test the actual
   process, message ordering, timeout, and shutdown behavior. For persistence,
   assert a reread observes the change. A mock or compilation alone is not that
   evidence. Finish by reporting exact commands, outcomes, and uncovered cases.

## Snippet verification

From this skill directory, run:

```bash
elixir references/verify_snippets.exs SKILL.md references/syntax.md references/gotchas.md
```

The verifier accepts trusted author-written snippets only; it executes code and
is not a sandbox for user-supplied programs. It requires Elixir 1.17 or newer.
`elixir` fences compile with no undefined-call warnings; `elixir-run` also calls
`run/0` on defined modules (or executes a wrapped expression); `elixir-bad` must
fail compilation or emit an undefined-call warning. Runtime examples contain
assertions, so printing a plausible result is not considered success. Fences
must be self-contained; do not depend on definitions in a previous fence.

Compile success checks syntax and some static diagnostics. It does not prove
that callbacks return valid tuples, external services respond, database writes
persist, or all runtime matches succeed. Run the tests that establish those
claims before presenting code as complete.

## Sources

Use the dependency version selected by the repository when reading these docs:

- [Elixir 1.17 documentation](https://hexdocs.pm/elixir/1.17.3/Kernel.html)
- [GenServer callbacks](https://hexdocs.pm/elixir/1.17.3/GenServer.html)
- [Ecto changesets](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Erlang reference manual](https://www.erlang.org/doc/system/reference_manual.html)
