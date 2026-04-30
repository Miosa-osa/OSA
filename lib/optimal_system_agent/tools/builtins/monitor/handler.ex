defmodule OptimalSystemAgent.Tools.Builtins.Monitor.Handler do
  @moduledoc """
  Validation, permission, and execution for `monitor`.

  Implements 4 watch kinds: file, process, url, command. All polling is
  cooperative — the agent's abort signal terminates within one poll tick.
  """

  alias OptimalSystemAgent.Tools.Builtins.Monitor.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"kind" => kind, "target" => target} = input, _ctx)
      when is_binary(kind) and is_binary(target) and target != "" do
    duration = input["duration_seconds"]

    cond do
      kind not in Constants.kinds() ->
        {:error, "kind must be one of: #{Enum.join(Constants.kinds(), ", ")}", -32_602}

      duration != nil and
          not (is_integer(duration) and duration > 0 and
                   duration <= Constants.max_duration_seconds()) ->
        {:error, "duration_seconds must be 1..#{Constants.max_duration_seconds()}", -32_602}

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

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(input, %UseContext{abort_ref: abort_ref}) do
    duration_s = Map.get(input, "duration_seconds", 60)
    poll_ms = Map.get(input, "poll_interval_ms", Constants.default_poll_interval_ms())

    deadline_ms = System.monotonic_time(:millisecond) + duration_s * 1_000

    initial = sample(input)
    started_at = System.monotonic_time(:millisecond)
    watch_loop(input, initial, deadline_ms, poll_ms, abort_ref, started_at)
  end

  # ── Polling loop ──────────────────────────────────────────────────────

  defp watch_loop(input, initial, deadline_ms, poll_ms, abort_ref, started_at) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline_ms ->
        elapsed = format_duration(now - started_at)
        {:ok, "monitor: timeout after #{elapsed}, no change observed (target=#{describe(input)})"}

      aborted?(abort_ref) ->
        elapsed = format_duration(now - started_at)
        {:ok, "monitor: interrupted after #{elapsed} (target=#{describe(input)})"}

      true ->
        Process.sleep(min(poll_ms, deadline_ms - now))

        case sample(input) do
          ^initial ->
            watch_loop(input, initial, deadline_ms, poll_ms, abort_ref, started_at)

          new_value ->
            elapsed = format_duration(System.monotonic_time(:millisecond) - started_at)

            {:ok,
             "monitor: change detected after #{elapsed} (target=#{describe(input)})\n" <>
               "  before: #{inspect(initial)}\n" <>
               "  after:  #{inspect(new_value)}"}
        end
    end
  end

  # ── Samplers ──────────────────────────────────────────────────────────

  defp sample(%{"kind" => "file", "target" => path}) do
    case File.stat(Path.expand(path)) do
      {:ok, %{mtime: m, size: s}} -> {:file, m, s}
      {:error, reason} -> {:file_error, reason}
    end
  end

  defp sample(%{"kind" => "process", "target" => target}) do
    pid = parse_pid(target)
    {:process, pid && Process.alive?(pid)}
  end

  defp sample(%{"kind" => "url", "target" => url}) do
    request = Finch.build(:get, url)

    case Finch.request(request, OptimalSystemAgent.Finch, receive_timeout: 5_000) do
      {:ok, %{status: status}} -> {:url, status}
      {:error, reason} -> {:url_error, inspect(reason)}
    end
  rescue
    e -> {:url_error, Exception.message(e)}
  end

  defp sample(%{"kind" => "command", "target" => cmd}) do
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {output, code} -> {:command, code, output |> String.trim_trailing() |> String.slice(0, 200)}
    end
  rescue
    e -> {:command_error, Exception.message(e)}
  end

  defp parse_pid(target) do
    pid_str = String.trim_leading(target, "#PID")

    try do
      :erlang.list_to_pid(String.to_charlist(pid_str))
    rescue
      _ -> nil
    end
  end

  defp aborted?(nil), do: false
  defp aborted?(pid) when is_pid(pid), do: not Process.alive?(pid)
  defp aborted?(_), do: false

  defp describe(%{"kind" => k, "target" => t}), do: "#{k}:#{t}"
  defp describe(_), do: "<unknown>"

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_duration(ms) do
    s = div(ms, 1_000)
    "#{div(s, 60)}m#{rem(s, 60)}s"
  end
end
