defmodule OptimalSystemAgent.Agent.SessionId do
  @moduledoc """
  The one generator for session ids that OSA mints itself.

  ## Why this exists

  Every entry point that needed an id for a *fresh* session used to build its own
  out of `System.unique_integer([:positive])` — `"headless_\#{n}"` in
  `mix osa.run`, `"sdk-\#{n}"`, `"http_\#{n}"`, `"tui_\#{n}"`,
  `"mcp_server_\#{n}"`. That counter is unique **within one BEAM instance**, and
  every `osa` invocation is its own BEAM, so it restarts from a small number on
  every boot. Measured on this machine across five fresh boots it produced
  `2564, 2567, 2566, 390, 10` — a few thousand values wide, non-monotonic, and
  re-entered on every run.

  Session ids are also persistence keys: `~/.osa/sessions/<id>.json` (the
  transcript `Loop.init/1` replays when no checkpoint exists),
  `<id>.spend.json` (the durable budget sidecar), `<id>.goal.json`,
  `<id>.updates.jsonl`. So a repeated id is not a cosmetic clash — a fresh run
  silently **inherits another session's conversation history and bill**. That was
  observed directly: two of six benchmark runs published spend records
  contaminated by an earlier session, and `~/.osa/sessions` still holds
  `headless_4`, `headless_8`, `headless_67`, `headless_71` — ids a later run will
  land on again.

  ## Reuse that is correct, and reuse that is not

  Reuse is a *feature* when it is asked for: `--resume <id>`, a `name:`-addressed
  teammate, and the per-conversation channel ids (`slack:<channel>`,
  `telegram:<chat>`) all mean "continue that session" and must keep working
  untouched. This module is only ever asked for a NEW id, so it can be strict in
  a way those paths cannot: it refuses to hand back an id that already has
  artifacts on disk.

  ## Shape

      <prefix>-<ms since epoch>-<12 hex chars of CSPRNG>

  The millisecond prefix keeps ids roughly time-ordered for humans and for
  `list/1`; the 48 random bits make a collision within the same millisecond
  ~1 in 2.8e14. `Runtime.SessionManager` already generated ids this way for
  exactly this reason — this module is that decision, made once and shared.

  ## The overwrite is impossible, not merely unlikely

  Random bits make a repeat improbable; they do not make it impossible, and a
  clock that steps backwards makes the timestamp non-unique too. So `generate/1`
  additionally *claims* the id: it checks `SessionPersistence.exists?/1` and
  draws again if anything is already on disk under that name. A draw that had to
  be repeated is a real collision averted, so it is logged at `warning` and
  emitted as telemetry rather than absorbed — the through-line of this class of
  defect is that the loss was silent.
  """

  require Logger

  alias OptimalSystemAgent.Agent.SessionPersistence

  # Enough attempts that exhausting them means something is structurally wrong
  # (an unwritable/unreadable sessions dir, a stuck clock), not bad luck.
  @max_attempts 5

  @doc """
  Mint a fresh, collision-proof session id.

  `prefix` names the entry point ("headless", "sdk", "http", "tui") and is
  sanitised to the characters the on-disk path preserves, so the id round-trips
  through `SessionPersistence`'s filename escaping unchanged.
  """
  @spec generate(String.t() | atom()) :: String.t()
  def generate(prefix \\ "session") do
    draw(safe_prefix(prefix), 1)
  end

  @doc """
  The id a caller asked for, or a fresh one.

  The single line every entry point wants: `SessionId.resolve(opts[:resume],
  "headless")`. An explicit id is returned verbatim — that is a resume, and
  reusing its artifacts is the entire point.
  """
  @spec resolve(String.t() | nil, String.t() | atom()) :: String.t()
  def resolve(explicit, _prefix) when is_binary(explicit) and explicit != "", do: explicit
  def resolve(_, prefix), do: generate(prefix)

  # ── Private ──────────────────────────────────────────────────────────

  defp draw(prefix, attempt) do
    candidate = mint(prefix)

    cond do
      not SessionPersistence.exists?(candidate) ->
        if attempt > 1 do
          Logger.warning(
            "[session_id] minted #{candidate} after #{attempt} attempts — " <>
              "#{attempt - 1} candidate id(s) already had artifacts on disk"
          )
        end

        candidate

      attempt >= @max_attempts ->
        # Every draw looked taken. Either the sessions dir is lying to us or the
        # clock is. Fall back to a strictly wider id rather than knowingly
        # returning a taken one, and say so loudly.
        forced = mint(prefix) <> "-" <> rand_hex(8)

        Logger.error(
          "[session_id] #{@max_attempts} generated ids all collided under prefix " <>
            "#{inspect(prefix)}; falling back to #{forced}. The sessions directory " <>
            "or the system clock is misbehaving."
        )

        emit_collision(prefix, attempt, :exhausted)
        forced

      true ->
        emit_collision(prefix, attempt, :retried)
        draw(prefix, attempt + 1)
    end
  end

  defp mint(prefix) do
    "#{prefix}-#{System.system_time(:millisecond)}-#{rand_hex(6)}"
  end

  defp rand_hex(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  defp emit_collision(prefix, attempt, outcome) do
    :telemetry.execute(
      [:osa, :session_id, :collision],
      %{attempt: attempt},
      %{prefix: prefix, outcome: outcome}
    )
  rescue
    # Telemetry must never be the reason a session fails to start.
    _ -> :ok
  end

  defp safe_prefix(prefix) do
    case Regex.replace(~r/[^a-zA-Z0-9_]/, to_string(prefix), "_") do
      "" -> "session"
      p -> p
    end
  end
end
