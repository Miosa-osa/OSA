defmodule OptimalSystemAgent.Tools.ArgCoercion do
  @moduledoc """
  Schema-driven, lossless coercion of model-emitted tool arguments.

  ## Why

  Providers hand back tool arguments as JSON, and models routinely emit a
  *stringified* scalar where the schema asks for an integer/number/boolean, or a
  bare scalar where the schema asks for an array. `ExJsonSchema` correctly
  rejects those, and the agent loop then burns a full REASK round trip (plus
  error tokens) to get back a value it already had.

  Measured over a 29,188-call corpus (`docs/research/tool-audit.md` §5): 233
  rejections were of exactly this shape — `task_write` 127 (Expected Array, got
  String), `file_grep` 69 (Expected Integer, got String), `web_fetch` 26,
  `memory_save` 5, `tool_search` 4, `sleep` 2. `tool_search` saw only 11-12
  calls in the whole corpus, so that is a ~40% failure rate on the escape hatch
  that makes the deferred tools reachable at all.

  This module fixes it in ONE place, driven by the tool's own JSON Schema,
  instead of per-tool argument massaging.

  ## Contract

  `coerce/2` is **total**, **idempotent** and **conservative**:

    * total — any input that matches no rule passes through untouched; it never
      raises, whatever garbage it is handed;
    * idempotent — `coerce(s, coerce(s, args)) == coerce(s, args)`, because
      every rule only fires on a shape it then leaves alone;
    * conservative and lossless — a coercion happens only when the string is an
      exact, round-trippable rendering of the target type. `"30"` becomes `30`;
      `"30abc"`, `"3.5"` (for an `integer`), `""`, `"yes"`, `"TRUE"` and
      anything else ambiguous are left EXACTLY as-is so validation still
      rejects them with a real error. Never guess: a wrong guess executes the
      wrong tool call silently, which is strictly worse than a REASK.

  ## Rules

    * `"integer"` + string matching an optional sign and digits → integer
    * `"number"` + numeric string → float (or integer, if it renders as one)
    * `"boolean"` + exactly `"true"` / `"false"` → boolean
    * `"array"` + scalar (string/number/boolean) → one-element list, whose
      element is then coerced against `items`
    * `"object"` → recurse into `properties`
    * `"array"` → recurse into `items` for every element

  Nothing else is touched. In particular: a missing `"type"`, or a *union* type
  (`"type"` given as a list), disables coercion for that node — with more than
  one admissible type there is no unambiguous target. `nil` is never wrapped
  into `[nil]`; a null stays a null so `required`/nullability still decide.

  Schemas are string-keyed, the same JSON convention as
  `OptimalSystemAgent.Tools.SchemaNormalizer`. Atom-keyed *argument* maps are
  also honoured, since some internal callers build args with atom keys.
  """

  @doc """
  Coerce `arguments` against `schema`, returning the coerced argument map.

  Returns `arguments` unchanged when the schema is not a usable object schema,
  when the arguments are not a map, or on any internal error.
  """
  @spec coerce(term(), term()) :: term()
  def coerce(schema, arguments) when is_map(arguments) do
    coerce_value(schema, arguments)
  rescue
    _ -> arguments
  catch
    _, _ -> arguments
  end

  def coerce(_schema, arguments), do: arguments

  # ── Core walk ────────────────────────────────────────────────────────

  defp coerce_value(schema, value) when is_map(schema) do
    case schema_type(schema) do
      "object" -> coerce_object(schema, value)
      "array" -> coerce_array(schema, value)
      "integer" -> coerce_integer(value)
      "number" -> coerce_number(value)
      "boolean" -> coerce_boolean(value)
      # Absent type, union type ("type" as a list), or a type we do not touch
      # (e.g. "string"): recurse structurally where the schema still tells us
      # how, otherwise leave alone.
      _ -> untyped_recurse(schema, value)
    end
  end

  defp coerce_value(_schema, value), do: value

  # A schema with no declared type may still carry `properties` (a de-facto
  # object) — recurse so nested integers under such a node are still fixed.
  # It must NOT do scalar->array wrapping or any type conversion: with no
  # declared type there is no unambiguous target.
  defp untyped_recurse(schema, value) when is_map(value) do
    if is_map(Map.get(schema, "properties")), do: coerce_object(schema, value), else: value
  end

  defp untyped_recurse(_schema, value), do: value

  # ── object ───────────────────────────────────────────────────────────

  defp coerce_object(schema, value) when is_map(value) do
    props = Map.get(schema, "properties")

    if is_map(props) do
      Enum.reduce(props, value, fn {key, prop_schema}, acc ->
        cond do
          Map.has_key?(acc, key) ->
            Map.put(acc, key, coerce_value(prop_schema, Map.get(acc, key)))

          # Some internal callers build argument maps with atom keys.
          is_binary(key) and atom_key(key) != nil and Map.has_key?(acc, atom_key(key)) ->
            k = atom_key(key)
            Map.put(acc, k, coerce_value(prop_schema, Map.get(acc, k)))

          true ->
            acc
        end
      end)
    else
      value
    end
  end

  defp coerce_object(_schema, value), do: value

  defp atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # ── array ────────────────────────────────────────────────────────────

  defp coerce_array(schema, value) when is_list(value) do
    items = Map.get(schema, "items")

    if is_map(items), do: Enum.map(value, &coerce_value(items, &1)), else: value
  end

  # Scalar where an array is required: the single most common model slip
  # (`task_write` 127 rejections). Wrap it, then coerce the element against
  # `items` so `{"type":"array","items":{"type":"integer"}}` + `"3"` yields
  # `[3]`. `nil`, maps and anything else are left alone — a null is a real
  # value the schema may legitimately reject, not a one-element list.
  defp coerce_array(schema, value)
       when is_binary(value) or is_number(value) or is_boolean(value) do
    items = Map.get(schema, "items")
    element = if is_map(items), do: coerce_value(items, value), else: value
    [element]
  end

  defp coerce_array(_schema, value), do: value

  # ── scalars ──────────────────────────────────────────────────────────

  # Exact integer rendering only. `Integer.parse/1` alone is not enough: it
  # happily returns `{30, "abc"}` for `"30abc"` and `{3, ".5"}` for `"3.5"`.
  # The remainder must be empty for the conversion to be lossless.
  defp coerce_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp coerce_integer(value), do: value

  # A `number` accepts both integer and float renderings. An integral string
  # stays an integer (a valid JSON number, and lossless); anything with a
  # fractional/exponent part becomes a float. Trailing garbage disqualifies.
  defp coerce_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  defp coerce_number(value), do: value

  # Exactly the two JSON literals. Not `"yes"`, not `"1"`, not `"True"` —
  # those are conventions, not renderings, and guessing at them is how a
  # "safe" flag silently flips.
  defp coerce_boolean("true"), do: true
  defp coerce_boolean("false"), do: false
  defp coerce_boolean(value), do: value

  # ── helpers ──────────────────────────────────────────────────────────

  # Only a single, string type participates in coercion. A list ("type":
  # ["string","integer"]) is a union: ambiguous, so no rule fires.
  defp schema_type(schema) do
    case Map.get(schema, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end
end
