defmodule OptimalSystemAgent.Providers.BudgetNoteCachePlacementTest do
  @moduledoc """
  The per-turn pacing note (`Agent.Loop.TurnBudget`) must never be the message
  a provider's `cache_control` breakpoint is measured against — it changes
  every single iteration (step count, token estimate, elapsed time), so if it
  were ever inside the cached region, the "stable prefix" a rolling breakpoint
  protects would change on every request instead of only when the
  conversation actually grows.

  These tests exercise `Providers.Registry.normalize_outbound_messages/3`
  directly — the one function that both places the rolling `cache_control`
  breakpoint (via `Providers.PromptCache.restructure/3`) and appends the
  budget note (`append_budget_note/2`) — so what is asserted is the actual
  wire-shaped output, not a claim about where a comment says it goes.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Registry

  @target {:compat, :openrouter}
  @model "anthropic/claude-sonnet-4.5"

  defp cached_system_message do
    %{
      role: "system",
      content: [
        %{"type" => "text", "text" => "static base", "cache_control" => %{"type" => "ephemeral"}},
        %{"type" => "text", "text" => "world state", "cache_control" => %{"type" => "ephemeral"}},
        # The unmarked volatile tail `PromptCache.restructure/3` relocates.
        %{"type" => "text", "text" => "clock/turn count"}
      ]
    }
  end

  defp history do
    [
      %{role: "user", content: "do the thing"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "1", name: "file_read", arguments: %{}}]
      },
      %{role: "tool", tool_call_id: "1", content: "file contents"}
    ]
  end

  defp has_cache_control?(msg) do
    case msg do
      %{content: parts} when is_list(parts) ->
        Enum.any?(parts, &Map.has_key?(&1, "cache_control"))

      _ ->
        false
    end
  end

  defp text_of(%{content: text}) when is_binary(text), do: text

  defp text_of(%{content: parts}) when is_list(parts) do
    parts |> Enum.map(&(Map.get(&1, "text") || Map.get(&1, :text))) |> Enum.join("\n")
  end

  test "the budget note is the last message and carries NO cache_control" do
    messages =
      Registry.normalize_outbound_messages(
        [cached_system_message() | history()],
        @target,
        model: @model,
        budget_note: "[Budget: step 3/100 (97 left) | tokens ~1k/150k (149k left) | elapsed 12s]"
      )

    last = List.last(messages)

    assert text_of(last) =~ "[Budget: step 3/100"
    refute has_cache_control?(last)
  end

  test "the note is wrapped as operating context, not raw user text" do
    messages =
      Registry.normalize_outbound_messages(
        [cached_system_message() | history()],
        @target,
        model: @model,
        budget_note: "[Budget: step 1/10 (9 left) | tokens ~0/60k (60k left) | elapsed 1s]"
      )

    last = List.last(messages)
    assert last.role == "user"
    assert text_of(last) =~ "<system-reminder>"
    assert text_of(last) =~ "</system-reminder>"
  end

  test "no cache_control marker ever lands on the budget note across two DIFFERENT notes" do
    base = [cached_system_message() | history()]

    turn1 =
      Registry.normalize_outbound_messages(base, @target,
        model: @model,
        budget_note: "[Budget: step 1/50 (49 left) | tokens ~0/150k (150k left) | elapsed 1s]"
      )

    turn2 =
      Registry.normalize_outbound_messages(base, @target,
        model: @model,
        budget_note: "[Budget: step 2/50 (48 left) | tokens ~500/150k (149k left) | elapsed 8s]"
      )

    refute has_cache_control?(List.last(turn1))
    refute has_cache_control?(List.last(turn2))

    # The message that DOES carry the breakpoint is identical across both
    # calls — the rolling breakpoint is unperturbed by a note that changes
    # every single iteration, which is the whole point.
    marked1 = Enum.find(turn1, &has_cache_control?/1)
    marked2 = Enum.find(turn2, &has_cache_control?/1)
    assert marked1 == marked2
  end

  test "no budget_note opt means no extra trailing message is appended" do
    base = [cached_system_message() | history()]
    without_note = Registry.normalize_outbound_messages(base, @target, model: @model)

    with_empty_note =
      Registry.normalize_outbound_messages(base, @target, model: @model, budget_note: "")

    assert length(without_note) == length(with_empty_note)
    refute Enum.any?(without_note, fn m -> text_of(m) =~ "[Budget:" end)
  end
end
