defmodule OptimalSystemAgent.Agent.Loop.ToolError do
  @moduledoc """
  The NON-FATAL TOOL ERROR contract (Codex `FunctionCallError` parity).

  Codex models every model-visible tool failure as exactly two variants
  (`codex-rs/tools/src/function_call_error.rs`):

      pub enum FunctionCallError {
          RespondToModel(String),   // synthesize a tool result, turn CONTINUES
          Fatal(String),            // the turn dies
      }

  and the dispatcher (`codex-rs/core/src/tools/parallel.rs:78-84`) routes them:
  `Fatal` becomes a hard turn error, **everything else** is turned into a
  synthesized tool result (`failure_response`, `success: Some(false)`, the error
  text as the body) so the MODEL READS the failure and recovers.

  This module is that contract for OSA. The default class is
  `:respond_to_model`: a tool that raises, throws, exits, times out, is denied
  by the operator, or returns `{:error, reason}` produces a **normal tool
  result** the model can read and react to. Only an explicit fatal signal
  aborts the turn.

  ## What is FATAL

  Deliberately tiny — mirroring Codex, where `Fatal` is reserved for "the
  machinery itself is broken", not "this call did not work":

    * a tool returning `{:fatal, reason}`
    * a raised `#{inspect(__MODULE__)}.Fatal` exception
    * an exit with reason `{:fatal, reason}`

  Everything else — `RuntimeError`, `ArgumentError`, `File.Error`, a `throw`, a
  GenServer-call `:exit`, a killed/timed-out task, an unknown tool, a schema
  rejection, a permission denial — is `:respond_to_model`.

  ## Wire shapes

  `ToolExecutor.execute_tool_call/2` returns:

    * `{tool_msg, result_str}`                      — normal (unchanged)
    * `{tool_msg, result_str, {:fatal, message}}`   — fatal

  The fatal 3-tuple still carries a fully-formed `tool_msg` and a binary
  `result_str` (prefixed `"Error:"`, per the existing convention that
  `finalize_result/5`, `Reminders`, and `DoomLoop` all key on) so that history
  stays valid and every binary-based check keeps working. The third element is
  the only thing that says "abort"; `normalize_results/1` strips it at the
  ReactLoop boundary.
  """

  defmodule Fatal do
    @moduledoc """
    Raise this from anywhere under `ToolExecutor.execute_tool_call/2` to abort
    the turn. Everything else is recovered into a model-readable tool result.
    """
    defexception message: "fatal tool error"
  end

  # Throw tag used to unwind out of `DurableLog.run_once/3` WITHOUT recording a
  # fatal step as a completed one.
  @throw_tag :osa_fatal_tool

  @max_reason_bytes 4_000

  @type class :: :ok | :fatal | :error
  @type outcome :: {:ok, term()} | {:fatal, String.t()} | {:error, String.t()}

  @doc "Raise the fatal signal (aborts the turn)."
  @spec fatal!(String.t()) :: no_return()
  def fatal!(message), do: raise(Fatal, message: text(message))

  @doc false
  @spec throw_fatal(String.t()) :: no_return()
  def throw_fatal(message), do: throw({@throw_tag, text(message)})

  @doc """
  Run `fun`, converting EVERY failure mode into the two-class contract.

  Returns `{:ok, value}`, `{:fatal, message}`, or `{:error, message}`. The
  `{:error, ...}` class is the Codex `RespondToModel` variant: the caller is
  expected to synthesize a tool result from it and keep the turn alive.
  """
  @spec run((-> term())) :: outcome()
  def run(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    e in Fatal ->
      {:fatal, text(e.message)}

    e ->
      {:error, exception_text(e, __STACKTRACE__)}
  catch
    :throw, {@throw_tag, message} ->
      {:fatal, text(message)}

    :throw, {:fatal, message} ->
      {:fatal, text(message)}

    :throw, value ->
      {:error, "tool threw #{inspect(value, limit: 20)}"}

    :exit, {:fatal, message} ->
      {:fatal, text(message)}

    :exit, reason ->
      {:error, exit_text(reason)}
  end

  @doc """
  Classify a raw tool return value.

  `{:fatal, reason}` is the ONLY value that aborts; every other error shape is
  a `:respond_to_model` string the model gets to read.
  """
  @spec classify(term()) :: {:fatal, String.t()} | :not_fatal
  def classify({:fatal, reason}), do: {:fatal, text(reason)}
  def classify(%Fatal{message: m}), do: {:fatal, text(m)}
  def classify(_), do: :not_fatal

  @doc """
  Human-readable text for a process exit reason, safe for a tool result body.
  """
  @spec exit_text(term()) :: String.t()
  def exit_text({:timeout, _call}), do: "tool timed out waiting on a call"
  def exit_text(:timeout), do: "tool timed out"
  def exit_text(:killed), do: "tool process was killed"
  def exit_text(:noproc), do: "a process the tool depends on is not running"
  def exit_text({:noproc, _}), do: "a process the tool depends on is not running"
  def exit_text(:shutdown), do: "tool process was shut down"
  def exit_text({:shutdown, _}), do: "tool process was shut down"

  def exit_text({%{__exception__: true} = e, stack}) when is_list(stack),
    do: exception_text(e, stack)

  def exit_text(reason), do: "tool exited: " <> clip(inspect(reason, limit: 20))

  @doc """
  The model-facing body for a non-fatal failure.

  Keeps the existing `"Error:"` prefix convention — `finalize_result/5`'s
  `tool_failed` test, `Agent.Reminders`' self-correction collector, and
  `DoomLoop.FailureSignature` all key on it — and never double-prefixes.
  """
  @spec model_text(String.t()) :: String.t()
  def model_text(message) do
    msg = text(message)

    if String.starts_with?(msg, "Error:") or String.starts_with?(msg, "Blocked:") do
      msg
    else
      "Error: " <> msg
    end
  end

  @doc """
  Build the fatal 3-tuple result for a tool call.

  The `tool_msg`/`result_str` pair is a completely ordinary tool result (so
  message history and every `String.starts_with?(result_str, "Error:")` check
  keep working); the trailing `{:fatal, message}` is what makes the turn stop.
  """
  @spec fatal_result(map(), String.t()) :: {map(), String.t(), {:fatal, String.t()}}
  def fatal_result(tool_call, message) do
    body = model_text("fatal tool error — " <> text(message))

    {%{
       role: "tool",
       tool_call_id: Map.get(tool_call, :id),
       name: Map.get(tool_call, :name),
       content: body
     }, body, {:fatal, text(message)}}
  end

  @doc """
  Split a `[{tool_call, result}]` list into plain 2-tuple results plus the first
  fatal message (or `nil`).

  Fatal entries keep their synthesized tool message so the assistant's
  `tool_calls` are never left orphaned in history — the turn ends *after* the
  results are appended, exactly like Codex returns the tool output before
  surfacing `CodexErr::Fatal`.
  """
  @spec normalize_results([{map(), term()}]) :: {[{map(), {map(), String.t()}}], String.t() | nil}
  def normalize_results(results) when is_list(results) do
    Enum.map_reduce(results, nil, fn
      {tc, {tool_msg, result_str, {:fatal, message}}}, acc ->
        {{tc, {tool_msg, result_str}}, acc || message}

      entry, acc ->
        {entry, acc}
    end)
  end

  @doc """
  True when `result_str` is the record of an OPERATOR decision (a permission
  denial, a timed-out/cancelled approval, or a reject-with-steer) rather than a
  tool malfunction.

  These are model-readable results by design — the model is supposed to read
  the reason and pick another route — so they must NOT feed the doom-loop
  failure-signature detector, which would otherwise hard-halt the turn after
  three declines.
  """
  @spec user_decision?(String.t()) :: boolean()
  def user_decision?(result_str) when is_binary(result_str) do
    String.contains?(result_str, [
      "you declined to run",
      "denied and saved as a standing rule",
      "you asked to reconsider",
      "cancelled before approval",
      "timed out with no response",
      "requires interactive approval"
    ])
  end

  def user_decision?(_), do: false

  # ── private ──────────────────────────────────────────────────────────

  defp exception_text(e, stack) do
    where =
      case stack do
        [frame | _] -> " (" <> Exception.format_stacktrace_entry(frame) <> ")"
        _ -> ""
      end

    clip(Exception.message(e) <> where)
  rescue
    _ -> clip(inspect(e, limit: 20))
  end

  defp text(v) when is_binary(v), do: clip(v)
  defp text(v), do: clip(inspect(v, limit: 20))

  defp clip(s) when byte_size(s) > @max_reason_bytes,
    do: binary_part(s, 0, @max_reason_bytes) <> "… (truncated)"

  defp clip(s), do: s
end
