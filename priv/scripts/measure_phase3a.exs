#!/usr/bin/env elixir
# measure_phase3a.exs
# Measures actual token savings from Phase 3a lazy-loading (list_active vs list_tools_direct).
#
# Run with:
#   mix run priv/scripts/measure_phase3a.exs

alias OptimalSystemAgent.Tools.Registry

IO.puts("\n=== Phase 3a Token Savings Measurement ===\n")

# ── 1. Collect both tool sets ─────────────────────────────────────────────────

all_tools    = Registry.list_tools_direct()
active_tools = Registry.list_active()

IO.puts("Full tool set:   #{length(all_tools)} tools")
IO.puts("Active tool set: #{length(active_tools)} tools")
IO.puts("Deferred count:  #{length(all_tools) - length(active_tools)} tools")
IO.puts("")

# ── 2. Build Anthropic-format JSON payload (what the LLM provider sees) ───────
# Format mirrors Providers.Anthropic.format_tools/1:
#   %{"name" => ..., "description" => ..., "input_schema" => ...}

format_tools = fn tools ->
  Enum.map(tools, fn tool ->
    %{
      "name"         => tool.name,
      "description"  => tool.description,
      "input_schema" => tool.parameters
    }
  end)
end

all_payload    = format_tools.(all_tools)
active_payload = format_tools.(active_tools)

# ── 3. JSON-encode and measure bytes ─────────────────────────────────────────

all_json    = Jason.encode!(all_payload)
active_json = Jason.encode!(active_payload)

all_bytes    = byte_size(all_json)
active_bytes = byte_size(active_json)
saved_bytes  = all_bytes - active_bytes

IO.puts("--- Byte sizes (JSON-encoded tool array) ---")
IO.puts("Full set:    #{all_bytes} bytes")
IO.puts("Active set:  #{active_bytes} bytes")
IO.puts("Saved:       #{saved_bytes} bytes (#{Float.round(saved_bytes / all_bytes * 100, 1)}%)")
IO.puts("")

# ── 4. Token estimation ───────────────────────────────────────────────────────
# Anthropic tokeniser: ~4 bytes/token for English prose/JSON (cl100k_base approximation)
# This is the standard rough estimate used in cost projections.

bytes_per_token = 4

all_tokens    = div(all_bytes, bytes_per_token)
active_tokens = div(active_bytes, bytes_per_token)
saved_tokens  = all_tokens - active_tokens

IO.puts("--- Token estimates (bytes / #{bytes_per_token}) ---")
IO.puts("Full set:    ~#{all_tokens} tokens")
IO.puts("Active set:  ~#{active_tokens} tokens")
IO.puts("Saved/turn:  ~#{saved_tokens} tokens")
IO.puts("")

# ── 5. Daily/cost projections ─────────────────────────────────────────────────

turns_per_day    = 100
daily_tokens     = saved_tokens * turns_per_day
cost_per_1k      = 0.01   # $0.01 per 1k input tokens (conservative)
daily_dollars    = daily_tokens / 1000.0 * cost_per_1k

IO.puts("--- Projections at #{turns_per_day} turns/day ---")
IO.puts("Daily tokens saved:  #{daily_tokens} tokens")
IO.puts("Daily cost saved:    $#{Float.round(daily_dollars, 4)} (@ $#{cost_per_1k}/1k input tokens)")
IO.puts("")

# ── 6. Per-tool breakdown — top 5 heaviest schemas ───────────────────────────

IO.puts("--- Top 5 heaviest tool schemas (deferred tools) ---")

deferred_names = MapSet.new(all_tools, & &1.name) |> MapSet.difference(MapSet.new(active_tools, & &1.name))

all_with_bytes =
  Enum.map(all_tools, fn tool ->
    payload = %{
      "name"         => tool.name,
      "description"  => tool.description,
      "input_schema" => tool.parameters
    }
    {tool.name, byte_size(Jason.encode!(payload)), MapSet.member?(deferred_names, tool.name)}
  end)

top5 =
  all_with_bytes
  |> Enum.sort_by(fn {_name, bytes, _deferred} -> bytes end, :desc)
  |> Enum.take(5)

Enum.each(top5, fn {name, bytes, deferred} ->
  tokens    = div(bytes, bytes_per_token)
  tag       = if deferred, do: " [DEFERRED]", else: ""
  IO.puts("  #{name}#{tag}: #{bytes} bytes (~#{tokens} tokens)")
end)

IO.puts("")
IO.puts("--- Top 5 deferred tools by schema size ---")

top5_deferred =
  all_with_bytes
  |> Enum.filter(fn {_name, _bytes, deferred} -> deferred end)
  |> Enum.sort_by(fn {_name, bytes, _deferred} -> bytes end, :desc)
  |> Enum.take(5)

Enum.each(top5_deferred, fn {name, bytes, _} ->
  tokens = div(bytes, bytes_per_token)
  IO.puts("  #{name}: #{bytes} bytes (~#{tokens} tokens)")
end)

IO.puts("")

# ── 7. Summary ────────────────────────────────────────────────────────────────

IO.puts("=== SUMMARY ===")
IO.puts("Phase 3a reduces tool payload from #{all_bytes} bytes to #{active_bytes} bytes per turn.")
IO.puts("Saves ~#{saved_tokens} tokens/turn, ~#{daily_tokens} tokens/day (#{turns_per_day} turns).")
IO.puts("Estimated daily cost savings: $#{Float.round(daily_dollars, 4)} at $#{cost_per_1k}/1k tokens.")
IO.puts("")
