defmodule OptimalSystemAgent.Events.StrandedEventsTest do
  @moduledoc """
  Guards one bug SHAPE that this codebase produces repeatedly: something is
  wired but not connected.

  Confirmed instances, all found the same way — by something downstream being
  mysteriously empty:

    * `hook_blocked` was emitted for months and never drawn, because the
      forwarder allowlist is the only bridge from the Bus to a session topic
      and the name was missing. A hook that stopped a tool call stopped it
      silently.
    * `verification_gate_triggered` was emitted and forwarded nowhere, so the
      gate was invisible to the TUI, to SSE, and to every benchmark transcript.
      It was found while trying to test a hypothesis about it and discovering
      the question could not be answered.
    * `should_defer?` on a `@behaviour`-style tool module was read by nothing,
      so the declaration compiled, reviewed as correct, and deferred nothing.
    * `cached_tokens` was collected under a key `CacheAttribution` does not
      read.

  Every one of these is silent, and every one looks right in review. A test is
  the only thing that notices.

  ## What this test does and does not claim

  It asserts that events the TUI has a PARSER for, and which are emitted ONLY
  on the Bus, appear in the forwarder allowlist. A parser with no delivery path
  is the specific defect.

  It deliberately does not assert that every emitted event is forwarded. Most
  are not, correctly: the allowlist exists to avoid double-delivering events
  whose producer already broadcasts on the session topic, and a duplicate is
  its own bug. Nor does it claim an un-forwarded event is broken — the task
  panel, for instance, renders from tool results rather than from
  `task_created`.

  `@known_unforwarded` is therefore a real list, not a suppression: each entry
  needs a reason. Adding a name without one is how this test stops working.
  """
  use ExUnit.Case, async: true

  @forwarder "lib/optimal_system_agent/events/tui_forwarder.ex"
  @sse_parser "priv/rust/tui/src/client/sse.rs"

  # Bus-only events the TUI can parse but that are deliberately NOT forwarded.
  # Each needs a stated reason; "it seemed fine" is not one.
  @known_unforwarded %{
    # Rendered from the task_write / todos TOOL RESULT, not from the event.
    "task_created" => "task panel renders from tool results",
    "task_updated" => "task panel renders from tool results",
    "task_checklist_show" => "task panel renders from tool results",
    "task_checklist_hide" => "task panel renders from tool results",
    # These carry their own direct Phoenix.PubSub broadcast in their emitter.
    "compaction_started" => "CompactionEvents broadcasts directly",
    "compaction_completed" => "CompactionEvents broadcasts directly",
    "compaction_failed" => "CompactionEvents broadcasts directly",
    # Delivered through the permission/ask request-response path, not the feed.
    "permission_required" => "permission flow has its own delivery path",
    "ask_user_question" => "delivered as `ask_user`, which IS forwarded",
    "survey_answered" => "survey flow has its own delivery path",
    "plan_proposed" => "plan review has its own delivery path",
    # Orchestrator/background surfaces with dedicated broadcasts.
    "background_agent_started" => "background surface broadcasts directly",
    "swarm_started" => "orchestrator broadcasts directly",
    "budget_warning" => "surfaced via context_pressure / status bar",
    "budget_exceeded" => "surfaced via context_pressure / status bar",
    # Confirmed direct Phoenix.PubSub broadcasts in llm_client.ex.
    "streaming_token" => "llm_client broadcasts directly (type: :streaming_token)",
    "thinking_delta" => "llm_client broadcasts directly (type: :thinking_delta)",
    "provider_retry" => "parsed as a system_event sub-event by the SSE route",
    "cost_update" => "accounting broadcasts directly with type: :cost_update",
    "doom_loop_detected" =>
      "doom-loop recovery broadcasts directly with type: :doom_loop_detected",
    "overdrive_resumed" => "agent loop broadcasts directly as a system_event",
    "background_agent_failed" => "background surface broadcasts directly",
    "background_agent_stalled" => "background surface broadcasts directly",
    # Broadcast as {:osa_event, %{type: :background_agent_completed}} — see
    # background_notifier.ex:73. The audit's regex only sees the `event:` form,
    # which is why a name can look stranded and not be.
    "background_agent_completed" => "broadcast directly with type:, not event:",
    # UNRESOLVED, and left here rather than silently dropped.
    #
    # `context_pressure` is emitted ONLY via Bus.emit — no direct broadcast
    # anywhere in lib/ — and is not forwarded, yet the TUI context meter
    # demonstrably works and its percentages match the backend's own
    # `used_percent` arithmetic exactly (370.5k/1M read as 37.8%). Those two
    # facts cannot both be true through the path traced here, so one of them is
    # wrong and I could not establish which without a live session.
    #
    # Whoever gets there: either the meter is fed by a path this audit does not
    # know about, or it is running on stale/locally-derived numbers that happen
    # to look right. The second would be a real bug wearing a correct-looking
    # face, which is the whole subject of this test.
    "context_pressure" => "UNRESOLVED — see comment; meter works but path untraced"
  }

  defp forwarded_names do
    File.read!(@forwarder)
    |> String.split("@forward_events ~w(", parts: 2)
    |> List.last()
    |> String.split(")a", parts: 2)
    |> List.first()
    |> String.split()
    |> MapSet.new()
  end

  test "the forwarder allowlist is parseable and non-trivial" do
    names = forwarded_names()

    assert MapSet.size(names) > 5, "allowlist looks empty — the parser above is wrong"

    # The two confirmed regressions of this bug shape.
    assert MapSet.member?(names, "hook_blocked")
    assert MapSet.member?(names, "verification_gate_triggered")
  end

  test "every Bus-only event the TUI parses is either forwarded or documented" do
    sse = File.read!(@sse_parser)
    forwarded = forwarded_names()

    emitted =
      "lib"
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/event:\s*:([a-z_]+)/, File.read!(path), capture: :all_but_first)
      end)
      |> List.flatten()
      |> Enum.uniq()

    stranded =
      emitted
      |> Enum.filter(&String.contains?(sse, "\"#{&1}\""))
      |> Enum.reject(&MapSet.member?(forwarded, &1))
      |> Enum.reject(&Map.has_key?(@known_unforwarded, &1))
      |> Enum.sort()

    assert stranded == [],
           """
           These events have a TUI parser but no delivery path:

               #{Enum.join(stranded, "\n    ")}

           Either add the name to @forward_events, or add it to
           @known_unforwarded WITH the reason it reaches the client another way.
           An event nobody delivers is the `hook_blocked` bug again.
           """
  end
end
