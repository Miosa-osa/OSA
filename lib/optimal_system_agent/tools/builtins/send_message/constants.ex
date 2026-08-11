defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Constants do
  @moduledoc """
  Exported constants for `send_message`.

  Other modules reference `tool_name/0` so a rename propagates automatically.

  ## Rate discipline

  A subagent that interrupts the user every thirty seconds is worse than one
  that never speaks: the channel stops being a signal and becomes noise, and
  the user starts ignoring it — including the one message that mattered. The
  numbers below are the whole design of the subagent voice, so they live here
  as named constants rather than as literals buried in the handler.
  """

  @tool_name "send_message"
  def tool_name, do: @tool_name

  @pending_table :osa_agent_messages
  def pending_table, do: @pending_table

  @doc """
  ETS table holding the per-sender send budget: `{sender_id, count, last_ms}`.
  """
  @budget_table :osa_agent_message_budget
  def budget_table, do: @budget_table

  @doc """
  Hard ceiling on interruptions per subagent run.

  Two is deliberate and small. A subagent's report is the channel for
  everything it learned; the live channel exists only for the things that are
  worthless if they arrive at the end. There are rarely two of those and never
  three.
  """
  @max_messages_per_run 2
  def max_messages_per_run, do: @max_messages_per_run

  @doc """
  Minimum gap between two messages from the same sender.

  Even inside the budget, two messages back to back read as a stream. A minute
  apart, they read as two separate things worth knowing.
  """
  @min_spacing_ms 60_000
  def min_spacing_ms, do: @min_spacing_ms

  @doc """
  Silence window at the start of a run.

  Nothing a subagent "discovers" in its first few tool calls is news — it is
  reading the files it was told to read. Speaking here is announcing that work
  has begun, which the user already knows.
  """
  @warmup_ms 30_000
  def warmup_ms, do: @warmup_ms

  @doc """
  Hard length cap on a subagent's interruption.

  TRUNCATION, never rejection: an over-long message is a message with a lead
  buried in it, and the lead is at the front. Rejecting it would lose the lead
  too and burn one of only two chances to say anything.
  """
  @max_message_chars 200
  def max_message_chars, do: @max_message_chars

  @doc """
  How long an undelivered parked message stays in the pending table.

  The bag is drained by the RECIPIENT's loop — so a message addressed to an
  agent that crashed, or that finished before its next iteration, is never
  drained and used to sit in ETS for the lifetime of the node. Sized well past
  any normal loop iteration so a live recipient always wins the race.
  """
  @pending_ttl_ms 30 * 60_000
  def pending_ttl_ms, do: @pending_ttl_ms
end
