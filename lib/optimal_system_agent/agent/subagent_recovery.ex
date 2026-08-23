defmodule OptimalSystemAgent.Agent.SubagentRecovery do
  @moduledoc """
  Subagent runtime recovery — retry with fallback model or fresh sandbox
  when a subagent fails.

  When a delegated subagent fails (model timeout, sandbox crash, rate limit),
  the parent agent can use this module to retry with:
  1. A fallback model (cheaper/faster model that's more likely to succeed)
  2. A fresh sandbox (if the sandbox was the problem)
  3. Reduced scope (if the task was too large)

  Adapted from HackerAI's `runtime-recovery.ts`.

  ## Usage

      case SubagentRecovery.recover(agent_id, failure_reason) do
        {:retry, %{model: fallback_model}} -> delegate(task, model: fallback_model)
        {:retry, %{fresh_sandbox: true}} -> delegate(task, sandbox: :fresh)
        {:fatal, reason} -> report_failure(reason)
      end
  """

  require Logger

  @max_recovery_attempts 2

  # Model fallback ladder: if the current model fails, try the next
  @model_fallback_ladder %{
    "opus" => "sonnet",
    "sonnet" => "haiku",
    "haiku" => nil,
    "elite" => "specialist",
    "specialist" => "utility",
    "utility" => nil
  }

  @doc "Maximum recovery attempts before giving up."
  @spec max_attempts() :: non_neg_integer()
  def max_attempts, do: @max_recovery_attempts

  @doc """
  Determine the recovery action for a failed subagent.

  Returns:
  - `{:retry, opts}` — retry with modified options (fallback model, fresh sandbox)
  - `{:fatal, reason}` — no recovery possible, report the failure
  """
  @spec recover(String.t(), String.t(), keyword()) :: {:retry, keyword()} | {:fatal, String.t()}
  def recover(agent_id, failure_reason, opts \\ []) do
    attempt = Keyword.get(opts, :recovery_attempt, 0)
    current_model = Keyword.get(opts, :model)

    if attempt >= @max_recovery_attempts do
      {:fatal,
       "Subagent #{agent_id} failed after #{attempt} recovery attempts: #{failure_reason}"}
    else
      recovery = classify_failure(failure_reason)

      case recovery do
        :model_failure ->
          fallback = fallback_model(current_model)

          if fallback do
            Logger.info("[SubagentRecovery] Retrying #{agent_id} with fallback model #{fallback}")
            {:retry, Keyword.merge(opts, model: fallback, recovery_attempt: attempt + 1)}
          else
            {:fatal, "No fallback model available for #{current_model}: #{failure_reason}"}
          end

        :sandbox_failure ->
          Logger.info("[SubagentRecovery] Retrying #{agent_id} with fresh sandbox")
          {:retry, Keyword.merge(opts, fresh_sandbox: true, recovery_attempt: attempt + 1)}

        :rate_limit ->
          Logger.info("[SubagentRecovery] Retrying #{agent_id} after rate limit backoff")
          {:retry, Keyword.merge(opts, recovery_attempt: attempt + 1, backoff_ms: 5_000)}

        :permanent ->
          {:fatal, "Permanent failure for #{agent_id}: #{failure_reason}"}

        :unknown ->
          # Unknown failures: try once more with no changes
          if attempt == 0 do
            {:retry, Keyword.merge(opts, recovery_attempt: 1)}
          else
            {:fatal, "Subagent #{agent_id} failed with unknown error: #{failure_reason}"}
          end
      end
    end
  end

  @doc "Get the fallback model for a given model name."
  @spec fallback_model(String.t() | nil) :: String.t() | nil
  def fallback_model(nil), do: nil

  def fallback_model(model) when is_binary(model) do
    normalized = String.downcase(model)

    Enum.find_value(@model_fallback_ladder, fn {key, value} ->
      if String.contains?(normalized, key), do: value
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp classify_failure(reason) do
    normalized = String.downcase(reason)

    cond do
      String.contains?(normalized, "timeout") or String.contains?(normalized, "timed out") ->
        :model_failure

      String.contains?(normalized, "sandbox") or String.contains?(normalized, "container") or
        String.contains?(normalized, "e2b") or String.contains?(normalized, "microvm") ->
        :sandbox_failure

      String.contains?(normalized, "rate limit") or String.contains?(normalized, "429") or
          String.contains?(normalized, "too many requests") ->
        :rate_limit

      String.contains?(normalized, "authentication") or
        String.contains?(normalized, "unauthorized") or
        String.contains?(normalized, "invalid key") or
        String.contains?(normalized, "content_filter") or
          String.contains?(normalized, "content-filter") ->
        :permanent

      true ->
        :unknown
    end
  end
end
