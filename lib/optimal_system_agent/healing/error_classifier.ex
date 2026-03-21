defmodule OptimalSystemAgent.Healing.ErrorClassifier do
  @moduledoc """
  Classifies errors encountered by agent loops into actionable categories.

  Returns a `{category, severity, retryable?}` tuple used by the Healing
  Orchestrator to decide whether to attempt autonomous repair and how much
  urgency to assign.

  ## Categories

  | Category            | Description                                       |
  |---------------------|---------------------------------------------------|
  | `:tool_failure`     | A tool raised or returned an error               |
  | `:llm_error`        | Provider API error (rate limit, auth, timeout)   |
  | `:timeout`          | Operation exceeded its time budget               |
  | `:budget_exceeded`  | Spend limit was hit mid-session                  |
  | `:permission_denied`| Blocked by sandbox or OS-level permission guard  |
  | `:file_conflict`    | Write-before-read violation or merge conflict    |
  | `:assertion_failure`| Test or invariant assertion failed               |
  | `:unknown`          | Unrecognised error shape                         |

  ## Severity levels

  `:low` → `:medium` → `:high` → `:critical`
  """

  @type category ::
          :tool_failure
          | :llm_error
          | :timeout
          | :budget_exceeded
          | :permission_denied
          | :file_conflict
          | :assertion_failure
          | :unknown

  @type severity :: :low | :medium | :high | :critical

  @type classification :: {category(), severity(), retryable? :: boolean()}

  @doc """
  Classify an error into `{category, severity, retryable?}`.

  Accepts exceptions (structs with `__struct__` and `message` keys),
  maps with an `:error` or `:reason` key, atoms, or plain strings.
  """
  @spec classify(term()) :: classification()

  # ---- Struct/exception patterns ----

  def classify(%{__struct__: struct_mod} = error) do
    name = struct_mod |> Module.split() |> List.last()
    classify_by_name(name, Map.get(error, :message, inspect(error)))
  end

  # ---- Map patterns ----

  def classify(%{error: :budget_exceeded}), do: {:budget_exceeded, :high, false}
  def classify(%{error: :over_limit}), do: {:budget_exceeded, :high, false}

  def classify(%{error: :permission_denied}), do: {:permission_denied, :high, false}
  def classify(%{error: :eacces}), do: {:permission_denied, :medium, false}
  def classify(%{error: :sandbox_violation}), do: {:permission_denied, :high, false}

  def classify(%{error: :timeout}), do: {:timeout, :medium, true}
  def classify(%{error: :deadline_exceeded}), do: {:timeout, :medium, true}

  def classify(%{error: :file_conflict}), do: {:file_conflict, :medium, true}
  def classify(%{error: :write_before_read}), do: {:file_conflict, :low, true}

  def classify(%{error: reason} = error) when is_atom(reason) do
    classify_by_reason_atom(reason, error)
  end

  def classify(%{reason: reason} = error) when is_atom(reason) do
    classify_by_reason_atom(reason, error)
  end

  def classify(%{error: message}) when is_binary(message) do
    classify_string(message)
  end

  def classify(%{message: message}) when is_binary(message) do
    classify_string(message)
  end

  # ---- Atom patterns ----

  def classify(:budget_exceeded), do: {:budget_exceeded, :high, false}
  def classify(:over_limit), do: {:budget_exceeded, :high, false}
  def classify(:timeout), do: {:timeout, :medium, true}
  def classify(:eacces), do: {:permission_denied, :medium, false}
  def classify(:eperm), do: {:permission_denied, :high, false}
  def classify(:file_conflict), do: {:file_conflict, :medium, true}
  def classify(:write_before_read), do: {:file_conflict, :low, true}
  def classify(:rate_limited), do: {:llm_error, :medium, true}
  def classify(:unauthorized), do: {:llm_error, :critical, false}
  def classify(:assertion_failed), do: {:assertion_failure, :medium, true}

  # ---- String patterns ----

  def classify(message) when is_binary(message), do: classify_string(message)

  # ---- Catch-all ----

  def classify(_error), do: {:unknown, :medium, true}

  # -- Private helpers --

  defp classify_by_name(name, _message) when name in ~w(BudgetExceededError OverLimitError) do
    {:budget_exceeded, :high, false}
  end

  defp classify_by_name(name, _message) when name in ~w(TimeoutError DeadlineError) do
    {:timeout, :medium, true}
  end

  defp classify_by_name(name, _message)
       when name in ~w(PermissionDeniedError AccessDeniedError SandboxViolationError) do
    {:permission_denied, :high, false}
  end

  defp classify_by_name(name, _message) when name in ~w(FileConflictError WriteBeforeReadError) do
    {:file_conflict, :medium, true}
  end

  defp classify_by_name(name, _message)
       when name in ~w(AssertionError ExUnit.AssertionError RuntimeError) do
    {:assertion_failure, :medium, true}
  end

  defp classify_by_name(name, message)
       when name in ~w(APIError ProviderError LLMError HTTPError) do
    classify_llm_message(message)
  end

  defp classify_by_name(_name, message), do: classify_string(message)

  defp classify_by_reason_atom(reason, _error)
       when reason in [:rate_limited, :service_unavailable, :bad_gateway] do
    {:llm_error, :medium, true}
  end

  defp classify_by_reason_atom(reason, _error)
       when reason in [:unauthorized, :forbidden, :invalid_api_key] do
    {:llm_error, :critical, false}
  end

  defp classify_by_reason_atom(reason, _error)
       when reason in [:not_found, :tool_not_found, :tool_error] do
    {:tool_failure, :medium, true}
  end

  defp classify_by_reason_atom(reason, _error)
       when reason in [:nxdomain, :econnrefused, :closed] do
    {:llm_error, :high, true}
  end

  defp classify_by_reason_atom(_reason, _error), do: {:unknown, :medium, true}

  defp classify_string(message) when is_binary(message) do
    lower = String.downcase(message)

    cond do
      contains_any?(lower, ["budget exceeded", "over limit", "cost limit"]) ->
        {:budget_exceeded, :high, false}

      contains_any?(lower, ["rate limit", "too many requests", "429"]) ->
        {:llm_error, :medium, true}

      contains_any?(lower, ["unauthorized", "invalid api key", "403", "authentication"]) ->
        {:llm_error, :critical, false}

      contains_any?(lower, ["timeout", "timed out", "deadline", "took too long"]) ->
        {:timeout, :medium, true}

      contains_any?(lower, ["permission denied", "eacces", "eperm", "sandbox", "not allowed"]) ->
        {:permission_denied, :high, false}

      contains_any?(lower, ["file conflict", "write before read", "merge conflict", "already modified"]) ->
        {:file_conflict, :medium, true}

      contains_any?(lower, ["assertion", "assert", "expected", "test failed", "flunk"]) ->
        {:assertion_failure, :medium, true}

      contains_any?(lower, ["tool", "function call", "tool_call", "tool error", "tool failure"]) ->
        {:tool_failure, :medium, true}

      contains_any?(lower, ["llm", "provider", "model", "openai", "anthropic", "ollama"]) ->
        classify_llm_message(lower)

      true ->
        {:unknown, :medium, true}
    end
  end

  defp classify_llm_message(message) do
    lower = String.downcase(message)

    cond do
      contains_any?(lower, ["rate limit", "429", "too many requests"]) ->
        {:llm_error, :medium, true}

      contains_any?(lower, ["unauthorized", "401", "403", "invalid key"]) ->
        {:llm_error, :critical, false}

      contains_any?(lower, ["timeout", "timed out", "503", "unavailable"]) ->
        {:llm_error, :high, true}

      true ->
        {:llm_error, :medium, true}
    end
  end

  defp contains_any?(string, substrings) do
    Enum.any?(substrings, &String.contains?(string, &1))
  end
end
