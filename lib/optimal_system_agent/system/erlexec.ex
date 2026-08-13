defmodule OptimalSystemAgent.System.Erlexec do
  @moduledoc """
  Lazy, failure-tolerant startup for `:erlexec` — the OS process manager behind
  the OpenComputers PTY executor.

  ## Why this module exists

  `:erlexec` ships a setuid-aware C port program (`exec-port`) that **refuses to
  start as root** unless an effective user was explicitly configured:

      Not allowed to run as root without setting effective user (-user option)!

  It used to be a plain runtime dependency, which meant OTP started it as part
  of `Application.ensure_all_started(:optimal_system_agent)`. As root, that start
  failed, `ensure_all_started/1` returned `{:error, ...}`, and
  `CLI.serve/0`/`CLI.chat/0` matched it against `{:ok, _}` and died with a
  `MatchError` before OSA had booted at all.

  Every stock Docker image runs as root, so this made OSA unable to boot in a
  container — for a feature (interactive PTY sessions) that a headless run never
  touches. The dependency is now declared `runtime: false` in `mix.exs` and
  shipped in the release with load-only mode, so nothing starts it implicitly;
  this module starts it on first use and reports a clear, one-time diagnostic
  when it cannot.

  ## Contract

  `ensure_started/0` is idempotent and never raises. It returns `:ok` when the
  application is running, `{:error, reason}` otherwise. Callers must degrade —
  the PTY executor answers `{:error, :exec_unavailable}` — rather than crash.
  """

  require Logger

  @app :erlexec

  # Cached across calls so a container that will never have erlexec does not
  # re-attempt the port spawn (and re-log) on every PTY request.
  @status_key {__MODULE__, :status}

  @doc """
  Start `:erlexec` if it is not already running.

  Returns `:ok` or `{:error, reason}`. Idempotent; the outcome is cached in
  `:persistent_term`, so the (possibly slow, definitely noisy) port spawn is
  attempted at most once per node.
  """
  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case :persistent_term.get(@status_key, nil) do
      nil ->
        status = do_start()
        :persistent_term.put(@status_key, status)
        status

      status ->
        status
    end
  end

  @doc "True when `:erlexec` is available for use (starting it if needed)."
  @spec available?() :: boolean()
  def available?, do: ensure_started() == :ok

  @doc """
  One-line human explanation of why erlexec is unavailable, or `nil` when it is
  available. Used by `doctor` and by the PTY executor's error path.
  """
  @spec unavailable_reason() :: String.t() | nil
  def unavailable_reason do
    case ensure_started() do
      :ok -> nil
      {:error, reason} -> describe(reason)
    end
  end

  @doc """
  Forget the cached status (tests, and any caller that has changed the
  environment erlexec depends on, e.g. dropped privileges).
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@status_key)
    :ok
  end

  @doc """
  True when this OS user is root (uid 0).

  Root is the single most common reason erlexec will not start, and it is worth
  naming explicitly in the diagnostic rather than surfacing
  `{:port_exited_with_status, 4}`.
  """
  @spec root?() :: boolean()
  def root? do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == "0"
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # ── internals ────────────────────────────────────────────────────────

  defp do_start do
    if match?({:win32, _}, :os.type()) do
      {:error, :unsupported_os}
    else
      start_app()
    end
  end

  defp start_app do
    case Application.ensure_all_started(@app) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[erlexec] PTY/native process execution is UNAVAILABLE: #{describe(reason)}. " <>
            "OSA runs normally without it — only OpenComputers interactive PTY sessions " <>
            "(pty_open) are affected."
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[erlexec] PTY/native process execution is UNAVAILABLE: #{inspect(e)}")
      {:error, e}
  catch
    _, reason ->
      Logger.warning("[erlexec] PTY/native process execution is UNAVAILABLE: #{inspect(reason)}")
      {:error, reason}
  end

  defp describe(:unsupported_os), do: "not supported on Windows (no C port program)"

  defp describe(reason) do
    base = inspect(reason)

    if root?() do
      "erlexec's port program refuses to run as root (#{base}) — this is expected " <>
        "inside a container; run OSA as a non-root user if you need PTY sessions"
    else
      base
    end
  end
end
