defmodule OptimalSystemAgent.Security.Steer do
  @moduledoc """
  Interactive steering for live security runs (Tier 3 #14).

  Adapted from Strix's interactive-steering feature. While a pentest is in
  flight, the user can redirect the agent mid-run — narrow scope, change
  target priority, stop a noisy scan, ask to pivot to a different finding.
  The steer directive is stored per-session and read at the next agent-loop
  iteration boundary, then surfaced as a `system` message the agent acts on
  (the same mechanism `VerificationGate` uses for its grounded-verification
  directive).

  ## Lifecycle

  1. User (or an orchestrator) calls `Steer.inject/2` with a directive string.
  2. The agent loop, at the top of each iteration, calls `Steer.consume/1`.
  3. If a steer is pending, it returns `{:steer, directive}` and clears it —
     the loop injects it as a `system` message.
  4. If none pending, returns `:none` and the loop proceeds normally.

  This is non-destructive: the steer doesn't cancel the current turn, it
  shapes the next one. The agent sees it as an authoritative instruction.

  ## Usage

      Steer.inject(session_id, "Stop the nmap scan. Pivot to testing the /api/ endpoints on 10.0.0.5.")
      # ... at the next iteration boundary ...
      case Steer.consume(session_id) do
        {:steer, directive} -> # inject as system message
        :none -> # proceed normally
      end
  """

  require Logger

  alias OptimalSystemAgent.Security.SteerStore

  @type directive :: %{
          session_id: String.t(),
          body: String.t(),
          injected_at: DateTime.t(),
          source: String.t()
        }

  @doc "Inject a steer directive for a session. Overwrites any pending steer."
  @spec inject(String.t(), String.t(), keyword()) :: {:ok, directive()}
  def inject(session_id, body, opts \\ [])
      when is_binary(session_id) and is_binary(body) do
    source = Keyword.get(opts, :source, "user")

    directive = %{
      session_id: session_id,
      body: body,
      injected_at: DateTime.utc_now(),
      source: source
    }

    with {:ok, _} <- SteerStore.ensure_started(session_id) do
      SteerStore.put(session_id, directive)

      Logger.info(
        "[Steer] directive injected for session #{session_id}: #{String.slice(body, 0, 80)}"
      )

      {:ok, directive}
    end
  end

  @doc """
  Consume the pending steer directive for a session.

  Returns `{:steer, directive}` and clears it (one-shot), or `:none`.
  Called by the agent loop at the top of each iteration.
  """
  @spec consume(String.t()) :: {:steer, directive()} | :none
  def consume(session_id) when is_binary(session_id) do
    with {:ok, _} <- SteerStore.ensure_started(session_id) do
      case SteerStore.get(session_id) do
        {:ok, directive} ->
          SteerStore.clear(session_id)
          {:steer, directive}

        :none ->
          :none
      end
    else
      _ -> :none
    end
  end

  @doc "Check whether a steer is pending without consuming it."
  @spec pending?(String.t()) :: boolean()
  def pending?(session_id) when is_binary(session_id) do
    with {:ok, _} <- SteerStore.ensure_started(session_id),
         {:ok, _} <- SteerStore.get(session_id) do
      true
    else
      _ -> false
    end
  end

  @doc "Render a steer directive as a system message body for the agent."
  @spec render(directive()) :: String.t()
  def render(%{} = directive) do
    """
    <user_steer>
    The operator has redirected this run. Treat this as an authoritative instruction and adjust your current plan accordingly.

    Directive: #{directive.body}

    Source: #{directive.source}
    Injected at: #{DateTime.to_iso8601(directive.injected_at)}
    </user_steer>
    """
  end

  @doc "Clear any pending steer for a session."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    with {:ok, _} <- SteerStore.ensure_started(session_id) do
      SteerStore.clear(session_id)
    else
      _ -> :ok
    end
  end
end
