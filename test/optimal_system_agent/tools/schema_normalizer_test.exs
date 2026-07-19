defmodule OptimalSystemAgent.Tools.SchemaNormalizerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.SchemaNormalizer, as: N

  describe "additionalProperties" do
    test "strips additionalProperties: true" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "additionalProperties" => true
      }

      out = N.normalize(schema)
      refute Map.has_key?(out, "additionalProperties")
    end

    test "keeps additionalProperties when it is a schema (false is left too)" do
      schema = %{"type" => "object", "additionalProperties" => false}
      assert N.normalize(schema)["additionalProperties"] == false

      nested = %{"type" => "object", "additionalProperties" => %{"type" => "string"}}
      assert N.normalize(nested)["additionalProperties"] == %{"type" => "string"}
    end
  end

  describe "anyOf / oneOf union collapse" do
    test "drops the null branch of an optional property and flattens the single survivor" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "nickname" => %{
            "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]
          }
        }
        # note: no "required" → nickname is optional → null branch droppable
      }

      out = N.normalize(schema)
      prop = out["properties"]["nickname"]

      refute Map.has_key?(prop, "anyOf")
      assert prop["type"] == "string"
    end

    test "keeps the null branch for a REQUIRED property" do
      schema = %{
        "type" => "object",
        "required" => ["nickname"],
        "properties" => %{
          "nickname" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
        }
      }

      out = N.normalize(schema)
      # required → null branch retained → union not collapsed to a bare string
      assert %{"anyOf" => branches} = out["properties"]["nickname"]
      assert Enum.any?(branches, &(&1["type"] == "null"))
    end

    test "flattens a single-member anyOf into the parent" do
      schema = %{"anyOf" => [%{"type" => "string", "description" => "hi"}]}
      out = N.normalize(schema)

      refute Map.has_key?(out, "anyOf")
      assert out["type"] == "string"
      assert out["description"] == "hi"
    end

    test "oneOf is treated as anyOf and a single member flattens" do
      schema = %{"oneOf" => [%{"type" => "integer"}]}
      out = N.normalize(schema)

      refute Map.has_key?(out, "oneOf")
      refute Map.has_key?(out, "anyOf")
      assert out["type"] == "integer"
    end

    test "an optional property expressed via oneOf with a null branch collapses" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "count" => %{"oneOf" => [%{"type" => "integer"}, %{"type" => "null"}]}
        }
      }

      out = N.normalize(schema)
      prop = out["properties"]["count"]

      refute Map.has_key?(prop, "oneOf")
      refute Map.has_key?(prop, "anyOf")
      assert prop["type"] == "integer"
      # integer bounds also applied on the way out
      assert prop["maximum"] == 9_007_199_254_740_991
    end

    test "empty {object} | {array} struct union collapses to object" do
      schema = %{"anyOf" => [%{"type" => "object"}, %{"type" => "array"}]}
      out = N.normalize(schema)

      refute Map.has_key?(out, "anyOf")
      assert out["type"] == "object"
      assert out["properties"] == %{}
    end

    test "a genuine multi-branch union is left as a single anyOf (no oneOf key)" do
      schema = %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      out = N.normalize(schema)

      refute Map.has_key?(out, "oneOf")
      assert %{"anyOf" => branches} = out
      assert length(branches) == 2
    end
  end

  describe "allOf flatten" do
    test "merges allOf members into the parent when no keys collide" do
      schema = %{
        "allOf" => [
          %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}},
          %{"required" => ["a"]}
        ]
      }

      out = N.normalize(schema)
      refute Map.has_key?(out, "allOf")
      assert out["type"] == "object"
      assert out["properties"]["a"]["type"] == "string"
      assert out["required"] == ["a"]
    end

    test "does not flatten allOf when a key collides" do
      schema = %{
        "type" => "object",
        "allOf" => [%{"type" => "string"}]
      }

      out = N.normalize(schema)
      # "type" collides with parent → left intact
      assert Map.has_key?(out, "allOf")
    end
  end

  describe "unbounded integer bounds" do
    test "forces minimum/maximum on an unbounded integer" do
      out = N.normalize(%{"type" => "integer"})
      assert out["minimum"] == -9_007_199_254_740_991
      assert out["maximum"] == 9_007_199_254_740_991
    end

    test "respects an existing maximum" do
      out = N.normalize(%{"type" => "integer", "maximum" => 10})
      assert out["maximum"] == 10
      refute Map.has_key?(out, "minimum")
    end

    test "leaves an existing minimum in place while adding a maximum" do
      out = N.normalize(%{"type" => "integer", "minimum" => 1})
      assert out["minimum"] == 1
      assert out["maximum"] == 9_007_199_254_740_991
    end

    test "does not touch string or number types" do
      assert N.normalize(%{"type" => "string"}) == %{"type" => "string"}
      assert N.normalize(%{"type" => "number"}) == %{"type" => "number"}
    end
  end

  describe "raw format handling" do
    test "strips a format annotation keyword" do
      out = N.normalize(%{"type" => "string", "format" => "uri"})
      refute Map.has_key?(out, "format")
      assert out["type"] == "string"
    end

    test "strips nested format keywords inside properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "email" => %{"type" => "string", "format" => "email"},
          "id" => %{"type" => "string", "format" => "uuid"}
        }
      }

      out = N.normalize(schema)
      refute Map.has_key?(out["properties"]["email"], "format")
      refute Map.has_key?(out["properties"]["id"], "format")
    end

    test "preserves a property NAMED format (only the keyword is stripped)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "format" => %{"type" => "string", "description" => "output format"}
        }
      }

      out = N.normalize(schema)
      # the property survives; only its inner (absent) format keyword would go
      assert out["properties"]["format"]["type"] == "string"
      assert out["properties"]["format"]["description"] == "output format"
    end
  end

  describe "$ref / $defs inlining" do
    test "inlines a local $ref and drops the resolved $defs" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "point" => %{"$ref" => "#/$defs/Point"}
        },
        "$defs" => %{
          "Point" => %{
            "type" => "object",
            "properties" => %{
              "x" => %{"type" => "integer"},
              "y" => %{"type" => "integer"}
            }
          }
        }
      }

      out = N.normalize(schema)

      refute Map.has_key?(out, "$defs")
      point = out["properties"]["point"]
      refute Map.has_key?(point, "$ref")
      assert point["type"] == "object"
      assert point["properties"]["x"]["type"] == "integer"
      # bounds applied to the inlined integers too
      assert point["properties"]["x"]["maximum"] == 9_007_199_254_740_991
    end

    test "inlines #/definitions/ references as well" do
      schema = %{
        "properties" => %{"n" => %{"$ref" => "#/definitions/Name"}},
        "definitions" => %{"Name" => %{"type" => "string"}}
      }

      out = N.normalize(schema)
      refute Map.has_key?(out, "definitions")
      assert out["properties"]["n"]["type"] == "string"
    end

    test "ref override fields survive inlining" do
      schema = %{
        "properties" => %{
          "p" => %{"$ref" => "#/$defs/Base", "description" => "overridden"}
        },
        "$defs" => %{"Base" => %{"type" => "string", "description" => "base"}}
      }

      out = N.normalize(schema)
      assert out["properties"]["p"]["type"] == "string"
      assert out["properties"]["p"]["description"] == "overridden"
    end

    test "a self-referential $ref does not loop forever" do
      schema = %{
        "$defs" => %{
          "Node" => %{
            "type" => "object",
            "properties" => %{"next" => %{"$ref" => "#/$defs/Node"}}
          }
        },
        "properties" => %{"root" => %{"$ref" => "#/$defs/Node"}}
      }

      # cycle guard leaves the innermost self-ref in place, so $defs is retained
      out = N.normalize(schema)
      assert out["properties"]["root"]["type"] == "object"
    end
  end

  describe "Type.Union-style schema (end-to-end antigravity case)" do
    test "a TypeBox Type.Union parameter is flattened to a provider-safe schema" do
      # What `Type.Union([Type.String(), Type.Null()])` on an optional field
      # compiles to — the exact shape google-antigravity rejects.
      schema = %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "target" => %{
            "anyOf" => [
              %{"type" => "string", "format" => "uri"},
              %{"type" => "null"}
            ]
          },
          "retries" => %{"type" => "integer"}
        },
        "required" => ["retries"]
      }

      out = N.normalize(schema)

      # additionalProperties: true gone
      refute Map.has_key?(out, "additionalProperties")

      # optional union collapsed to a bare string, format annotation gone
      target = out["properties"]["target"]
      refute Map.has_key?(target, "anyOf")
      assert target["type"] == "string"
      refute Map.has_key?(target, "format")

      # required integer bounded
      assert out["properties"]["retries"]["maximum"] == 9_007_199_254_740_991

      # nothing anyOf/oneOf/$ref survives anywhere
      json = Jason.encode!(out)
      refute String.contains?(json, "anyOf")
      refute String.contains?(json, "oneOf")
      refute String.contains?(json, "$ref")
    end
  end

  describe "tool-spec helpers" do
    test "normalize_tool/1 rewrites only the :parameters field" do
      tool = %{
        name: "demo",
        description: "d",
        parameters: %{"type" => "integer"}
      }

      out = N.normalize_tool(tool)
      assert out.name == "demo"
      assert out.description == "d"
      assert out.parameters["maximum"] == 9_007_199_254_740_991
    end

    test "normalize_tools/1 maps over a list and passes non-tool values through" do
      tools = [
        %{name: "a", description: "", parameters: %{"type" => "integer"}}
      ]

      [out] = N.normalize_tools(tools)
      assert out.parameters["maximum"] == 9_007_199_254_740_991

      assert N.normalize_tools(nil) == nil
    end

    test "normalize/1 passes non-map input through unchanged" do
      assert N.normalize("nope") == "nope"
      assert N.normalize(nil) == nil
    end
  end
end
