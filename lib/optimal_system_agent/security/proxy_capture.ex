defmodule OptimalSystemAgent.Security.ProxyCapture do
  @moduledoc """
  Record a HAR dump from an operator-run proxy. Do not ship Caido or a MITM.

  Capture path:
  1. Operator (or sandbox) runs an intercepting proxy and dumps HAR.
  2. This module records the dump path and ingests into HttpReplay when
     `HttpReplay.ingest_har/2` is available.
  3. Optional start/stop talks to `mitmdump` only through an injected
     `:runner`. This module does not bind ports or spawn a proxy.

  Session-scoped ETS (`:osa_security_proxy`). Tests always inject `:runner`.
  """

  @table :osa_security_proxy
  @missing_bin "mitmdump not found - ingest a HAR dump instead"
  @default_port 8080

  @type session :: %{
          port: integer() | nil,
          har_path: String.t() | nil,
          status: :running | :stopped | :idle
        }

  @doc """
  Read a HAR file at `path`, ingest it, and record the dump path.

  Calls `HttpReplay.ingest_har/2` when that function is exported.
  Otherwise parses HAR into `%{method, url, status}` maps.
  """
  @spec ingest_dump(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def ingest_dump(session_id, path)
      when is_binary(session_id) and is_binary(path) do
    case File.read(path) do
      {:ok, json} -> ingest_json(session_id, json, path)
      {:error, reason} -> {:error, file_error(path, reason)}
    end
  end

  def ingest_dump(_, _), do: {:error, "session_id and path must be strings"}

  @doc """
  Ingest a HAR JSON string for `session_id`.

  Same pipeline as `ingest_dump/2`. `path` in the result is nil (no file).
  """
  @spec ingest_har_blob(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def ingest_har_blob(session_id, har_json)
      when is_binary(session_id) and is_binary(har_json) do
    ingest_json(session_id, har_json, nil)
  end

  def ingest_har_blob(_, _), do: {:error, "session_id and HAR payload must be strings"}

  @doc """
  Mark a capture session running.

  Options:
    * `:runner` - `fn cmd -> {:ok, stdout} | {:error, reason} end`.
      `cmd` is `{:start, port, har_path}` or `{:stop, session_id}`.
      Tests must pass a stub. Default looks up `mitmdump` then `mitmproxy`
      and errors with `"mitmdump not found - ingest a HAR dump instead"`
      when both are missing. Does not spawn a proxy process.
    * `:find_executable` - injectable `System.find_executable/1` for the
      default runner (missing-binary path without shelling out).
    * `:port` - listen port recorded on the session (default 8080).
    * `:har_path` - dump path recorded on the session.
  """
  @spec start(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def start(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    ensure_table()

    port = Keyword.get(opts, :port, @default_port)
    har_path = Keyword.get(opts, :har_path) || default_har_path(session_id)
    runner = Keyword.get(opts, :runner) || default_runner(opts)

    case invoke(runner, {:start, port, har_path}) do
      {:ok, _stdout} ->
        session = %{
          port: port,
          har_path: har_path,
          status: :running,
          runner: runner
        }

        :ets.insert(@table, {session_id, merge(lookup(session_id), session)})
        {:ok, public(session)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop the capture session. Calls `runner.({:stop, session_id})`."
  @spec stop(String.t(), keyword()) :: :ok | {:error, String.t()}
  def stop(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    ensure_table()

    case lookup(session_id) do
      nil ->
        :ok

      session ->
        runner = Keyword.get(opts, :runner) || session_runner(session) || default_runner(opts)

        case invoke(runner, {:stop, session_id}) do
          {:ok, _} ->
            :ets.insert(@table, {session_id, Map.put(session, :status, :stopped)})
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Session status. `:idle` when the session has never started."
  @spec status(String.t()) :: :running | :stopped | :idle
  def status(session_id) when is_binary(session_id) do
    ensure_table()

    case lookup(session_id) do
      %{status: status} when status in [:running, :stopped, :idle] -> status
      _ -> :idle
    end
  end

  def status(_), do: :idle

  # ── ingest ──────────────────────────────────────────────────────────────

  defp ingest_json(session_id, json, path) do
    case replay_har(session_id, json) do
      {:ok, recs} when is_list(recs) ->
        count = length(recs)
        record_ingest(session_id, path, count)
        {:ok, %{count: count, path: path}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp replay_har(session_id, json) do
    if http_replay?() do
      OptimalSystemAgent.Security.HttpReplay.ingest_har(session_id, json)
    else
      parse_har_local(json)
    end
  end

  defp http_replay? do
    Code.ensure_loaded?(OptimalSystemAgent.Security.HttpReplay) and function_exported?(OptimalSystemAgent.Security.HttpReplay, :ingest_har, 2)
  end

  defp parse_har_local(json) do
    case Jason.decode(json) do
      {:ok, %{"log" => %{"entries" => entries}}} when is_list(entries) ->
        {:ok, Enum.flat_map(entries, &parse_entry/1)}

      {:ok, _} ->
        {:error, "not a HAR log (missing log.entries)"}

      {:error, err} ->
        {:error, Exception.message(err)}
    end
  end

  defp parse_entry(%{"request" => req} = entry) when is_map(req) do
    url = req["url"] || ""

    if url == "" do
      []
    else
      [
        %{
          method: to_string(req["method"] || "GET"),
          url: url,
          status: get_in(entry, ["response", "status"])
        }
      ]
    end
  end

  defp parse_entry(_), do: []

  defp record_ingest(session_id, path, count) do
    ensure_table()
    current = lookup(session_id) || %{status: :idle, port: nil, har_path: nil, runner: nil}

    session =
      current
      |> Map.put(:dump_path, path)
      |> Map.put(:count, count)
      |> maybe_har_path(path)

    :ets.insert(@table, {session_id, session})
  end

  defp maybe_har_path(session, path) when is_binary(path) and path != "",
    do: Map.put(session, :har_path, path)

  defp maybe_har_path(session, _), do: session

  # ── runner ──────────────────────────────────────────────────────────────

  defp default_runner(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    fn cmd ->
      case find.("mitmdump") || find.("mitmproxy") do
        nil -> {:error, @missing_bin}
        _bin -> default_invoke(cmd)
      end
    end
  end

  # Bookkeeping only. This module never spawns mitmdump/mitmproxy.
  # Inject `:runner` when the operator wants an external dump process.
  defp default_invoke({:start, _port, _har_path}), do: {:ok, ""}
  defp default_invoke({:stop, _session_id}), do: {:ok, ""}
  defp default_invoke(_), do: {:error, @missing_bin}

  defp invoke(runner, cmd) when is_function(runner, 1) do
    case runner.(cmd) do
      {:ok, stdout} -> {:ok, stdout}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "runner returned #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp invoke(_, _), do: {:error, @missing_bin}

  # ── ETS ─────────────────────────────────────────────────────────────────

  defp lookup(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] -> session
      _ -> nil
    end
  end

  defp session_runner(%{runner: runner}) when is_function(runner, 1), do: runner
  defp session_runner(_), do: nil

  defp merge(nil, session), do: session

  defp merge(current, session) do
    Map.merge(current, Map.take(session, [:port, :har_path, :status, :runner]))
  end

  defp public(session) do
    %{
      port: Map.get(session, :port),
      har_path: Map.get(session, :har_path),
      status: Map.get(session, :status)
    }
  end

  defp default_har_path(session_id) do
    safe =
      session_id
      |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
      |> String.slice(0, 80)

    Path.join(System.tmp_dir!(), "osa-proxy-#{safe}.har")
  end

  defp file_error(path, reason) do
    "#{path}: #{:file.format_error(reason)}"
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
