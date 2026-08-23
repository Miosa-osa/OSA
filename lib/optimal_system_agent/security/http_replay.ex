defmodule OptimalSystemAgent.Security.HttpReplay do
  @moduledoc """
  HTTP intercept/replay without a MITM daemon.

  Strix's proxy lets an agent list, view, and repeat captured requests.
  OSA does not ship a live intercepting proxy. This module is the replay
  half: HAR ingest keeps full request records (method, url, headers,
  postData, status), not just TrafficIngest notes, plus a RoE-gated
  repeater that only fires an injected HTTP client.

  Repeat is an in-scope HTTP repeat of a captured request, not a tunneler.
  Live HTTP is opt-in via `:http_client`; the default never calls Req or
  HTTPoison. Every send path calls `RoeGuard.check/2` with blast `:access`
  on the final URL host. List and view are recon and do not send.
  """

  alias OptimalSystemAgent.Security.RoeGuard

  @table :osa_security_http
  @cap 500

  @type record :: %{
          id: String.t(),
          method: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t() | nil,
          status: integer() | nil,
          source: :har | :manual
        }

  @type response :: %{
          status: integer(),
          headers: map() | list(),
          body: String.t(),
          request_id: String.t()
        }

  @doc """
  Parse HAR JSON into full request records and append them to the session.

  Unique by method+url+body hash. Caps at 500 records per session.
  """
  @spec ingest_har(String.t(), String.t()) :: {:ok, [record()]} | {:error, String.t()}
  def ingest_har(session_id, har_json)
      when is_binary(session_id) and is_binary(har_json) do
    ensure_table()

    case Jason.decode(har_json) do
      {:ok, map} -> store_parsed(session_id, parse_har(map))
      {:error, err} -> {:error, Exception.message(err)}
    end
  end

  def ingest_har(_, _), do: {:error, "session_id and HAR payload must be strings"}

  @doc "Manual insert. Requires method and url."
  @spec put(String.t(), map()) :: {:ok, record()} | {:error, String.t()}
  def put(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    ensure_table()

    method = attr(attrs, :method)
    url = attr(attrs, :url)

    cond do
      not is_binary(method) or method == "" or not is_binary(url) or url == "" ->
        {:error, "method and url are required"}

      session_count(session_id) >= @cap ->
        {:error, "session cap of 500 reached"}

      true ->
        rec = %{
          id: next_id(session_id),
          method: String.upcase(method),
          url: url,
          headers: normalize_headers(attr(attrs, :headers) || []),
          body: normalize_body(attr(attrs, :body)),
          status: normalize_status(attr(attrs, :status)),
          source: :manual
        }

        insert(session_id, rec)
        {:ok, rec}
    end
  end

  def put(_, _), do: {:error, "session_id must be a string and attrs a map"}

  @doc """
  List records for a session.

  Optional filters: `:host`, `:status`, `:method`, `:q` (url substring).
  """
  @spec list(String.t(), keyword()) :: [record()]
  def list(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    ensure_table()

    session_id
    |> session_records()
    |> Enum.filter(&matches_filters?(&1, opts))
  end

  @doc "Fetch a single request by id."
  @spec view(String.t(), String.t()) :: {:ok, record()} | {:error, String.t()}
  def view(session_id, req_id) when is_binary(session_id) and is_binary(req_id) do
    ensure_table()

    case :ets.lookup(@table, {session_id, req_id}) do
      [{_, rec}] -> {:ok, rec}
      [] -> {:error, "unknown request id"}
    end
  end

  def view(_, _), do: {:error, "session_id and request id must be strings"}

  @doc """
  Replay a captured request through an injected HTTP client.

  Requires `:roe`. Gated with `RoeGuard.check/2` at blast `:access` on the
  final URL (after `:overrides`). Does not send on `:block` or
  `:needs_authorization`. Default client is not configured.
  """
  @spec repeat(String.t(), String.t(), keyword()) :: {:ok, response()} | {:error, String.t()}
  def repeat(session_id, req_id, opts \\ [])
      when is_binary(session_id) and is_binary(req_id) and is_list(opts) do
    ensure_table()

    with {:ok, contract} <- fetch_roe(opts),
         {:ok, rec} <- view(session_id, req_id) do
      req = apply_overrides(rec, Keyword.get(opts, :overrides, %{}))
      target = roe_target(req.url)

      case RoeGuard.check(contract, %{blast: :access, target: target}) do
        {:allow, _} -> dispatch(req, rec.id, Keyword.get(opts, :http_client))
        {:block, reason} -> {:error, reason}
        {:needs_authorization, reason} -> {:error, reason}
      end
    end
  end

  @doc "Compact table of id / method / status / url."
  @spec render_list(String.t()) :: String.t()
  def render_list(session_id) when is_binary(session_id) do
    rows =
      session_id
      |> list()
      |> Enum.map(fn rec ->
        status = if is_integer(rec.status), do: Integer.to_string(rec.status), else: "-"
        "#{rec.id}  #{rec.method}  #{status}  #{rec.url}"
      end)

    Enum.join(["id  method  status  url" | rows], "\n")
  end

  # ── HAR parse ──────────────────────────────────────────────────────────

  defp parse_har(%{"log" => %{"entries" => entries}}) when is_list(entries) do
    {:ok, Enum.flat_map(entries, &parse_entry/1)}
  end

  defp parse_har(_), do: {:error, "not a HAR log (missing log.entries)"}

  defp parse_entry(%{"request" => req} = entry) when is_map(req) do
    url = req["url"] || ""

    if url == "" do
      []
    else
      [
        %{
          id: "",
          method: String.upcase(to_string(req["method"] || "GET")),
          url: url,
          headers: normalize_headers(req["headers"] || []),
          body: post_data(req["postData"]),
          status: normalize_status(get_in(entry, ["response", "status"])),
          source: :har
        }
      ]
    end
  end

  defp parse_entry(_), do: []

  defp post_data(%{"text" => text}) when is_binary(text), do: text
  defp post_data(%{text: text}) when is_binary(text), do: text
  defp post_data(_), do: nil

  defp store_parsed(_session_id, {:error, _} = err), do: err

  defp store_parsed(session_id, {:ok, parsed}) do
    existing = session_records(session_id)
    hashes = MapSet.new(existing, &fingerprint/1)
    count = length(existing)
    next_n = next_index(existing)

    {added, _, _} =
      Enum.reduce(parsed, {[], hashes, {count, next_n}}, fn rec, {acc, seen, {count, n}} ->
        hash = fingerprint(rec)

        cond do
          MapSet.member?(seen, hash) ->
            {acc, seen, {count, n}}

          count >= @cap ->
            {acc, seen, {count, n}}

          true ->
            rec = %{rec | id: "req-#{n}"}
            insert(session_id, rec)
            {[rec | acc], MapSet.put(seen, hash), {count + 1, n + 1}}
        end
      end)

    {:ok, Enum.reverse(added)}
  end

  # ── repeat ─────────────────────────────────────────────────────────────

  defp fetch_roe(opts) do
    case Keyword.get(opts, :roe, :missing) do
      :missing -> {:error, "roe required"}
      nil -> {:error, "roe required"}
      contract -> {:ok, contract}
    end
  end

  defp apply_overrides(rec, overrides) when is_map(overrides) do
    %{
      method: rec.method,
      url: Map.get(overrides, :url, rec.url),
      headers: Map.get(overrides, :headers, rec.headers),
      body: Map.get(overrides, :body, rec.body)
    }
  end

  defp apply_overrides(rec, _),
    do: %{method: rec.method, url: rec.url, headers: rec.headers, body: rec.body}

  defp roe_target(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> url
    end
  end

  defp roe_target(_), do: ""

  defp dispatch(req, request_id, client) when is_function(client, 1) do
    case client.(req) do
      {:ok, %{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body, request_id: request_id}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}

      other ->
        {:error, "http_client returned #{inspect(other)}"}
    end
  end

  defp dispatch(_req, _request_id, _), do: {:error, "http_client not configured"}

  # ── list filters ───────────────────────────────────────────────────────

  defp matches_filters?(rec, opts) do
    Enum.all?(opts, fn
      {:host, host} when is_binary(host) -> rec_host(rec.url) == host
      {:status, status} -> rec.status == status
      {:method, method} -> rec.method == String.upcase(to_string(method))
      {:q, q} when is_binary(q) -> String.contains?(rec.url, q)
      _ -> true
    end)
  end

  defp rec_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  # ── ETS ────────────────────────────────────────────────────────────────

  defp insert(session_id, rec) do
    :ets.insert(@table, {{session_id, rec.id}, rec})
  end

  defp session_records(session_id) do
    @table
    |> :ets.match({{session_id, :_}, :"$1"})
    |> Enum.map(fn [rec] -> rec end)
    |> Enum.sort_by(&id_index/1)
  end

  defp session_count(session_id) do
    @table
    |> :ets.select_count([{{{session_id, :_}, :_}, [], [true]}])
  end

  defp next_id(session_id), do: "req-#{next_index(session_records(session_id))}"

  defp next_index([]), do: 1
  defp next_index(recs), do: id_index(List.last(recs)) + 1

  defp id_index(%{id: id}), do: id_index(id)

  defp id_index("req-" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp id_index(_), do: 0

  defp fingerprint(%{method: method, url: url, body: body}) do
    :crypto.hash(:sha256, [method, 0, url, 0, body || ""])
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ── normalize ──────────────────────────────────────────────────────────

  defp attr(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp normalize_headers(list) when is_list(list) do
    Enum.flat_map(list, fn
      {k, v} -> [{to_string(k), to_string(v)}]
      %{name: n, value: v} -> [{to_string(n), to_string(v)}]
      %{"name" => n, "value" => v} -> [{to_string(n), to_string(v)}]
      _ -> []
    end)
  end

  defp normalize_headers(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(_), do: []

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(_), do: nil

  defp normalize_status(status) when is_integer(status), do: status
  defp normalize_status(_), do: nil
end
