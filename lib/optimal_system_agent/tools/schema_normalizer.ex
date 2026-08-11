defmodule OptimalSystemAgent.Tools.SchemaNormalizer do
  @moduledoc """
  LLM-safe JSON-Schema normalizer for OSA tool parameter schemas.

  Ported from opencode's `tool/json-schema.ts` (`normalize`), adapted to the
  string-keyed JSON-Schema maps OSA tools emit from `parameters/0` and the
  `input_schema` maps MCP servers advertise.

  ## Why

  Several validators — notably **google-antigravity** — reject perfectly legal
  JSON-Schema constructs that our schema builders (and MCP servers) emit:

    * `anyOf` / `oneOf` unions (what `Type.Union` compiles to)
    * `additionalProperties: true`
    * raw `format` annotation keywords with unsupported values
    * unbounded `integer` fields
    * local `$ref` / `$defs` (some providers won't resolve them)

  Sending any of these produces a hard 400 before the model ever runs. This
  module rewrites a schema into a maximally-portable equivalent so **every**
  tool schema crossing the provider boundary is safe, regardless of which
  provider serves the turn.

  ## Transformations (each is idempotent)

    1. **`additionalProperties: true`** — dropped (implied default; some
       validators reject the explicit `true`).
    2. **`anyOf` / `oneOf` union collapse** —
       * `oneOf` is treated as `anyOf` (rewritten to a single `anyOf` key);
       * for optional properties, `{"type": "null"}` branches are dropped;
       * a `number` + non-finite-enum union collapses to the `number`;
       * an empty `{object} | {array}` struct union collapses to `object`;
       * a single-member union is flattened into its parent.
    3. **`allOf` flatten** — merged into the parent when no keys collide.
    4. **Unbounded `integer`** — gets `minimum`/`maximum` safe-integer bounds.
    5. **Raw `format` keyword** — stripped (it is an optional annotation; an
       unsupported value like `"uri"`/`"uuid"` is what triggers rejection, and
       removing it never changes the argument contract).
    6. **Local `$ref` / `$defs`** — every `#/$defs/...` and `#/definitions/...`
       reference is inlined, then the now-unused definition blocks are dropped
       so no reference survives.

  All schemas are string-keyed (the JSON convention OSA and MCP both use);
  non-map / atom-keyed values pass through untouched.
  """

  # Mirrors JS Number.MAX_SAFE_INTEGER / MIN_SAFE_INTEGER so an unbounded
  # integer field advertises a concrete, provider-acceptable range.
  @max_safe_integer 9_007_199_254_740_991
  @min_safe_integer -9_007_199_254_740_991

  @doc """
  Normalize a single JSON-Schema map into an LLM-safe equivalent.

  Non-map input is returned unchanged.
  """
  @spec normalize(term()) :: term()
  def normalize(schema) when is_map(schema) do
    schema
    |> normalize_node(false)
    |> inline_local_refs(nil, MapSet.new())
    |> drop_defs_if_resolved()
  end

  def normalize(other), do: other

  @doc """
  Normalize the `:parameters` (or `"parameters"`) field of a single tool spec
  map (`%{name:, description:, parameters:}`), leaving everything else intact.
  """
  @spec normalize_tool(map()) :: map()
  def normalize_tool(%{parameters: params} = tool),
    do: %{tool | parameters: normalize(params)}

  def normalize_tool(%{"parameters" => params} = tool),
    do: Map.put(tool, "parameters", normalize(params))

  def normalize_tool(tool), do: tool

  @doc """
  Normalize every tool spec in a list. Anything that is not a tool-shaped map
  passes through untouched, so this is safe to call on an arbitrary `:tools`
  option value.
  """
  @spec normalize_tools(term()) :: term()
  def normalize_tools(tools) when is_list(tools), do: Enum.map(tools, &normalize_tool/1)
  def normalize_tools(other), do: other

  # ── Core recursive normalization ──────────────────────────────────────────

  # `strip_null?` is true when the node is the value of an OPTIONAL property
  # (its name is absent from the enclosing object's `required`). Only then may
  # a `{"type": "null"}` branch be dropped from a union — for a required field
  # the null branch is meaningful and left alone.
  defp normalize_node(value, _strip_null?) when is_list(value) do
    Enum.map(value, &normalize_node(&1, false))
  end

  defp normalize_node(value, strip_null?) when is_map(value) do
    required = required_set(value)

    value
    |> Enum.map(fn
      {"properties", props} when is_map(props) ->
        {"properties", normalize_properties(props, required)}

      {k, v} ->
        {k, normalize_node(v, false)}
    end)
    |> Map.new()
    |> drop_additional_properties()
    |> strip_format()
    |> unify_oneof()
    |> collapse_union(strip_null?)
    |> flatten_all_of()
    |> bound_integer()
  end

  defp normalize_node(value, _strip_null?), do: value

  defp normalize_properties(props, required) do
    props
    |> Enum.map(fn {name, property} ->
      {name, normalize_node(property, not MapSet.member?(required, name))}
    end)
    |> Map.new()
  end

  defp required_set(%{"required" => list}) when is_list(list),
    do: list |> Enum.filter(&is_binary/1) |> MapSet.new()

  defp required_set(_), do: MapSet.new()

  # 1. additionalProperties: true → drop.
  defp drop_additional_properties(%{"additionalProperties" => true} = schema),
    do: Map.delete(schema, "additionalProperties")

  defp drop_additional_properties(schema), do: schema

  # 5. Raw `format` annotation keyword → strip. Only removes the schema-level
  # `format` keyword; a property *named* "format" lives inside "properties" and
  # is untouched (it is never this map's own "format" key).
  defp strip_format(%{"format" => _} = schema), do: Map.delete(schema, "format")
  defp strip_format(schema), do: schema

  # 2a. Rewrite `oneOf` to `anyOf` so union collapse has a single code path and
  # a surviving multi-branch union is expressed with one (anyOf) key, not two.
  # If both are present the branches are concatenated.
  defp unify_oneof(%{"oneOf" => one} = schema) when is_list(one) do
    existing = Map.get(schema, "anyOf", [])
    existing = if is_list(existing), do: existing, else: []

    schema
    |> Map.delete("oneOf")
    |> Map.put("anyOf", existing ++ one)
  end

  defp unify_oneof(schema), do: schema

  # 2b. Union collapse on `anyOf`.
  defp collapse_union(%{"anyOf" => branches} = schema, strip_null?) when is_list(branches) do
    cond do
      # Optional property: drop null branches, then re-run the whole node so a
      # now-single-member union flattens.
      strip_null? and Enum.any?(branches, &null_branch?/1) ->
        without_null = Enum.reject(branches, &null_branch?/1)
        normalize_node(Map.put(schema, "anyOf", without_null), strip_null?)

      # number + non-finite-enum branches → collapse to the number branch.
      (number = Enum.find(branches, &number_branch?/1)) &&
          non_finite_count(branches) == length(branches) - 1 ->
        rest = Map.delete(schema, "anyOf")
        normalize_node(Map.merge(number, rest), false)

      # empty {object} | {array} struct union → object.
      empty_struct_union?(branches) ->
        rest = Map.delete(schema, "anyOf")
        normalize_node(Map.merge(%{"type" => "object", "properties" => %{}}, rest), false)

      # single-member union → flatten member into parent.
      match?([m] when is_map(m), branches) ->
        [member] = branches
        rest = Map.delete(schema, "anyOf")
        normalize_node(Map.merge(member, rest), false)

      true ->
        schema
    end
  end

  defp collapse_union(schema, _strip_null?), do: schema

  # 3. allOf flatten — only when member keys don't collide with each other or
  # the parent, matching opencode's `canFlattenAllOf`.
  defp flatten_all_of(%{"allOf" => all} = schema) when is_list(all) do
    if Enum.all?(all, &is_map/1) and can_flatten_all_of?(all, schema) do
      rest = Map.delete(schema, "allOf")
      merged = Enum.reduce(all, %{}, &Map.merge(&2, &1))
      normalize_node(Map.merge(merged, rest), false)
    else
      schema
    end
  end

  defp flatten_all_of(schema), do: schema

  defp can_flatten_all_of?(all, parent) do
    parent_keys = parent |> Map.keys() |> Enum.reject(&(&1 == "allOf")) |> MapSet.new()

    {ok?, _seen} =
      Enum.reduce_while(all, {true, parent_keys}, fn item, {_ok, seen} ->
        Enum.reduce_while(Map.keys(item), {true, seen}, fn key, {_ok, seen} ->
          if MapSet.member?(seen, key) do
            {:halt, {false, seen}}
          else
            {:cont, {true, MapSet.put(seen, key)}}
          end
        end)
        |> case do
          {false, seen} -> {:halt, {false, seen}}
          {true, seen} -> {:cont, {true, seen}}
        end
      end)

    ok?
  end

  # 4. Unbounded integer → safe-integer bounds. `minimum` fills only when
  # absent; `maximum` is the trigger and is always set.
  defp bound_integer(%{"type" => "integer"} = schema) do
    if Map.has_key?(schema, "maximum") do
      schema
    else
      schema
      |> Map.put_new("minimum", @min_safe_integer)
      |> Map.put("maximum", @max_safe_integer)
    end
  end

  defp bound_integer(schema), do: schema

  # ── Union-branch predicates ───────────────────────────────────────────────

  defp null_branch?(%{"type" => "null"}), do: true
  defp null_branch?(_), do: false

  defp number_branch?(%{"type" => "number"}), do: true
  defp number_branch?(_), do: false

  defp non_finite_count(branches) do
    Enum.count(branches, fn
      %{"enum" => enum} when is_list(enum) -> Enum.all?(enum, &non_finite_number?/1)
      _ -> false
    end)
  end

  defp non_finite_number?(v), do: v in ["NaN", "Infinity", "-Infinity"]

  defp empty_struct_union?(branches) do
    length(branches) == 2 and
      Enum.any?(branches, fn b ->
        is_map(b) and b["type"] == "object" and not has_key_string?(b, "properties")
      end) and
      Enum.any?(branches, fn b ->
        is_map(b) and b["type"] == "array" and not has_key_string?(b, "items")
      end)
  end

  defp has_key_string?(map, key), do: is_map(map) and Map.has_key?(map, key)

  # ── $ref / $defs inlining ─────────────────────────────────────────────────

  # `defs` is the definitions table in scope (top-level `$defs`/`definitions`);
  # `seen` guards against ref cycles.
  defp inline_local_refs(value, defs, seen) when is_list(value),
    do: Enum.map(value, &inline_local_refs(&1, defs, seen))

  defp inline_local_refs(value, defs, seen) when is_map(value) do
    defs = defs || local_definitions(value)

    case ref_target_name(value) do
      {:ok, name} ->
        cond do
          MapSet.member?(seen, name) ->
            recurse_refs(value, defs, seen)

          (target = defs && defs[name]) && is_map(target) ->
            merged = Map.merge(target, Map.delete(value, "$ref"))
            inline_local_refs(merged, defs, MapSet.put(seen, name))

          true ->
            recurse_refs(value, defs, seen)
        end

      :error ->
        recurse_refs(value, defs, seen)
    end
  end

  defp inline_local_refs(value, _defs, _seen), do: value

  defp recurse_refs(value, defs, seen) do
    value
    |> Enum.map(fn {k, v} -> {k, inline_local_refs(v, defs, seen)} end)
    |> Map.new()
  end

  defp local_definitions(%{"$defs" => defs}) when is_map(defs), do: defs
  defp local_definitions(%{"definitions" => defs}) when is_map(defs), do: defs
  defp local_definitions(_), do: nil

  defp ref_target_name(%{"$ref" => ref}) when is_binary(ref) do
    cond do
      name = capture(ref, ~r{^#/\$defs/(.+)$}) -> {:ok, name}
      name = capture(ref, ~r{^#/definitions/(.+)$}) -> {:ok, name}
      true -> :error
    end
  end

  defp ref_target_name(_), do: :error

  defp capture(str, regex) do
    case Regex.run(regex, str) do
      [_, name] -> name
      _ -> nil
    end
  end

  # Drop the definition blocks once nothing references them anymore.
  defp drop_defs_if_resolved(value) when is_map(value) do
    if has_local_reference?(value) do
      value
    else
      value |> Map.delete("$defs") |> Map.delete("definitions")
    end
  end

  defp drop_defs_if_resolved(value), do: value

  defp has_local_reference?(value) when is_list(value),
    do: Enum.any?(value, &has_local_reference?/1)

  defp has_local_reference?(%{"$ref" => ref} = value) when is_binary(ref) do
    if String.starts_with?(ref, "#/$defs/") or String.starts_with?(ref, "#/definitions/") do
      true
    else
      value |> Map.values() |> Enum.any?(&has_local_reference?/1)
    end
  end

  defp has_local_reference?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&has_local_reference?/1)

  defp has_local_reference?(_), do: false
end
