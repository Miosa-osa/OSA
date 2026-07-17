defmodule OptimalSystemAgent.Tools.Builtins.Monitor.Handler do
  @moduledoc """
  Validation, permission, and execution for `monitor`.

  Implements 4 watch kinds: file, process, url, command. Execution is
  NON-BLOCKING: `execute/2` registers a supervised background watcher via
  `Monitor.WatchManager` and returns immediately with a `watch_id`. The watcher
  streams `monitor_fired` events (and injects a notification into the parent
  loop) on each occurrence — the agent's ReAct turn is never held. The polling
  sample/compare loop itself lives in `Monitor.WatchTask`.
  """

  alias OptimalSystemAgent.Monitor.WatchManager
  alias OptimalSystemAgent.Tools.Builtins.Monitor.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"kind" => kind, "target" => target} = input, _ctx)
      when is_binary(kind) and is_binary(target) and target != "" do
    duration = input["duration_seconds"]
    mode = input["mode"]

    cond do
      kind not in Constants.kinds() ->
        {:error, "kind must be one of: #{Enum.join(Constants.kinds(), ", ")}", -32_602}

      duration != nil and
          not (is_integer(duration) and duration > 0 and
                   duration <= Constants.max_duration_seconds()) ->
        {:error, "duration_seconds must be 1..#{Constants.max_duration_seconds()}", -32_602}

      mode != nil and mode not in Constants.modes() ->
        {:error, "mode must be one of: #{Enum.join(Constants.modes(), ", ")}", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"kind" => _, "target" => _}, _ctx),
    do: {:error, "kind and target must be non-empty strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: kind, target", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"kind" => "url", "target" => url} = input, _ctx) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and host != nil ->
        {:allow, input}

      _ ->
        {:deny, "Access denied: monitor target URL must be http(s) with a host"}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # Register a supervised background watcher and return immediately. The watcher
  # streams monitor_fired events + injects notifications into the parent loop on
  # each occurrence (see Monitor.WatchTask) instead of blocking this turn.
  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(input, ctx) do
    session_id = ctx && Map.get(ctx, :session_id)
    mode = Map.get(input, "mode", "once")
    duration_s = Map.get(input, "duration_seconds", 60)

    case WatchManager.start(input, session_id) do
      {:ok, watch_id} ->
        mode_note =
          if mode == "repeat",
            do:
              "It will report EACH occurrence for up to #{duration_s}s (mode=repeat). " <>
                "Stop early via monitor with a stop request if needed.",
            else: "It will report the FIRST change, then retire (mode=once)."

        {:ok,
         "Started background watch.\n" <>
           "- watch_id: #{watch_id}\n" <>
           "- watching: #{describe(input)}\n" <>
           "- mode: #{mode}\n\n" <>
           "The watch runs in the background; you'll be notified automatically when it " <>
           "fires (the change is injected into this conversation). #{mode_note}"}

      {:error, reason} ->
        {:error, "Failed to start watch: #{reason}"}
    end
  end

  defp describe(%{"kind" => k, "target" => t}), do: "#{k}:#{t}"
  defp describe(_), do: "<unknown>"
end
