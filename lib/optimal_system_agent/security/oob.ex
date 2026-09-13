defmodule OptimalSystemAgent.Security.Oob do
  @moduledoc """
  Out-of-band listener poll loop for blind SSRF/XSS/SQLi callbacks.

  This is not a callback implant. The agent already writes payloads; this
  module starts a listener, exposes the callback host that must be injected
  *before* a blind payload is sent, and polls for hits. No C2. No exploit
  strings.

  Session-scoped ETS (`:osa_security_oob`), same custody pattern as Evidence.
  Production talks to `interactsh-client` through an injectable runner so tests
  never open a socket.

  ## Start twice

  `start/2` is idempotent while a session is `:running`. A second start on
  the same `session_id` returns the existing session and does not call the
  runner, so a host already baked into a payload is not rotated. After
  `stop/1`, start replaces the session with a new host.
  """

  @table :osa_security_oob
  @missing_client "interactsh-client not found"
  @not_started "start oob before blind payload"
  @no_session "no oob session"
  @stopped "oob session stopped"
  @no_hits "no oob hits"
  @no_host "no oob host in interactsh output"

  @host_re ~r/[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+/
  @received_re ~r/Received\s+(\w+)\s+from\s+(\S+)/i

  @type hit :: %{
          id: String.t(),
          protocol: String.t(),
          remote: String.t() | nil,
          raw: String.t(),
          at: DateTime.t()
        }

  @type session :: %{
          id: String.t(),
          host: String.t(),
          started_at: DateTime.t(),
          hits: [hit()],
          status: :running | :stopped
        }

  @doc """
  Register an OOB listener for `session_id`.

  Options:
    * `:runner` - `fn cmd -> {:ok, stdout} | {:error, reason} end`.
      `cmd` is `{:start, session_id}` or `{:poll, session_id}`. Tests must
      pass a stub. Default looks up `interactsh-client` and errors with
      `"interactsh-client not found"` when it is missing.
    * `:find_executable` - injectable `System.find_executable/1` for the
      default runner (tests the missing-binary path without shelling out).
  """
  @spec start(String.t(), keyword()) :: {:ok, session()} | {:error, String.t()}
  def start(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    ensure_table()

    case lookup(session_id) do
      %{status: :running} = session ->
        {:ok, public(session)}

      _ ->
        runner = Keyword.get(opts, :runner) || default_runner(opts)

        case invoke(runner, {:start, session_id}) do
          {:ok, stdout} ->
            with {:ok, host} <- parse_host(stdout) do
              session = %{
                id: session_id,
                host: host,
                started_at: DateTime.utc_now(),
                hits: [],
                status: :running,
                runner: runner,
                seen: MapSet.new()
              }

              :ets.insert(@table, {session_id, session})
              {:ok, public(session)}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Callback hostname the agent must inject before sending a blind payload."
  @spec host(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def host(session_id) when is_binary(session_id) do
    ensure_table()

    case lookup(session_id) do
      %{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, @no_session}
    end
  end

  @doc """
  Poll the listener and return **new** hits from this call.

  Duplicate raw lines (already seen this session) are ignored. The full
  history stays on the session via `hits/1`.
  """
  @spec poll(String.t(), keyword()) :: {:ok, [hit()]} | {:error, String.t()}
  def poll(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    ensure_table()

    case lookup(session_id) do
      nil ->
        {:error, @no_session}

      %{status: :stopped} ->
        {:error, @stopped}

      session ->
        runner = Keyword.get(opts, :runner) || session.runner || default_runner(opts)

        case invoke(runner, {:poll, session_id}) do
          {:ok, stdout} ->
            {new_hits, seen} = parse_new_hits(stdout, session.seen)

            session = %{
              session
              | hits: session.hits ++ new_hits,
                seen: seen,
                runner: runner
            }

            :ets.insert(@table, {session_id, session})
            {:ok, new_hits}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "All hits so far. Empty list if there is no session."
  @spec hits(String.t()) :: [hit()]
  def hits(session_id) when is_binary(session_id) do
    ensure_table()

    case lookup(session_id) do
      %{hits: hits} when is_list(hits) -> hits
      _ -> []
    end
  end

  @doc "Mark the session stopped. Further poll/2 calls error."
  @spec stop(String.t()) :: :ok
  def stop(session_id) when is_binary(session_id) do
    ensure_table()

    case lookup(session_id) do
      nil ->
        :ok

      session ->
        :ets.insert(@table, {session_id, %{session | status: :stopped}})
        :ok
    end
  end

  @doc "Verbatim-ish dump of hits for ReportGate / Evidence."
  @spec receipt(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def receipt(session_id) when is_binary(session_id) do
    case hits(session_id) do
      [] ->
        {:error, @no_hits}

      list ->
        dump =
          list
          |> Enum.map(fn hit ->
            "protocol=#{hit.protocol} remote=#{hit.remote || "-"}\n#{hit.raw}"
          end)
          |> Enum.join("\n---\n")

        {:ok, dump}
    end
  end

  @doc """
  Gate for blind classes: must be called before claiming a payload was sent.
  """
  @spec require_started(String.t()) :: :ok | {:error, String.t()}
  def require_started(session_id) when is_binary(session_id) do
    ensure_table()

    case lookup(session_id) do
      %{status: :running} -> :ok
      _ -> {:error, @not_started}
    end
  end

  # ── runner ──────────────────────────────────────────────────────────────

  defp default_runner(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    fn cmd ->
      case find.("interactsh-client") do
        nil -> {:error, @missing_client}
        bin when is_binary(bin) -> default_invoke(bin, cmd)
      end
    end
  end

  # Real binary path. Tests never reach this: they stub `:runner` or inject a
  # nil `:find_executable`. Bounded read so a hanging client cannot block the
  # caller forever.
  defp default_invoke(bin, {:start, session_id}) do
    out_file = session_file(session_id)
    File.mkdir_p!(Path.dirname(out_file))
    File.touch!(out_file)

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, ["-json", "-o", out_file]}
      ])

    acc = collect_port(port, 5_000, "")

    case parse_host(acc) do
      {:ok, _} ->
        :ets.insert(@table, {{:port, session_id}, port, out_file})
        {:ok, acc}

      {:error, _} = err ->
        Port.close(port)
        err
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp default_invoke(_bin, {:poll, session_id}) do
    extra =
      case :ets.lookup(@table, {:port, session_id}) do
        [{{:port, ^session_id}, port, out_file}] ->
          drain = collect_port(port, 200, "")
          file = File.read!(out_file)
          file <> drain

        _ ->
          ""
      end

    {:ok, extra}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp collect_port(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        case parse_host(acc) do
          {:ok, _} -> acc
          _ -> collect_port(port, timeout, acc)
        end

      {^port, {:exit_status, _}} ->
        acc
    after
      timeout -> acc
    end
  end

  defp session_file(session_id) do
    Path.join([System.tmp_dir!(), "osa-oob", session_id, "interactions.jsonl"])
  end

  defp invoke(runner, cmd) do
    case runner.(cmd) do
      {:ok, stdout} when is_binary(stdout) -> {:ok, stdout}
      {:error, reason} -> {:error, to_reason(reason)}
      other -> {:error, "oob runner failed: #{inspect(other)}"}
    end
  end

  defp to_reason(reason) when is_binary(reason), do: reason
  defp to_reason(reason), do: inspect(reason)

  # ── parse ───────────────────────────────────────────────────────────────

  defp parse_host(stdout) when is_binary(stdout) do
    trimmed = String.trim(stdout)

    case json_host(trimmed) do
      {:ok, host} ->
        {:ok, host}

      :error ->
        case first_hostname(trimmed) do
          nil -> {:error, @no_host}
          host -> {:ok, host}
        end
    end
  end

  defp json_host(text) do
    case decode_json(text) do
      {:ok, host} when is_binary(host) ->
        {:ok, host}

      :error ->
        text
        |> String.split("\n", trim: true)
        |> Enum.find_value(:error, fn line ->
          case decode_json(String.trim(line)) do
            {:ok, host} -> {:ok, host}
            :error -> nil
          end
        end)
    end
  end

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, %{"host" => host}} when is_binary(host) and host != "" ->
        {:ok, host}

      {:ok, %{"domain" => host}} when is_binary(host) and host != "" ->
        {:ok, host}

      {:ok, list} when is_list(list) ->
        Enum.find_value(list, :error, fn
          %{"host" => host} when is_binary(host) and host != "" -> {:ok, host}
          %{"domain" => host} when is_binary(host) and host != "" -> {:ok, host}
          _ -> nil
        end)

      _ ->
        :error
    end
  end

  defp first_hostname(text) do
    @host_re
    |> Regex.scan(text)
    |> Enum.map(&hd/1)
    |> Enum.find(&hostname_token?/1)
  end

  defp hostname_token?(token) do
    String.contains?(token, ".") and not ipv4?(token)
  end

  defp ipv4?(token) do
    case :inet.parse_ipv4_address(String.to_charlist(token)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp parse_new_hits(stdout, seen) when is_binary(stdout) do
    trimmed = String.trim(stdout)

    {candidates, fallback_lines} =
      case Jason.decode(trimmed) do
        {:ok, list} when is_list(list) ->
          hits =
            list
            |> Enum.map(fn map -> {encode_line(map), hit_from_map(map, encode_line(map))} end)
            |> Enum.reject(fn {_line, hit} -> is_nil(hit) end)

          {hits, []}

        {:ok, %{} = map} ->
          line = trimmed

          case hit_from_map(map, line) do
            nil -> {[], String.split(stdout, "\n", trim: true)}
            hit -> {[{line, hit}], []}
          end

        _ ->
          {[], String.split(stdout, "\n", trim: true)}
      end

    line_hits =
      fallback_lines
      |> Enum.map(fn line -> {line, parse_hit_line(line)} end)
      |> Enum.reject(fn {_line, hit} -> is_nil(hit) end)

    (candidates ++ line_hits)
    |> Enum.reduce({[], seen}, fn {line, hit}, {hits, seen} ->
      if MapSet.member?(seen, line) do
        {hits, seen}
      else
        {hits ++ [hit], MapSet.put(seen, line)}
      end
    end)
  end

  defp encode_line(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      _ -> inspect(map)
    end
  end

  defp parse_hit_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = map} -> hit_from_map(map, line)
      _ -> parse_received_line(line)
    end
  end

  defp parse_received_line(line) do
    case Regex.run(@received_re, line) do
      [_, proto, remote] ->
        %{
          id: hit_id(nil, line),
          protocol: String.downcase(proto),
          remote: String.trim(remote),
          raw: line,
          at: DateTime.utc_now()
        }

      _ ->
        nil
    end
  end

  defp hit_from_map(map, raw_line) when is_map(map) do
    proto = json_get(map, ["protocol", "proto"])
    unique = json_get(map, ["unique-id", "unique_id", "uniqueId", "full-id", "full_id", "id"])
    remote = json_get(map, ["remote-address", "remote_address", "remoteAddress", "remote"])
    raw = json_get(map, ["raw-request", "raw_request", "rawRequest", "raw"]) || raw_line
    ts = json_get(map, ["timestamp", "at", "time"])

    if proto || unique || json_get(map, ["raw-request", "raw_request", "rawRequest"]) do
      %{
        id: hit_id(unique, raw_line),
        protocol: proto_name(proto),
        remote: stringify_or_nil(remote),
        raw: to_string(raw),
        at: parse_time(ts)
      }
    else
      nil
    end
  end

  defp proto_name(nil), do: "unknown"
  defp proto_name(proto), do: proto |> to_string() |> String.downcase()

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(v), do: to_string(v)

  defp json_get(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.get(map, k) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp hit_id(unique, _raw) when is_binary(unique) and unique != "", do: unique

  defp hit_id(_, raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp parse_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(_), do: DateTime.utc_now()

  # ── ets ─────────────────────────────────────────────────────────────────

  defp lookup(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] -> session
      _ -> nil
    end
  end

  defp public(session) do
    Map.take(session, [:id, :host, :started_at, :hits, :status])
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :ordered_set])
      _ -> :ok
    end
  end
end
