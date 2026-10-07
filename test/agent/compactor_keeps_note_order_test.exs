defmodule OptimalSystemAgent.Agent.CompactorKeepsNoteOrderTest do
  @moduledoc """
  Only the leading system run (system prompt, earlier summary) is set aside
  by the compactor. A `role: "system"` note written mid-conversation stays
  where it was written.

  Reported live: every compaction pass lifted all 153 per-step notes of a
  session to the top of the transcript and exempted them from every step.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor

  test "micro-compaction keeps a mid-conversation system note in place" do
    messages = [
      %{role: "system", content: "You are OSA."},
      %{role: "user", content: "first"},
      %{role: "assistant", content: "ok"},
      %{role: "system", content: "[Output contract — inform] answer first"},
      %{role: "user", content: "second"}
    ]

    result = Compactor.micro_compact(messages)

    assert Enum.map(result, & &1.content) == Enum.map(messages, & &1.content)
  end
end
