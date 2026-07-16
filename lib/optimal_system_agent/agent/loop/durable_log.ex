defmodule OptimalSystemAgent.Agent.Loop.DurableLog do
  @moduledoc """
  Per-step durable write record + idempotency keys for crash-recovery
  (primitive #27).

  Complements `Loop.Checkpoint` (which snapshots *whole-iteration* state) with a
  finer-grained, append-only log of *individual completed tool-call steps*.

  Inspired by two established patterns:

    * **LangGraph `put_writes`** — durably record each node's writes the instant
      it finishes, before advancing, so a replay never redoes committed work.
    * **Temporal idempotency keys** — give each activity a stable dedup key so a
      replayed activity returns its recorded result instead of re-executing side
      effects.

  ## Why the checkpoint alone is not enough

  `Checkpoint.checkpoint_state/1` is written *after* a whole tool batch completes
  (`ReactLoop.handle_result/3`). If the backend crashes *mid-batch* — some tools
  ran, some did not — the restored checkpoint predates the batch, so on resume
  the loop re-issues the *entire* batch and every already-executed tool runs a
  second time (double writes, double shells, double API calls).

  The durable log records each tool step the moment it completes. On resume, a
  tool call whose idempotency key is already recorded returns the **recorded**
  result and is **not** re-executed. Guarantees:

    * **exactly-once** in the common case (the model reproduces the same call for
      the interrupted step), and
    * **at-least-once** in the worst case (the model produces a *different* call
      on replay, so the old side effect is orphaned and the new call runs).

  ## Storage

  Append-only JSONL, one file per session under `durable_log_dir/`. Append-only
  is deliberately crash-safe: a torn final line loses at most the last step, and
  `load/1` simply skips unparseable lines. Files are per-turn and cleared at the
  turn boundary (`clear/1`), so they stay small.

  ## Additive by construction

  When `:durable_execution` is disabled, or a session id is missing, every
  function degrades to a no-op / miss and callers run tools exactly as before —
  normal runs simply get the extra durable writes.
  """
  require Logger

  @type key :: String.t()
  @type entry :: %{
          key: key(),
          tool_name: String.t() | nil,
          content: String.t(),
          result: String.t(),
          completed_at: String.t() | nil
        }

  @doc "Whether durable execution recording/replay is enabled (default: true)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :durable_execution, true)
  end

  @doc "Directory where per-session durable logs are stored."
  @spec durable_dir() :: String.t()
  def durable_dir do
    Application.get_env(:optimal_system_agent, :durable_log_dir, "~/.osa/durable")
    |> Path.expand()
  end

  @doc "Full path to the durable log file for a session."
  @spec log_path(String.t()) :: String.t()
  def log_path(session_id) do
    Path.join(durable_dir(), "#{session_id}.jsonl")
  end

  @doc """
  Deterministic idempotency key for a tool step.

  Stable across a crash+resume: derived from the logical position of the step
  (session turn + iteration) plus the tool name and canonicalised arguments —
  NOT the provider-assigned `tool_call.id`, which is regenerated on replay.
  """
  @spec step_key(map(), map()) :: key()
  def step_key(state, tool_call) when is_map(state) and is_map(tool_call) do
    turn = Map.get(state, :turn_count, 0)
    iter = Map.get(state, :iteration, 0)
    name = Map.get(tool_call, :name, "unknown")
    args_canon = canonical(Map.get(tool_call, :arguments, %{}))

    digest =
      :crypto.hash(:sha256, "#{name}\n#{args_canon}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "t#{turn}-i#{iter}-#{name}-#{digest}"
  end

  @doc """
  Run `fun` exactly once per idempotency key, durably.

  On a recorded (already-completed) key, returns the recorded
  `{tool_msg, result_str}` **without invoking `fun`** — the side effect already
  happened before the crash. On a miss, invokes `fun`, durably records a
  *successful* result, and returns it. Errored / blocked results are NOT
  recorded, so they get a fresh attempt on resume. When disabled or when the
  session id is missing, always invokes `fun` (pure passthrough).

  `fun` must return the `{tool_msg, result_str}` contract used by the loop.
  """
  @spec run_once(map(), map(), (-> {map(), String.t()})) :: {map(), String.t()}
  def run_once(state, tool_call, fun) when is_function(fun, 0) do
    session_id = Map.get(state, :session_id)

    if enabled?() and is_binary(session_id) do
      key = step_key(state, tool_call)

      case Map.fetch(load(session_id), key) do
        {:ok, entry} ->
          Logger.info(
            "[loop] Durable replay: #{Map.get(tool_call, :name)} step #{key} already " <>
              "completed — returning recorded result (skipping re-execution)"
          )

          emit_replay(state, tool_call, key)
          {replay_msg(tool_call, entry.content), entry.result}

        :error ->
          {tool_msg, result_str} = result = fun.()
          if success?(result_str), do: record(session_id, key, tool_call, tool_msg, result_str)
          result
      end
    else
      fun.()
    end
  end

  @doc """
  Durably record that a tool step completed with the given result.

  Appended as one JSONL line. No-op when disabled or when the session id is
  missing. Never raises — a failed durable write degrades to normal at-least-once
  execution and is logged.
  """
  @spec record(String.t() | nil, key(), map(), map(), String.t()) :: :ok
  def record(session_id, key, tool_call, tool_msg, result_str) when is_binary(session_id) do
    if enabled?() do
      entry = %{
        "key" => key,
        "tool_name" => Map.get(tool_call, :name),
        "content" => msg_content_string(tool_msg, result_str),
        "result" => sanitize(result_str),
        "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.mkdir_p!(durable_dir())
      File.write!(log_path(session_id), Jason.encode!(entry) <> "\n", [:append])
      :ok
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[loop] Durable log write failed: #{Exception.message(e)}")
      :ok
  end

  def record(_session_id, _key, _tool_call, _tool_msg, _result_str), do: :ok

  @doc "Load all recorded steps for a session as a `%{key => entry}` map (last write wins)."
  @spec load(String.t() | nil) :: %{optional(key()) => entry()}
  def load(session_id) when is_binary(session_id) do
    path = log_path(session_id)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(%{}, fn line, acc ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"key" => k} = m} ->
            Map.put(acc, k, %{
              key: k,
              tool_name: m["tool_name"],
              content: m["content"] || m["result"] || "",
              result: m["result"] || "",
              completed_at: m["completed_at"]
            })

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  def load(_session_id), do: %{}

  @doc "Whether a step key is already recorded as completed."
  @spec completed?(String.t() | nil, key()) :: boolean()
  def completed?(session_id, key), do: Map.has_key?(load(session_id), key)

  @doc "Number of recorded steps for a session (0 if none / disabled)."
  @spec step_count(String.t() | nil) :: non_neg_integer()
  def step_count(session_id), do: map_size(load(session_id))

  @doc "Delete the durable log for a session (turn / session boundary cleanup)."
  @spec clear(String.t() | nil) :: :ok
  def clear(session_id) when is_binary(session_id) do
    File.rm(log_path(session_id))
    :ok
  rescue
    _ -> :ok
  end

  def clear(_session_id), do: :ok

  # --- Private ---

  # A result string is "successful" unless it uses the loop's error/blocked
  # sentinels (see ToolExecutor.finalize_result/5 and ReactLoop). Only
  # successful steps are recorded, so a transient failure re-runs on resume.
  defp success?(s) when is_binary(s) do
    not (String.starts_with?(s, "Error:") or String.starts_with?(s, "Blocked:"))
  end

  defp success?(_), do: true

  # Rebuild a text tool message for replay, bound to the CURRENT tool_call.id
  # (the recorded id is stale after a resume). Content is always a string, so
  # replay is provider-safe even when the original result was an image block.
  defp replay_msg(tool_call, content) do
    %{
      role: "tool",
      tool_call_id: Map.get(tool_call, :id),
      name: Map.get(tool_call, :name),
      content: content
    }
  end

  # Persist the exact string content that was appended to the transcript for
  # text tools; fall back to the (already-normalised) result string for image /
  # structured tool messages whose content is a list of blocks.
  defp msg_content_string(tool_msg, result_str) do
    case Map.get(tool_msg, :content) do
      content when is_binary(content) -> sanitize(content)
      _ -> sanitize(result_str)
    end
  end

  # Order-independent, deterministic serialisation of tool arguments so the
  # idempotency key is stable regardless of map key ordering.
  defp canonical(v) when is_map(v) do
    inner =
      v
      |> Enum.map(fn {k, val} -> {to_string(k), val} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, val} -> "#{encode_scalar(k)}:#{canonical(val)}" end)

    "{" <> inner <> "}"
  end

  defp canonical(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &canonical/1) <> "]"
  defp canonical(v), do: encode_scalar(v)

  defp encode_scalar(v) do
    Jason.encode!(v)
  rescue
    _ -> inspect(v)
  end

  defp sanitize(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8) do
      {:error, valid, _} -> valid
      {:incomplete, valid, _} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp sanitize(other), do: to_string(other)

  defp emit_replay(state, tool_call, key) do
    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :durable_replay,
      session_id: Map.get(state, :session_id),
      tool: Map.get(tool_call, :name),
      step_key: key
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
