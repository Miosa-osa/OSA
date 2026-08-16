defmodule OptimalSystemAgent.Tools.ArgCoercionTest do
  @moduledoc """
  Behavioural tests for schema-driven argument coercion.

  The measured defect (`docs/research/tool-audit.md` §5): 233 tool calls in a
  29,188-call corpus were rejected because the model sent `"30"` where the
  schema said `integer`, or a bare string where it said `array`. Each cost a
  REASK round trip. These tests pin BOTH halves of the fix — that the
  unambiguous cases are repaired, and that the ambiguous ones are still left to
  fail loudly.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.ArgCoercion
  alias OptimalSystemAgent.Tools.Registry

  defp obj(props), do: %{"type" => "object", "properties" => props}

  describe "integer coercion" do
    test "an exact integer string becomes an integer" do
      schema = obj(%{"max_results" => %{"type" => "integer"}})
      assert %{"max_results" => 30} = ArgCoercion.coerce(schema, %{"max_results" => "30"})
    end

    test "negative and zero render losslessly" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      assert %{"n" => -5} = ArgCoercion.coerce(schema, %{"n" => "-5"})
      assert %{"n" => 0} = ArgCoercion.coerce(schema, %{"n" => "0"})
    end

    test "a fractional string is NOT truncated to an integer" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      assert %{"n" => "3.5"} = ArgCoercion.coerce(schema, %{"n" => "3.5"})
    end

    test "trailing garbage disqualifies the coercion" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      assert %{"n" => "30abc"} = ArgCoercion.coerce(schema, %{"n" => "30abc"})
    end

    test "the empty string is left alone" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      assert %{"n" => ""} = ArgCoercion.coerce(schema, %{"n" => ""})
    end

    test "an already-correct integer is untouched" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      assert %{"n" => 7} = ArgCoercion.coerce(schema, %{"n" => 7})
    end

    test "nil is never invented into a number" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      assert %{"n" => nil} = ArgCoercion.coerce(schema, %{"n" => nil})
    end
  end

  describe "number coercion" do
    test "a decimal string becomes a float" do
      schema = obj(%{"x" => %{"type" => "number"}})
      assert %{"x" => 3.5} = ArgCoercion.coerce(schema, %{"x" => "3.5"})
    end

    test "an integral string stays integral (still a valid JSON number)" do
      schema = obj(%{"x" => %{"type" => "number"}})
      assert %{"x" => 4} = ArgCoercion.coerce(schema, %{"x" => "4"})
    end

    test "a non-numeric string is left alone" do
      schema = obj(%{"x" => %{"type" => "number"}})
      assert %{"x" => "lots"} = ArgCoercion.coerce(schema, %{"x" => "lots"})
      assert %{"x" => "1.2.3"} = ArgCoercion.coerce(schema, %{"x" => "1.2.3"})
    end
  end

  describe "boolean coercion" do
    test "exactly the two JSON literals convert" do
      schema = obj(%{"flag" => %{"type" => "boolean"}})
      assert %{"flag" => true} = ArgCoercion.coerce(schema, %{"flag" => "true"})
      assert %{"flag" => false} = ArgCoercion.coerce(schema, %{"flag" => "false"})
    end

    test "conventions that are not renderings are refused" do
      schema = obj(%{"flag" => %{"type" => "boolean"}})

      for input <- ["yes", "no", "1", "0", "True", "TRUE", ""] do
        assert %{"flag" => ^input} = ArgCoercion.coerce(schema, %{"flag" => input})
      end
    end
  end

  describe "array coercion" do
    test "a bare scalar is wrapped into a one-element list" do
      schema = obj(%{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}})
      assert %{"tags" => ["a"]} = ArgCoercion.coerce(schema, %{"tags" => "a"})
    end

    test "the wrapped element is itself coerced against items" do
      schema = obj(%{"ids" => %{"type" => "array", "items" => %{"type" => "integer"}}})
      assert %{"ids" => [3]} = ArgCoercion.coerce(schema, %{"ids" => "3"})
    end

    test "existing list elements are coerced in place" do
      schema = obj(%{"ids" => %{"type" => "array", "items" => %{"type" => "integer"}}})
      assert %{"ids" => [1, 2, "x"]} = ArgCoercion.coerce(schema, %{"ids" => ["1", 2, "x"]})
    end

    test "nil is never wrapped into a one-element list" do
      schema = obj(%{"ids" => %{"type" => "array", "items" => %{"type" => "integer"}}})
      assert %{"ids" => nil} = ArgCoercion.coerce(schema, %{"ids" => nil})
    end

    test "a map is not wrapped" do
      schema = obj(%{"ids" => %{"type" => "array", "items" => %{"type" => "object"}}})
      assert %{"ids" => %{"a" => 1}} = ArgCoercion.coerce(schema, %{"ids" => %{"a" => 1}})
    end
  end

  describe "recursion" do
    test "nested objects are walked" do
      schema =
        obj(%{
          "opts" =>
            obj(%{
              "limit" => %{"type" => "integer"},
              "deep" => obj(%{"n" => %{"type" => "number"}})
            })
        })

      assert %{"opts" => %{"limit" => 10, "deep" => %{"n" => 1.5}}} =
               ArgCoercion.coerce(schema, %{
                 "opts" => %{"limit" => "10", "deep" => %{"n" => "1.5"}}
               })
    end

    test "objects inside array items are walked" do
      schema =
        obj(%{
          "todos" => %{
            "type" => "array",
            "items" => obj(%{"id" => %{"type" => "integer"}, "done" => %{"type" => "boolean"}})
          }
        })

      assert %{"todos" => [%{"id" => 1, "done" => true}, %{"id" => 2, "done" => "maybe"}]} =
               ArgCoercion.coerce(schema, %{
                 "todos" => [%{"id" => "1", "done" => "true"}, %{"id" => "2", "done" => "maybe"}]
               })
    end
  end

  describe "no-op cases" do
    test "a property with no declared type is untouched" do
      schema = obj(%{"anything" => %{"description" => "free-form"}})
      assert %{"anything" => "30"} = ArgCoercion.coerce(schema, %{"anything" => "30"})
    end

    test "a union type is ambiguous, so nothing fires" do
      schema = obj(%{"n" => %{"type" => ["string", "integer"]}})
      assert %{"n" => "30"} = ArgCoercion.coerce(schema, %{"n" => "30"})
    end

    test "properties absent from the schema pass through" do
      schema = obj(%{"n" => %{"type" => "integer"}})
      args = %{"n" => "1", "__session_id__" => "abc", "extra" => "2"}

      assert %{"n" => 1, "__session_id__" => "abc", "extra" => "2"} =
               ArgCoercion.coerce(schema, args)
    end

    test "a string field is never re-typed" do
      schema = obj(%{"s" => %{"type" => "string"}})
      assert %{"s" => "30"} = ArgCoercion.coerce(schema, %{"s" => "30"})
    end
  end

  describe "totality" do
    test "is idempotent" do
      schema =
        obj(%{
          "n" => %{"type" => "integer"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "flag" => %{"type" => "boolean"}
        })

      args = %{"n" => "30", "tags" => "a", "flag" => "true", "junk" => "3.5"}
      once = ArgCoercion.coerce(schema, args)
      assert once == ArgCoercion.coerce(schema, once)

      assert once ==
               args
               |> then(&ArgCoercion.coerce(schema, &1))
               |> then(&ArgCoercion.coerce(schema, &1))
    end

    test "never raises on garbage schemas or garbage arguments" do
      garbage = [
        nil,
        42,
        "schema",
        [],
        %{"type" => 7},
        %{"properties" => "nope"},
        %{"type" => "array"}
      ]

      for schema <- garbage do
        assert ArgCoercion.coerce(schema, %{"a" => 1}) == %{"a" => 1}
      end

      for value <- [nil, 42, "args", [1, 2], {:tuple, 1}] do
        assert ArgCoercion.coerce(obj(%{"a" => %{"type" => "integer"}}), value) == value
      end
    end

    test "self-referential / deeply nested junk still returns" do
      schema = obj(%{"a" => obj(%{"b" => obj(%{"c" => %{"type" => "integer"}})})})

      assert %{"a" => %{"b" => %{"c" => 1}}} =
               ArgCoercion.coerce(schema, %{"a" => %{"b" => %{"c" => "1"}}})

      assert %{"a" => "x"} = ArgCoercion.coerce(schema, %{"a" => "x"})
    end
  end

  describe "end to end through Registry.coerce_and_validate/2 on real tool schemas" do
    test "file_grep max_results as a string now validates, and the coerced value comes back" do
      mod = OptimalSystemAgent.Tools.Builtins.FileGrep.Tool
      args = %{"pattern" => "foo", "max_results" => "30"}

      # Pre-fix behaviour: ExJsonSchema rejects it outright.
      assert {:error, _} =
               Registry.validate_arguments(mod, %{"pattern" => "foo", "max_results" => "30abc"})

      assert {:ok, coerced} = Registry.coerce_and_validate(mod, args)
      assert coerced["max_results"] == 30
    end

    test "validate_arguments/2 still answers :ok / {:error, _} for existing callers" do
      mod = OptimalSystemAgent.Tools.Builtins.FileGrep.Tool
      assert :ok = Registry.validate_arguments(mod, %{"pattern" => "foo", "max_results" => "30"})
      assert {:error, message} = Registry.validate_arguments(mod, %{})
      assert is_binary(message)
    end
  end
end
