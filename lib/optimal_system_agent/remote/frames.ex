defmodule OptimalSystemAgent.Remote.Frames do
  @moduledoc """
  Pure frame builders and parsers for the OSA-side remote CLIENT, aligned to the
  MIOSA miosa-compute #484 protocol (`Web.Ws.OpenComputers.RemoteClientSocket`).

  ## Wire shape

  The client negotiates the `miosa-opencomputers-client-v1` subprotocol on
  `wss://api.miosa.ai/api/v1/opencomputers/clients/ws` and exchanges erlang-term
  binary frames (encoded/decoded with
  `OptimalSystemAgent.OpenComputers.Session.FrameCodec`, `:safe` on decode).

  EVERY message is wrapped in an envelope:

      {:oc_remote, %{v: 1, request_id: <uuid>, body: <body>}}

  `wrap/1` adds the envelope (fresh `request_id` per message); `unwrap/1` peels
  it back to the inner body. The server does not require the client to correlate
  on `request_id` for streaming, but the field must be present.

  ## Client -> server bodies

    * `{:remote_hello, %{account_key, client_instance_id}}`
    * `{:remote_hosts_list, %{}}`
    * `{:remote_session_open, %{ref, host_id, kind, params}}` where `kind` is
      `:exec | :agent`. `exec_params/2` and `agent_params/2` build `params`.
    * `{:remote_session_close, %{session_id}}`
    * `{:pong, seq}` (reply to a server `{:ping, seq}`)

  ## Server -> client bodies (parsed here)

    * `{:remote_hello_ok, %{tenant_id, heartbeat_ms}}`
    * `{:remote_hosts, %{hosts: [%{id, name, online, os_kind}]}}`
    * `{:remote_session_opened, %{ref, session_id}}`
    * `{:remote_session_frame, %{session_id, frame: <inner host frame>}}` — the
      inner `frame` is raw host output, e.g. `{:job_done, session_id, %{...}}`,
      `{:job_fail, session_id, reason}`, or `{:exec_chunk, %{...}}`.
    * `{:remote_session_closed, %{session_id, reason}}`
    * `{:remote_error, %{ref (optional), reason}}`
    * `{:ping, seq}`
  """

  @version 1

  # ── Envelope ─────────────────────────────────────────────────────────────────

  @doc "Wrap a body in the versioned `:oc_remote` envelope with a fresh request_id."
  @spec wrap(term()) :: {:oc_remote, map()}
  def wrap(body) do
    {:oc_remote, %{v: @version, request_id: request_id(), body: body}}
  end

  @doc "Unwrap an `:oc_remote` envelope back to its inner body."
  @spec unwrap(term()) :: {:ok, term()} | :error
  def unwrap({:oc_remote, %{v: @version, request_id: rid, body: body}}) when is_binary(rid),
    do: {:ok, body}

  def unwrap(_), do: :error

  @doc "A UUID-v4-like request identifier string."
  @spec request_id() :: String.t()
  def request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = c |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x4000)
    d = d |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  # ── Client -> server bodies ──────────────────────────────────────────────────

  @spec remote_hello(String.t(), String.t()) :: {:remote_hello, map()}
  def remote_hello(account_key, client_instance_id)
      when is_binary(account_key) and is_binary(client_instance_id) do
    {:remote_hello, %{account_key: account_key, client_instance_id: client_instance_id}}
  end

  @spec remote_hosts_list() :: {:remote_hosts_list, map()}
  def remote_hosts_list, do: {:remote_hosts_list, %{}}

  @spec remote_session_open(String.t(), String.t(), :exec | :agent, map()) ::
          {:remote_session_open, map()}
  def remote_session_open(ref, host_id, kind, params)
      when is_binary(ref) and is_binary(host_id) and kind in [:exec, :agent] and is_map(params) do
    {:remote_session_open, %{ref: ref, host_id: host_id, kind: kind, params: params}}
  end

  @spec remote_session_close(String.t()) :: {:remote_session_close, map()}
  def remote_session_close(session_id) when is_binary(session_id) do
    {:remote_session_close, %{session_id: session_id}}
  end

  @spec pong(term()) :: {:pong, term()}
  def pong(seq), do: {:pong, seq}

  # ── Session param builders ───────────────────────────────────────────────────

  @doc """
  Build `params` for an `:exec` session. `cmd` is required; `:args`, `:cwd`,
  `:env` (a list of `{k, v}` tuples), and `:timeout_ms` are optional. Omitted
  keys let the host apply its defaults (`cwd: "~"`, `timeout_ms: 300_000`).
  """
  @spec exec_params(String.t(), keyword()) :: map()
  def exec_params(cmd, opts \\ []) when is_binary(cmd) do
    %{cmd: cmd}
    |> maybe_put(:args, opts[:args])
    |> maybe_put(:cwd, opts[:cwd])
    |> maybe_put(:env, opts[:env])
    |> maybe_put(:timeout_ms, opts[:timeout_ms])
  end

  @doc """
  Build `params` for an `:agent` session. `prompt` is required; `context` is
  assembled from `:dir`/`:cwd`, `:model`, and `:provider` (only the #484-allowed
  keys), and `:timeout_ms` is optional. `context` is omitted entirely when empty.
  """
  @spec agent_params(String.t(), keyword()) :: map()
  def agent_params(prompt, opts \\ []) when is_binary(prompt) do
    context =
      %{}
      |> maybe_put(:cwd, opts[:dir] || opts[:cwd])
      |> maybe_put(:model, opts[:model])
      |> maybe_put(:provider, opts[:provider])

    %{prompt: prompt}
    |> then(fn base ->
      if map_size(context) > 0, do: Map.put(base, :context, context), else: base
    end)
    |> maybe_put(:timeout_ms, opts[:timeout_ms])
  end

  # ── Server -> client parsers ─────────────────────────────────────────────────

  @doc "Extract the host list from a `{:remote_hosts, _}` body."
  @spec parse_hosts(term()) :: {:ok, [map()]} | :error
  def parse_hosts({:remote_hosts, %{hosts: hosts}}) when is_list(hosts), do: {:ok, hosts}
  def parse_hosts(_), do: :error

  @doc "Extract the allocated `session_id` from a `{:remote_session_opened, _}` body."
  @spec parse_session_opened(term()) :: {:ok, String.t()} | :error
  def parse_session_opened({:remote_session_opened, %{session_id: sid}}) when is_binary(sid),
    do: {:ok, sid}

  def parse_session_opened(_), do: :error

  @doc "Extract `%{session_id, reason}` from a `{:remote_session_closed, _}` body."
  @spec parse_session_closed(term()) :: {:ok, map()} | :error
  def parse_session_closed({:remote_session_closed, %{session_id: sid} = info})
      when is_binary(sid),
      do: {:ok, info}

  def parse_session_closed(_), do: :error

  @doc "Extract the `reason` (and optional `ref`) from a `{:remote_error, _}` body."
  @spec parse_error(term()) :: {:ok, map()} | :error
  def parse_error({:remote_error, %{reason: _} = info}), do: {:ok, info}
  def parse_error(_), do: :error

  @doc """
  Unwrap a `{:remote_session_frame, %{session_id, frame}}` body into
  `{session_id, inner_frame}`.
  """
  @spec unwrap_session_frame(term()) :: {:ok, String.t(), term()} | :error
  def unwrap_session_frame({:remote_session_frame, %{session_id: sid, frame: frame}})
      when is_binary(sid),
      do: {:ok, sid, frame}

  def unwrap_session_frame(_), do: :error

  @doc """
  Human-readable rendering of an inner host frame (as delivered inside a
  `remote_session_frame`). Returns:

    * `{:chunk, text}` — non-terminal streamed output
    * `{:done, text}` — terminal success
    * `{:fail, text}` — terminal failure
    * `:ignore` — nothing to render
  """
  @spec render_session_frame(term()) ::
          {:chunk, String.t()} | {:done, String.t()} | {:fail, String.t()} | :ignore
  def render_session_frame({:job_done, _sid, %{exit_code: code, stdout: out}}) do
    {:done, "exit=#{code}\n#{out}"}
  end

  def render_session_frame({:job_done, _sid, %{result: result}}), do: {:done, to_string(result)}
  def render_session_frame({:job_done, _sid, result}), do: {:done, inspect(result)}

  def render_session_frame({:exec_result, %{exit_code: code, stdout: out}}) do
    {:done, "exit=#{code}\n#{out}"}
  end

  def render_session_frame({:job_fail, _sid, %{message: msg}}), do: {:fail, to_string(msg)}
  def render_session_frame({:job_fail, _sid, reason}), do: {:fail, describe_reason(reason)}

  def render_session_frame({:exec_chunk, %{data: data}}) when is_binary(data), do: {:chunk, data}

  def render_session_frame(_), do: :ignore

  @doc "Is `frame` a terminal inner host frame (`job_done` / `job_fail` / `exec_result`)?"
  @spec terminal_inner_frame?(term()) :: boolean()
  def terminal_inner_frame?({:job_done, _sid, _}), do: true
  def terminal_inner_frame?({:job_fail, _sid, _}), do: true
  def terminal_inner_frame?({:exec_result, _}), do: true
  def terminal_inner_frame?(_), do: false

  # ── Private ──────────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason(reason) when is_atom(reason), do: to_string(reason)
  defp describe_reason(reason), do: inspect(reason)
end
