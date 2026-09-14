# Syntax and API examples

Each fenced example is self-contained. Run the verifier from the skill root.

## Matching, guards, and defaults

A bare variable binds; `^expected` matches an existing binding. Guards accept
only guard-safe operations. Function heads clarify dispatch but `case` inside
a function is also valid. `%{}` matches any map, including structs; check
`map_size/1` when you mean an empty map. Declare defaults once for multi-clause
functions.

```elixir-run
defmodule SkillSyntaxMatching do
  def classify(value, fallback \\ :other)
  def classify(%{count: count}, _) when is_integer(count) and count > 0, do: :positive
  def classify(_, fallback), do: fallback

  def run do
    expected = 42
    ^expected = 42
    :positive = classify(%{count: 1})
    :other = classify(%{})
    %{a: 1} = Map.filter(%{a: 1, b: 2}, fn {_key, value} -> value == 1 end)
    :ok
  end
end
```

```elixir-bad
defmodule SkillSyntaxBadGuard do
  def check(map) when Map.get(map, :size) > 10, do: :large
end
```

## Failure contracts: with, case, cond, and if

An unmatched `<-` returns its value when `with` has no `else`; this can be an
intentional error-tuple contract. An unmatched `=` raises. If `else` is present,
it must cover the possible unmatched values or `WithClauseError` is raised.
`case` and `cond` can raise if no clause matches; `if` without `else` returns nil.
Handle the states your boundary accepts rather than adding catch-alls blindly.

```elixir-run
defmodule SkillSyntaxParse do
  def count(text) do
    with {number, ""} <- Integer.parse(text),
         true <- number >= 0 do
      {:ok, number}
    else
      false -> {:error, :negative}
      :error -> {:error, :invalid}
      {_number, _rest} -> {:error, :trailing_data}
    end
  end

  def run do
    {:ok, 4} = count("4")
    {:error, :negative} = count("-1")
    {:error, :invalid} = count("abc")
    {:error, :trailing_data} = count("4x")
  end
end
```

## Map keys, keyword options, and structs

Decoded JSON normally uses string keys. `map.key` uses an atom key and raises
when absent; `map["key"]` and `Map.get/3` support string keys. Keyword options
are ordered lists; use `Keyword.fetch!/2` rather than positional list matching.
Structs do not implement Access by default; use `struct.field` or `Map.get/2`.
`struct/2` silently discards unknown keys; validate external input first.

```elixir-run
map = %{"a" => 1, b: 2}
1 = map["a"]
nil = map[:a]
2 = map.b
3 = Keyword.fetch!([timeout: 100, retries: 3], :retries)
```

## Strings, charlists, bitstrings, and Erlang calls

Strings are UTF-8 binaries. Charlists contain Unicode codepoints. Check the
specific Erlang API: many accept binaries as well as lists. Use exact module
names, arities, and accepted argument types rather than guessing.

```elixir-run
true = is_binary("abc")
true = is_list(~c"abc")
5 = String.length("héllo")
5 = length(~c"héllo")
6 = byte_size("héllo")
32 = byte_size(:crypto.hash(:sha256, "abc"))
32 = byte_size(:crypto.mac(:hmac, :sha256, "key", "data"))
<<size::32, rest::binary>> = <<5::32, "hello">>
5 = size
"hello" = rest
```

## Pipes and collection APIs

A pipe supplies the first argument. Confirm signatures before piping. Use a
capture or `then/2` for a different position. Prepend during list accumulation
and reverse once instead of repeatedly appending a growing list.

```elixir-run
"a,b" = [" a ", "", "b"] |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(",")
[1, 2] = Enum.uniq([1, 1, 2])
[3, 2, 1] = Enum.reduce([1, 2, 3], [], fn value, acc -> [value | acc] end)
```

## API existence and safe external values

Versioned docs and loaded modules are the oracle. `Map.filter/2` exists on this
project's Elixir 1.17 baseline. `Enum.uniq/1` deduplicates; `List.uniq/1` is not
an API. A blanket list of nonexistent names quickly becomes stale.

```elixir-run
Code.ensure_loaded!(Map)
true = function_exported?(Map, :filter, 2)
Code.ensure_loaded!(Kernel)
true = macro_exported?(Kernel, :if, 2)
roles = %{"admin" => :admin, "viewer" => :viewer}
{:ok, :viewer} = Map.fetch(roles, "viewer")
:error = Map.fetch(roles, "unexpected-role")
```

```elixir-bad
defmodule SkillSyntaxMissingCall do
  def run, do: String.this_function_does_not_exist_for_skill_verification("x")
end
```

Avoid `String.to_atom/1` on unbounded external input. An explicit string-to-atom
map is safer than assuming `String.to_existing_atom/1` validates permissions.
