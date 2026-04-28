defmodule OptimalSystemAgent.Tools.MiddlewareTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.{Instruction, Middleware}

  # A simple executor that returns the instruction params
  defp success_executor(instruction) do
    {:ok, instruction.params}
  end

  defp failure_executor(instruction) do
    {:error, "tool #{instruction.tool} failed"}
  end

  # ---------------------------------------------------------------------------
  # Core middleware execution
  # ---------------------------------------------------------------------------

  describe "execute/3" do
    test "runs executor directly with empty stack" do
      inst = %Instruction{tool: "test_tool", params: %{"key" => "value"}}

      assert {:ok, %{"key" => "value"}} =
               Middleware.execute(inst, [], &success_executor/1)
    end

    test "runs middleware in stack order" do
      defmodule FirstMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, _opts) do
          order = Map.get(instruction.params, :order, [])

          updated = %{
            instruction
            | params: Map.put(instruction.params, :order, order ++ [:first])
          }

          next.(updated)
        end
      end

      defmodule SecondMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, _opts) do
          order = Map.get(instruction.params, :order, [])

          updated = %{
            instruction
            | params: Map.put(instruction.params, :order, order ++ [:second])
          }

          next.(updated)
        end
      end

      inst = %Instruction{tool: "test", params: %{}}

      assert {:ok, result} =
               Middleware.execute(inst, [FirstMW, SecondMW], &success_executor/1)

      assert result[:order] == [:first, :second]
    end

    test "middleware can short-circuit execution" do
      defmodule BlockingMW do
        @behaviour Middleware

        @impl true
        def call(_instruction, _next, _opts) do
          {:error, "blocked by middleware"}
        end
      end

      inst = %Instruction{tool: "test", params: %{}}

      assert {:error, "blocked by middleware"} =
               Middleware.execute(inst, [BlockingMW], &success_executor/1)
    end

    test "middleware can transform the result" do
      defmodule TransformMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, _opts) do
          case next.(instruction) do
            {:ok, result} -> {:ok, Map.put(result, :transformed, true)}
            error -> error
          end
        end
      end

      inst = %Instruction{tool: "test", params: %{"x" => 1}}

      assert {:ok, result} =
               Middleware.execute(inst, [TransformMW], &success_executor/1)

      assert result[:transformed] == true
      assert result["x"] == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in Middleware: Validation
  # ---------------------------------------------------------------------------

  describe "Middleware.Validation" do
    test "passes valid instructions through" do
      inst = %Instruction{tool: "test", params: %{"a" => 1}}

      assert {:ok, _} =
               Middleware.execute(inst, [Middleware.Validation], &success_executor/1)
    end

    # Validation checks required params from opts, not tool name
    test "passes through with no required opts" do
      inst = %Instruction{tool: "", params: %{}}

      assert {:ok, _} =
               Middleware.execute(inst, [Middleware.Validation], &success_executor/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in Middleware: Timing
  # ---------------------------------------------------------------------------

  describe "Middleware.Timing" do
    test "wraps success result in 3-tuple with elapsed time" do
      inst = %Instruction{tool: "test", params: %{"data" => "value"}}

      assert {:ok, %{"data" => "value"}, elapsed} =
               Middleware.execute(inst, [Middleware.Timing], &success_executor/1)

      assert is_integer(elapsed)
    end

    test "passes through errors unchanged" do
      inst = %Instruction{tool: "test", params: %{}}

      assert {:error, _} =
               Middleware.execute(inst, [Middleware.Timing], &failure_executor/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in Middleware: Logging
  # ---------------------------------------------------------------------------

  describe "Middleware.Logging" do
    test "does not alter success results" do
      inst = %Instruction{tool: "test", params: %{"x" => 1}}

      assert {:ok, %{"x" => 1}} =
               Middleware.execute(inst, [Middleware.Logging], &success_executor/1)
    end

    test "does not alter error results" do
      inst = %Instruction{tool: "test", params: %{}}

      assert {:error, "tool test failed"} =
               Middleware.execute(inst, [Middleware.Logging], &failure_executor/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Full stack integration
  # ---------------------------------------------------------------------------

  describe "full middleware stack" do
    test "composes Validation + Timing + Logging" do
      inst = %Instruction{tool: "integration_test", params: %{"value" => 42}}

      stack = [
        Middleware.Validation,
        Middleware.Timing,
        Middleware.Logging
      ]

      # Timing wraps in 3-tuple
      assert {:ok, %{"value" => 42}, _elapsed} =
               Middleware.execute(inst, stack, &success_executor/1)
    end
  end
end
