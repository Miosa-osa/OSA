defmodule OptimalSystemAgent.Sandbox.Health do
  @moduledoc """
  Sandbox health checking with exponential backoff retry.

  Before executing commands against a cloud sandbox (E2B, MIOSA, Vercel),
  `wait_for_ready/2` verifies the sandbox is actually responsive — not just
  "running" but able to execute a test command. This prevents the failure mode
  where a sandbox reports as running but is still booting, has exhausted
  resources, or has a dead command transport.

  ## Strategy

  1. Check if the backend is available (`available?/0`)
  2. Run a trivial test command (`echo ready`) with a short timeout
  3. If it fails, retry with exponential backoff + jitter
  4. Classify errors as permanent (auth, config) or transient (booting, rate limited)
  5. After max retries, return the last error

  ## Permanent vs transient errors

  Permanent errors (authentication failure, invalid template, invalid argument)
  are never retried — they will never succeed no matter how long we wait.
  Transient errors (sandbox booting, rate limited, network blip) are retried
  with backoff.

  ## Usage

      # Wait for the configured sandbox to be ready (default 5 retries)
      {:ok, :ready} = Sandbox.Health.wait_for_ready()
      # Now safe to execute the real command
      Sandbox.Router.execute("nmap -sS 10.0.0.1")

      # Custom retry count
      Sandbox.Health.wait_for_ready(max_retries: 10)

      # With a specific backend module
      Sandbox.Health.wait_for_ready(Sandbox.E2B, max_retries: 3)
  """

  require Logger

  alias OptimalSystemAgent.Sandbox.Router

  @default_max_retries 5
  @default_base_delay_ms 1_000
  @default_jitter_ms 100
  @health_check_command "echo ready"
  @health_check_timeout_ms 5_000

  @type health_result :: {:ok, :ready} | {:error, String.t()}

  @doc """
  Wait for the sandbox to become ready to execute commands.

  ## Options

    * `:max_retries` — maximum health check attempts (default: #{@default_max_retries})
    * `:base_delay_ms` — base delay for exponential backoff (default: #{@default_base_delay_ms}ms)
    * `:jitter_ms` — random jitter range (default: ±#{@default_jitter_ms}ms)
    * `:timeout_ms` — per-attempt command timeout (default: #{@health_check_timeout_ms}ms)
  """
  @spec wait_for_ready(keyword()) :: health_result()
  def wait_for_ready(opts \\ []) do
    backend = Router.backend()
    wait_for_ready(backend, opts)
  end

  @spec wait_for_ready(module(), keyword()) :: health_result()
  def wait_for_ready(backend, opts) when is_atom(backend) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    jitter_ms = Keyword.get(opts, :jitter_ms, @default_jitter_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @health_check_timeout_ms)

    do_wait_for_ready(backend, max_retries, base_delay_ms, jitter_ms, timeout_ms, nil)
  end

  # ── Retry loop ───────────────────────────────────────────────────────

  defp do_wait_for_ready(_backend, 0, _base, _jitter, _timeout, last_error) do
    reason = classify_error(last_error)
    Logger.warning("[Sandbox.Health] Sandbox not ready after all retries: #{reason}")
    {:error, "Sandbox not ready after all retries: #{reason}"}
  end

  defp do_wait_for_ready(backend, attempts_left, base_delay, jitter, timeout, _last_error) do
    attempt = @default_max_retries - attempts_left + 1

    case check_once(backend, timeout) do
      {:ok, :ready} ->
        Logger.info("[Sandbox.Health] Sandbox ready after attempt #{attempt}")
        {:ok, :ready}

      {:error, reason} = error ->
        if permanent_error?(reason) do
          Logger.warning("[Sandbox.Health] Permanent error, not retrying: #{reason}")
          error
        else
          delay = calculate_backoff(attempt, base_delay, jitter)

          Logger.debug(
            "[Sandbox.Health] Attempt #{attempt} failed (transient), retrying in #{delay}ms: #{reason}"
          )

          Process.sleep(delay)
          do_wait_for_ready(backend, attempts_left - 1, base_delay, jitter, timeout, reason)
        end
    end
  end

  # ── Single health check ──────────────────────────────────────────────

  defp check_once(backend, timeout_ms) do
    if not function_exported?(backend, :available?, 0) or not backend.available?() do
      {:error, "backend unavailable"}
    else
      task =
        Task.async(fn ->
          try do
            backend.execute(@health_check_command, timeout: timeout_ms)
          rescue
            e -> {:error, Exception.message(e)}
          end
        end)

      case Task.yield(task, timeout_ms + 2_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, output}} when is_binary(output) ->
          if String.contains?(output, "ready") do
            {:ok, :ready}
          else
            {:error, "health check returned unexpected output: #{String.slice(output, 0, 100)}"}
          end

        {:ok, {:error, reason}} ->
          {:error, reason}

        nil ->
          {:error, "health check timed out after #{timeout_ms}ms"}

        {:exit, _} ->
          {:error, "health check task crashed"}
      end
    end
  end

  # ── Error classification ──────────────────────────────────────────────

  # Permanent errors will never recover by retrying — fail fast.
  @permanent_patterns [
    "authentication",
    "unauthorized",
    "invalid api key",
    "forbidden",
    "template",
    "invalid argument",
    "not found",
    "sandbox not found"
  ]

  @spec permanent_error?(String.t()) :: boolean()
  def permanent_error?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)
    Enum.any?(@permanent_patterns, &String.contains?(normalized, &1))
  end

  def permanent_error?(_), do: false

  @spec classify_error(String.t() | nil) :: String.t()
  def classify_error(nil), do: "unknown"
  def classify_error(reason) when is_binary(reason), do: reason
  def classify_error(reason), do: inspect(reason)

  # ── Backoff calculation ──────────────────────────────────────────────

  @spec calculate_backoff(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def calculate_backoff(attempt, base_delay_ms, jitter_ms) do
    # Exponential: base * 2^(attempt-1) + random jitter
    # 1s, 2s, 4s, 8s, 16s with ±100ms jitter
    exponential = (base_delay_ms * :math.pow(2, attempt - 1)) |> round()
    # :rand.uniform/1 requires a positive integer — skip jitter when 0
    jitter = if jitter_ms > 0, do: :rand.uniform(jitter_ms * 2) - jitter_ms, else: 0
    max(0, exponential + jitter)
  end
end
