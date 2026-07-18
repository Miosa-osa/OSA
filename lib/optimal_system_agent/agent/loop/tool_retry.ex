defmodule OptimalSystemAgent.Agent.Loop.ToolRetry do
  @moduledoc """
  Bounded retry-with-backoff for **transient** tool failures (P0-2).

  The tool layer historically did a single one-shot dispatch: a tool that
  flaked once (a network blip, an ephemeral lock, a `:timeout`, a 429/5xx from
  a tool-backed API, a transient `EAGAIN`) killed the step permanently. On a
  long build/test/run this turns a recoverable hiccup into a dead task.

  This module wraps a tool dispatch and retries **only** clearly-transient
  failures with jittered exponential backoff, up to a small bound.

  ## What it will NOT retry (fail fast)

  Semantic / deterministic failures are the model's mistake and retrying them
  is wasted work that risks corrupting state:

    * `old_string not found`, `ambiguous`, `not unique`, `identical`,
      `no changes`, `already exists`
    * validation / schema errors (`must read file first`, `invalid argument`)
    * permission denials (`Blocked:` / `permission denied` / `denied by a
      saved rule`)
    * a deterministic non-zero exit with no transient signature
      (e.g. `Exit 1: compilation error`)

  Classification is a **conservative allowlist** of transient signatures
  (`transient_tool_error?/1`), further guarded so anything that looks semantic
  is never retried even if a transient word happens to co-occur.

  ## Contract

  `run/2` takes a zero-arity `fun` that returns the raw `Tools.execute/2`
  result (`{:ok, ...}` | `{:error, reason}`) and returns the final result
  unchanged. On a transient `{:error, _}` it re-invokes `fun` after a backoff,
  up to `:max_attempts` total attempts.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  # Total attempts (initial + retries). 3 => up to 2 retries.
  @default_max_attempts 3

  # Base backoff in ms; actual delay = base * 2^(attempt-1) plus up to 100%
  # jitter, capped at @max_backoff_ms.
  @default_base_ms 60
  @max_backoff_ms 2_000

  @doc """
  Run `fun` (a zero-arity closure returning `Tools.execute/2`'s result),
  retrying transient `{:error, _}` outcomes with jittered backoff.

  Options:

    * `:max_attempts` — total attempts (default #{@default_max_attempts})
    * `:base_ms`      — base backoff, ms (default #{@default_base_ms}); `0`
      disables sleeping (used by tests)
    * `:tool`         — tool name, for telemetry
    * `:session_id`   — session, for telemetry
  """
  @spec run((-> term()), keyword()) :: term()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    attempt(fun, 1, opts)
  end

  defp attempt(fun, n, opts) do
    result = fun.()

    case result do
      {:error, reason} ->
        max = max_attempts(opts)

        if n < max and transient_tool_error?(reason) do
          delay = backoff_ms(n, opts)
          emit_retry(opts, n, max, reason, delay)

          Logger.info(
            "[tool-retry] transient failure on #{opts[:tool] || "tool"} " <>
              "(attempt #{n}/#{max}) — retrying in #{delay}ms: #{trim(reason)}"
          )

          if delay > 0, do: Process.sleep(delay)
          attempt(fun, n + 1, opts)
        else
          result
        end

      other ->
        other
    end
  end

  @doc """
  True only for a conservative allowlist of clearly-transient error
  signatures. Semantic/deterministic errors return `false` and are never
  retried.
  """
  @spec transient_tool_error?(term()) :: boolean()
  def transient_tool_error?(reason) do
    cond do
      # Semantic errors always fail fast, even if a transient word co-occurs.
      semantic_error?(reason) -> false
      is_atom(reason) -> transient_atom?(reason)
      true -> transient_text?(to_text(reason))
    end
  end

  # --- Classification helpers ---

  @transient_atoms ~w(
    timeout etimedout eagain econnreset econnrefused econnaborted
    closed nxdomain ehostunreach enetunreach enetreset epipe etxtbsy
    ebusy eintr enospc
  )a

  defp transient_atom?(atom), do: atom in @transient_atoms

  # Substrings that unambiguously indicate a retriable, non-deterministic
  # failure. Kept deliberately narrow.
  @transient_substrings [
    "timed out",
    "timeout",
    "temporarily unavailable",
    "resource temporarily unavailable",
    "connection reset",
    "connection refused",
    "connection closed",
    "connection aborted",
    "broken pipe",
    "econnreset",
    "econnrefused",
    "etimedout",
    "eagain",
    "text file busy",
    "etxtbsy",
    "resource busy",
    "device or resource busy",
    "temporary failure",
    "try again",
    "too many requests",
    "rate limit",
    "429",
    "502",
    "503",
    "504",
    "bad gateway",
    "service unavailable",
    "gateway timeout",
    "network is unreachable",
    "no space left",
    "lock",
    "deadlock"
  ]

  defp transient_text?(text) do
    down = String.downcase(text)
    Enum.any?(@transient_substrings, &String.contains?(down, &1))
  end

  # Mirrors ToolExecutor.semantic_tool_error?/1 — deterministic model mistakes
  # and hard denials. Retrying these is always wrong.
  @semantic_substrings [
    "not found in",
    "old_string not found",
    "ambiguous",
    "no match",
    "not unique",
    "identical",
    "already exists",
    "no changes",
    "must read",
    "read it first",
    "read the file first",
    "has not been read",
    "modified since read",
    "permission denied",
    "denied by a saved",
    "not permitted",
    "invalid argument",
    "invalid parameter",
    "missing required",
    "validation"
  ]

  defp semantic_error?(reason) when is_atom(reason), do: false

  defp semantic_error?(reason) do
    down = reason |> to_text() |> String.downcase()
    Enum.any?(@semantic_substrings, &String.contains?(down, &1))
  end

  defp to_text(reason) when is_binary(reason), do: reason
  defp to_text(reason), do: inspect(reason)

  defp trim(reason), do: reason |> to_text() |> String.slice(0, 160)

  defp max_attempts(opts) do
    case Keyword.get(opts, :max_attempts, @default_max_attempts) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_max_attempts
    end
  end

  # Jittered exponential backoff: base * 2^(attempt-1) + up to 100% jitter.
  defp backoff_ms(attempt, opts) do
    base =
      case Keyword.get(opts, :base_ms, @default_base_ms) do
        n when is_integer(n) and n >= 0 -> n
        _ -> @default_base_ms
      end

    if base == 0 do
      0
    else
      deterministic = base * Integer.pow(2, attempt - 1)
      jitter = :rand.uniform(max(deterministic, 1))
      min(deterministic + jitter, @max_backoff_ms)
    end
  end

  defp emit_retry(opts, attempt, max, reason, delay) do
    Bus.emit(:system_event, %{
      event: :tool_retry,
      tool: Keyword.get(opts, :tool),
      session_id: Keyword.get(opts, :session_id),
      attempt: attempt,
      max_attempts: max,
      delay_ms: delay,
      reason: trim(reason)
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
