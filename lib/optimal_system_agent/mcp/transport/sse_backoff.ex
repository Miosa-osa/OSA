defmodule OptimalSystemAgent.MCP.Transport.SSEBackoff do
  @moduledoc """
  Pure exponential-backoff throttle for transport reconnects.

  Ported from grok's `xai-grok-mcp` `mcp_http_client.rs`: a naive reconnect
  loop that re-issues a stream request the instant it dies will hammer a broken
  server thousands of times a second (a flood-dead stream lives sub-millisecond).
  The fix distinguishes a *rapid* death — a connection that never reached a
  healthy, stable state — from a *stable* one that lived long enough (grok uses
  a 2s `STABLE_STREAM_THRESHOLD`) to be considered healthy.

  This is a pure state machine driven by two events the owner reports:

    * `observe_death(state, stable?)` — a connection just closed/failed.
      `stable?` says whether it had reached the healthy threshold first. A
      stable death RESETS the escalation (the next reconnect is quick, `base_ms`),
      so a normal idle-recycle never accrues delay; a rapid death (or a server
      that never connects at all) INCREMENTS it, so the delay grows
      `base_ms * 2^n`, capped at `max_ms`. Returns `{delay_ms, new_state}`.

    * `mark_stable(state)` — explicit reset, e.g. once a freshly established
      connection has survived the stability window.

  No processes, no sleeping, no clock reads: the owner decides *when* a
  connection counts as stable (typically via a timer armed after a successful
  handshake), which keeps every branch deterministic and unit-testable. OSA's
  `MCP.Client.ServerSession` is the production owner.
  """

  import Bitwise, only: [bsl: 2]

  @default_base_ms 1_000
  @default_max_ms 30_000
  @max_shift 16

  @type t :: %__MODULE__{
          base_ms: pos_integer(),
          max_ms: pos_integer(),
          consecutive: non_neg_integer()
        }

  defstruct base_ms: @default_base_ms, max_ms: @default_max_ms, consecutive: 0

  @doc "Build a throttle. Options override `:base_ms` and `:max_ms`."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      base_ms: Keyword.get(opts, :base_ms, @default_base_ms),
      max_ms: Keyword.get(opts, :max_ms, @default_max_ms)
    }
  end

  @doc """
  Record a connection death and return `{delay_ms, new_state}` for the next
  reconnect.

  `stable?` — did the connection reach a healthy, stable state before dying?
  A stable death resets escalation to zero (delay `base_ms`); a rapid death, or
  a server that never connected, escalates geometrically toward `max_ms`.
  """
  @spec observe_death(t(), boolean()) :: {pos_integer(), t()}
  def observe_death(%__MODULE__{} = s, stable?) do
    consecutive = if stable?, do: 0, else: s.consecutive + 1
    delay = delay_for(s, consecutive)
    {delay, %{s | consecutive: consecutive}}
  end

  @doc "Explicitly reset escalation (a connection is now considered healthy)."
  @spec mark_stable(t()) :: t()
  def mark_stable(%__MODULE__{} = s), do: %{s | consecutive: 0}

  @doc "The delay the next reconnect WOULD wait, without advancing state."
  @spec current_delay(t()) :: pos_integer()
  def current_delay(%__MODULE__{consecutive: n} = s), do: delay_for(s, n)

  @doc "Whether the throttle is in an escalated (rapid/down) episode."
  @spec escalated?(t()) :: boolean()
  def escalated?(%__MODULE__{consecutive: n}), do: n > 0

  # delay = base * 2^n, capped at max; the shift is clamped to avoid overflow.
  defp delay_for(%{base_ms: base, max_ms: max}, n) do
    exp = min(n, @max_shift)
    min(base * bsl(1, exp), max)
  end
end
