defmodule OptimalSystemAgent.Commands.Config do
  @moduledoc """
  Configuration-related commands: verbose, plan, think, config, compact, usage.
  """

  require Logger

  @doc "Handle the `/verbose` command."
  def cmd_verbose(_arg, session_id) do
    current = OptimalSystemAgent.Commands.get_setting(session_id, :verbose, false)
    new_value = !current
    OptimalSystemAgent.Commands.put_setting(session_id, :verbose, new_value)
    {:command, "Verbose mode: #{if new_value, do: "on", else: "off"}"}
  end

  @doc "Handle the `/plan` command."
  def cmd_plan(_arg, session_id) do
    case GenServer.call(
           {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}},
           :toggle_plan_mode
         ) do
      {:ok, true} ->
        {:command, "Plan mode enabled — complex tasks will show plans for approval"}

      {:ok, false} ->
        {:command, "Plan mode disabled — all tasks execute immediately"}
    end
  rescue
    _ -> {:command, "Plan mode toggle failed — no active session"}
  end

  @doc "Handle the `/think` command."
  def cmd_think(arg, session_id) do
    level = String.trim(arg) |> String.downcase()

    case level do
      "" ->
        current = OptimalSystemAgent.Commands.get_setting(session_id, :think_level, "normal")
        {:command, "Current reasoning depth: #{current}\n\nUsage: /think fast|normal|deep"}

      l when l in ["fast", "normal", "deep"] ->
        OptimalSystemAgent.Commands.put_setting(session_id, :think_level, l)

        desc =
          case l do
            "fast" -> "quick responses, minimal deliberation"
            "normal" -> "balanced reasoning and speed"
            "deep" -> "thorough analysis, extended thinking"
          end

        {:command, "Reasoning depth: #{l} (#{desc})"}

      _ ->
        {:command, "Unknown level: #{level}\n\nUsage: /think fast|normal|deep"}
    end
  end

  @doc "Handle the `/config` command."
  def cmd_config(_arg, session_id) do
    verbose = OptimalSystemAgent.Commands.get_setting(session_id, :verbose, false)
    think = OptimalSystemAgent.Commands.get_setting(session_id, :think_level, "normal")
    provider = Application.get_env(:optimal_system_agent, :default_provider, "unknown")
    max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
    max_iter = Application.get_env(:optimal_system_agent, :max_iterations, 30)
    http_port = Application.get_env(:optimal_system_agent, :http_port, 8089)
    sandbox = Application.get_env(:optimal_system_agent, :sandbox_enabled, false)

    output =
      """
      Runtime Configuration:
        session:       #{session_id}
        verbose:       #{verbose}
        think level:   #{think}
        provider:      #{provider}
        max tokens:    #{format_number(max_tokens)}
        max iterations: #{max_iter}
        http port:     #{http_port}
        sandbox:       #{sandbox}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/compact` command."
  def cmd_compact(_arg, _session_id) do
    stats = OptimalSystemAgent.Agent.Compactor.stats()

    output =
      """
      Context Compactor:
        compactions:     #{stats[:compaction_count] || 0}
        tokens saved:    #{stats[:tokens_saved] || 0}
        last compacted:  #{OptimalSystemAgent.Commands.Info.format_timestamp(stats[:last_compacted_at])}
        pipeline steps:  #{OptimalSystemAgent.Commands.Info.format_pipeline_steps(stats[:pipeline_steps_used])}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/usage` command."
  def cmd_usage(_arg, session_id) do
    compactor_stats = OptimalSystemAgent.Agent.Compactor.stats()
    memory_stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

    context_line =
      try do
        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] ->
            state = :sys.get_state(pid)
            estimated = OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
            util = if max_tokens > 0, do: Float.round(estimated / max_tokens * 100, 1), else: 0.0
            bar = context_utilization_bar(util)
            "  context now:   #{bar} #{format_number(estimated)}/#{format_number(max_tokens)} (#{util}%)"

          _ ->
            nil
        end
      rescue
        _ -> nil
      end

    lines = [
      "Token Usage:",
      "  max context:     #{format_number(max_tokens)} tokens",
      "  tokens saved:    #{format_number(compactor_stats[:tokens_saved] || 0)} (via compaction)",
      "  compactions:     #{compactor_stats[:compaction_count] || 0}",
      "  sessions stored: #{memory_stats[:session_count] || 0}",
      "  memory on disk:  #{format_bytes(memory_stats[:long_term_size] || 0)}"
    ]

    lines =
      if context_line,
        do: [Enum.at(lines, 0)] ++ [context_line] ++ Enum.drop(lines, 1),
        else: lines

    {:command, Enum.join(lines, "\n")}
  end

  # ── Formatting Helpers ──────────────────────────────────────────

  @doc false
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(n), do: "#{n}"

  @doc false
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  def format_bytes(_), do: "0 bytes"

  @doc false
  def context_utilization_bar(util) do
    filled = round(util / 5) |> min(20) |> max(0)
    empty = 20 - filled

    cond do
      util >= 90.0 ->
        "#{IO.ANSI.red()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"

      util >= 70.0 ->
        "#{IO.ANSI.yellow()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"

      true ->
        "#{IO.ANSI.green()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"
    end
  end
end
