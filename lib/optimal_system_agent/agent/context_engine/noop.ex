defmodule OptimalSystemAgent.Agent.ContextEngine.Noop do
  @moduledoc """
  No-op context engine — never compacts.

  Useful for testing, debugging, or providers with very large context
  windows where compaction is unnecessary. Implements `ContextEngine`
  but always returns messages unchanged.
  """

  @behaviour OptimalSystemAgent.Agent.ContextEngine

  @impl true
  def maybe_compact(messages, _known_tokens \\ nil, _session_id \\ nil, _opts \\ []),
    do: messages

  @impl true
  def estimate_tokens(nil), do: 0

  def estimate_tokens(text) when is_binary(text) do
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    round(words * 1.3)
  end

  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_tokens(Map.get(msg, :content, ""))
    end)
  end

  # `:unknown`, not 0.0. This engine never compacts, so it has no window and no
  # honest denominator — and a hardcoded 0.0 would render as a status bar that
  # confidently reads "0% context used" on a session about to overflow.
  @impl true
  def utilization_percent(_messages, _context_window \\ nil), do: :unknown

  @impl true
  def micro_compact(messages), do: messages

  @impl true
  def format_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = Map.get(msg, :role, "unknown")
      content = Map.get(msg, :content, "")
      "[#{role}] #{content}"
    end)
    |> Enum.join("\n")
  end

  @impl true
  def stats, do: %{}
end
