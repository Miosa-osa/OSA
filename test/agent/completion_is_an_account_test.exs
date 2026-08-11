defmodule OptimalSystemAgent.Agent.CompletionIsAnAccountTest do
  @moduledoc """
  The completion — the lead telling the user about it — is the most important
  part of delegation. These tests pin the two instructions that decide what the
  user actually gets, and the cost signal that rides the completion event.

  All three were places where the harness was actively working against the
  outcome it wanted: it told the lead to stop working, it accepted a bare
  "the agent finished" as compliance, and it threw the price away.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.TaskNotifications
  alias OptimalSystemAgent.Tools.Builtins.Delegate

  # ---------------------------------------------------------------------------
  # A1 — the launch result must not tell the lead to stop
  # ---------------------------------------------------------------------------

  describe "A1: the async-launch result" do
    test "never tells the lead it may end its response" do
      text = launch_text()

      refute text =~ "end your response",
             "Claude Code shipped this instruction and then REMOVED it (2.1.193): " <>
               "the launch result must not license the lead to stop working while a " <>
               "teammate runs."
    end

    test "tells the lead to keep working, and still forbids polling" do
      text = launch_text()

      assert text =~ "KEEP WORKING"
      assert text =~ "one clause"
      # The anti-poll discipline is the reason the instruction exists at all and
      # must survive the rewrite.
      assert text =~ "do NOT poll"
      assert text =~ "task_output"
      assert text =~ "do NOT read the output file"
    end

    test "still carries the handles the lead needs later" do
      text = launch_text()

      assert text =~ "agentId: agent:s1:1"
      assert text =~ "output_file: /tmp/agent-s1-1.md"
      assert text =~ "task_resume"
    end
  end

  # ---------------------------------------------------------------------------
  # A4 — an unmeasured cost is not a zero cost
  # ---------------------------------------------------------------------------

  describe "A4: reported cost" do
    test "a run with no recorded spend reports nil, not 0.0" do
      unknown = "agent:no-such-#{System.unique_integer([:positive])}:1"

      # The arithmetic accessor keeps its float contract for its callers...
      assert OptimalSystemAgent.Orchestrator.run_cost_usd(unknown) == 0.0

      # ...but the value that rides the event must distinguish "we never
      # measured this" from "this was free", or the TUI renders $0.00 for a
      # teammate whose price nobody knows.
      assert OptimalSystemAgent.Orchestrator.reported_cost_usd(unknown) == nil
    end
  end

  defp launch_text,
    do: Delegate.Handler.async_launch_notice("explore", "agent:s1:1", "/tmp/agent-s1-1.md")

  # ---------------------------------------------------------------------------
  # A2 — the completion notification must demand a synthesis
  # ---------------------------------------------------------------------------

  describe "A2: the completion notification" do
    test "demands an account in the model's own words, not a mention" do
      instruction = TaskNotifications.completion_instruction()

      assert instruction =~ "ACCOUNT"
      assert instruction =~ "IN YOUR OWN WORDS"
      # The four parts an account has to contain.
      assert instruction =~ "found"
      assert instruction =~ "changed"
      assert instruction =~ "means"
      assert instruction =~ "disagree"
    end

    test "forbids the two failure modes by name" do
      instruction = TaskNotifications.completion_instruction()

      assert instruction =~ "Do NOT paste",
             "pasting the report makes the user do the reading the delegation saved them"

      assert instruction =~ "the agent finished",
             "a bare status is the other failure mode and must be named"

      assert instruction =~ "not an account"
    end

    test "the instruction rides every rendered notification block" do
      xml =
        TaskNotifications.to_xml(%{
          task_id: "agent:s1:1",
          status: :completed,
          summary: "found three dead modules",
          output_file: "/tmp/x.md"
        })

      assert xml =~ "<task-notification>"
      assert xml =~ "found three dead modules"
      assert xml =~ TaskNotifications.completion_instruction()
    end

    test "still refuses to let the block leak into the user-facing reply" do
      instruction = TaskNotifications.completion_instruction()
      assert instruction =~ "never quote, repeat or paraphrase its markup"
    end
  end
end
