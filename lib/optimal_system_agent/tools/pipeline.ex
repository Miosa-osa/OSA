defmodule OptimalSystemAgent.Tools.Pipeline do
  @moduledoc """
  Combinators for sequencing and composing tool instructions.

  All combinators accept raw instruction inputs (strings, 2-tuples, 3-tuples,
  or `Instruction` structs) and normalise them internally via
  `OptimalSystemAgent.Tools.Instruction.normalize/1`.

  ## Options (all combinators)

  * `:executor` — `(tool_name, params) -> {:ok, result} | {:error, reason}`.
    Defaults to a no-op that returns `{:ok, params}`.

  ## Examples

      executor = fn name, params ->
        OptimalSystemAgent.Tools.Registry.execute(name, params)
      end

      # Run instructions sequentially, piping output into next input
      Pipeline.pipe(["file_read", {"file_write", %{"content" => "..."}}], executor: executor)

  ## There is no `parallel/2`

  There used to be. It spawned a bare `Task.async` per instruction, awaited them
  all, and consulted nothing: not `concurrency_safe?/2`, not
  `Tools.ConflictScope`, not the cancel flag. Handed a list containing two edits
  to one file, it produced exactly the silent lost-update the loop's other two
  dispatch sites were fixed to prevent — and it would have done so while the
  loop's own telemetry showed nothing, since it is not the loop.

  It had **zero production callers**; the only thing that ever invoked it was
  its own test. So it was not a working feature with a bug, it was a hazard
  waiting for its first caller, and the caller would have got a third,
  divergent, unguarded copy of a decision that is hard to get right once.

  It was deleted rather than routed through `Agent.Loop.ToolOrchestrator`,
  because routing it would have meant inventing the things the orchestrator
  needs and this module does not have — tool-call ids, a `UseContext`, a loop
  state, a session to cancel — in order to keep an API nobody called. Concurrent
  tool dispatch has ONE entry point: `ToolOrchestrator.dispatch/3`, which
  batches by cross-call conflict, honours the interrupt flag, and reports what
  it serialised. `pipe/2`, `fallback/2` and `retry/2` are sequential and stay.
  """

  alias OptimalSystemAgent.Tools.Instruction

  @type executor :: (String.t(), map() -> {:ok, any()} | {:error, String.t()})

  @doc """
  Run `instructions` sequentially. Each step's output map is merged into the
  next step's params before execution. Short-circuits on the first error.
  """
  @spec pipe([term()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def pipe(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    Enum.reduce_while(instructions, {:ok, %{}}, fn raw, {:ok, acc} ->
      case Instruction.normalize(raw) do
        {:ok, inst} ->
          merged = Map.merge(acc, inst.params)

          case executor.(inst.tool, merged) do
            {:ok, result} -> {:cont, {:ok, result}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @doc """
  Try each instruction in turn and return the first success. If all fail,
  returns the last error.
  """
  @spec fallback([term()], keyword()) :: {:ok, any()} | {:error, String.t()}
  def fallback(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    Enum.reduce_while(instructions, {:error, "no instructions"}, fn raw, _acc ->
      case Instruction.normalize(raw) do
        {:ok, inst} ->
          case executor.(inst.tool, inst.params) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, _} = err -> {:cont, err}
          end

        {:error, _} = err ->
          {:cont, err}
      end
    end)
  end

  @doc """
  Retry a single `instruction` up to `:attempts` times (default 3).
  Returns the first success or the last error.
  """
  @spec retry(term(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def retry(instruction, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)
    attempts = Keyword.get(opts, :attempts, 3)

    case Instruction.normalize(instruction) do
      {:error, _} = err ->
        err

      {:ok, inst} ->
        Enum.reduce_while(1..attempts, {:error, "not attempted"}, fn _i, _acc ->
          case executor.(inst.tool, inst.params) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, _} = err -> {:cont, err}
          end
        end)
    end
  end
end
