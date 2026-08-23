defmodule OptimalSystemAgent.Events.TuiForwarder do
  @moduledoc """
  Bridges the internal `Events.Bus` to the per-session `osa:session:<id>` PubSub
  topic that the TUI actually streams.

  OSA has two disjoint event transports: the goldrush-compiled `Events.Bus`
  (fire-and-forget, wraps CloudEvents) and Phoenix.PubSub `osa:session:<id>`
  (what the SSE loop / TUI consumes). Only `tool_executor` bridged both, so
  anything emitted ONLY on the Bus — progress notes, steer injections, monitor
  fires, push notifications — was invisible in the TUI.

  This GenServer registers a single `Bus` handler on `:system_event` and
  re-broadcasts the events on an **allowlist** of Bus-only sub-events to the
  session topic as `{:osa_event, %{type: :system_event, event: <sub>, ...}}`.
  The allowlist prevents double-emitting events that a producer already
  broadcasts directly on the session topic (which would duplicate them and
  could feed back).

  Add new Bus-only sub-events to `@forward_events` to make them visible in the
  TUI without touching each emitter.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  # Sub-event names (the `:event` field inside a `:system_event` payload) that
  # are emitted ONLY on the Bus and should be surfaced to the TUI. Anything a
  # producer already broadcasts on the session topic (tool_call, orchestrator_*,
  # background_*) is intentionally NOT here to avoid duplicates.
  @forward_events ~w(
    ask_user
    progress_ledger
    steer_injected
    monitor_started
    monitor_fired
    push_notification
    subscribe_pr_registered
    goal_verifier_round
    goal_tracker_transition
    verification_gate_triggered
    announcement_continue
    announcement_continue_exhausted
    scratchpad_activity
    coordinator_mode
    ask_user_mode
    error
    hook_run
    hook_blocked
    fleet_node_started
    fleet_node_progress
    fleet_node_completed
    fleet_summary
    session_title
    model_switched
  )a

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    ref =
      Bus.register_handler(:system_event, fn payload ->
        forward(payload)
      end)

    Logger.debug("[TuiForwarder] bridging Bus :system_event → osa:session PubSub")
    {:ok, %{ref: ref}}
  end

  # Handler runs in a Bus-spawned Task; keep it pure + defensive.
  defp forward(payload) do
    data = payload_data(payload)
    sub = normalize_event(data[:event] || data["event"])
    session_id = data[:session_id] || data["session_id"] || payload[:session_id]

    if sub in @forward_events and is_binary(session_id) do
      {out_sub, out_data} = shape(sub, data)

      event =
        out_data
        |> Map.put(:type, :system_event)
        |> Map.put(:event, out_sub)
        |> Map.put(:session_id, session_id)

      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{session_id}",
        {:osa_event, event}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── Sub-event reshaping ───────────────────────────────────────────────
  #
  # Most sub-events pass through untouched. `ask_user` does NOT: the raw Bus
  # payload carries a `reply_to` PID (not JSON-encodable — the SSE loop would
  # drop the whole frame) and its `question`/`options` shape is not the wire
  # contract the TUI survey dialog decodes. Reshape it into the
  # `ask_user_question` survey frame the TUI already knows how to render.
  @doc false
  @spec shape(atom(), map()) :: {atom(), map()}
  def shape(:ask_user, data) do
    question = to_string(get(data, :question) || "")
    options = get(data, :options) || []
    ref = to_string(get(data, :ref) || "")

    {:ask_user_question,
     %{
       survey_id: ref,
       questions: [
         %{
           text: question,
           header: get(data, :header),
           multi_select: false,
           options: Enum.map(List.wrap(options), &survey_option/1),
           skippable: true
         }
       ],
       skippable: true
     }}
  end

  def shape(sub, data), do: {sub, data}

  # Options arrive as flat strings shaped "Label (Recommended) — why you'd pick
  # it". Split the label from its one-line rationale so the dialog can render
  # the description on its own dimmed row (Claude Code / Codex presentation).
  defp survey_option(opt) when is_map(opt) do
    %{
      label: to_string(get(opt, :label) || ""),
      description: get(opt, :description)
    }
  end

  defp survey_option(opt) do
    text = to_string(opt)

    case String.split(text, [" — ", " – ", " -- "], parts: 2) do
      [label, desc] -> %{label: String.trim(label), description: String.trim(desc)}
      _ -> %{label: String.trim(text), description: nil}
    end
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get(_, _), do: nil

  # The inner emit payload is carried in the CloudEvents `:data` field.
  defp payload_data(%{data: data}) when is_map(data), do: data
  defp payload_data(payload) when is_map(payload), do: payload
  defp payload_data(_), do: %{}

  defp normalize_event(e) when is_atom(e), do: e
  defp normalize_event(e) when is_binary(e), do: String.to_atom(e)
  defp normalize_event(_), do: nil
end
