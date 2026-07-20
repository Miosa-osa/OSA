defmodule OptimalSystemAgent.Remote.Frames do
  @moduledoc """
  Pure frame builders and parsers for the OSA-side remote CLIENT.

  These are the wire terms the client exchanges with the MIOSA control-plane
  session broker over the client endpoint
  (`wss://api.miosa.ai/api/v1/opencomputers/clients/ws`). Every term is encoded
  and decoded with `OptimalSystemAgent.OpenComputers.Session.FrameCodec`
  (erlang-term codec), exactly as the host side does on `.../hosts/ws`.

  ## Two frame families

  ### 1. Control-plane frames (broker interprets these)

  These are NEW frames that only the broker understands. They do not exist on
  the host side. The MIOSA server MUST implement handlers for them:

    * `{:client_hello, %{account_key, version, role: :client}}` — client auth.
      Broker replies `{:client_hello_ok, %{account, heartbeat_ms}}` or
      `{:client_error, %{code, message}}`.
    * `{:hosts_list_request, %{}}` — broker replies
      `{:hosts_list, %{hosts: [%{id, alias, online, os, last_seen}]}}`.
    * `{:session_create_request, %{ref, host, kind, params}}` — broker allocates
      a `session_id`, verifies the account owns `host`, binds a client<->host
      route for that `session_id`, and replies
      `{:session_created, %{ref, host, session_id, kind}}`.
    * `{:sessions_list_request, %{host}}` — broker replies
      `{:sessions_list, %{host, sessions: [%{session_id, kind, started_at}]}}`.
    * `{:session_kill_request, %{host, session_id}}` — broker relays a teardown
      to the host and replies `{:session_killed, %{host, session_id}}`.

  ### 2. Data-plane frames (broker forwards verbatim to/from the host)

  These are the EXACT frames the host executors already speak (see
  `executor/direct/exec.ex`, `.../agent.ex`, `.../pty.ex`). The broker routes
  them by the `session_id` bound at create time and never interprets them:

    * Client -> host: `{:job, %{...}}`, `{:pty_open_request, ...}`,
      `{:pty_input, ...}`, `{:pty_resize, ...}`, `{:pty_close, ...}`.
    * Host -> client: `{:job_accept, id, n}`, `{:job_done, id, result}`,
      `{:job_fail, id, info}`, `{:pty_opened, ...}`, `{:pty_output, ...}`,
      `{:pty_close, ...}`, `{:pty_error, ...}`.

  For `exec` and `agent`, the job `id` is set to the broker-allocated
  `session_id` so the host reply frames (which reference `job.id`) route back to
  the right client without any host-side change.
  """

  @role :client

  # ── Control-plane builders ───────────────────────────────────────────────────

  @spec client_hello(String.t()) :: {:client_hello, map()}
  def client_hello(account_key) when is_binary(account_key) do
    {:client_hello, %{account_key: account_key, version: osa_version(), role: @role}}
  end

  @spec hosts_list_request() :: {:hosts_list_request, map()}
  def hosts_list_request, do: {:hosts_list_request, %{}}

  @spec session_create_request(String.t(), String.t(), atom(), map()) ::
          {:session_create_request, map()}
  def session_create_request(ref, host, kind, params \\ %{})
      when is_binary(ref) and is_binary(host) and is_atom(kind) and is_map(params) do
    {:session_create_request, %{ref: ref, host: host, kind: kind, params: params}}
  end

  @spec sessions_list_request(String.t()) :: {:sessions_list_request, map()}
  def sessions_list_request(host) when is_binary(host) do
    {:sessions_list_request, %{host: host}}
  end

  @spec session_kill_request(String.t() | nil, String.t()) :: {:session_kill_request, map()}
  def session_kill_request(host, session_id) when is_binary(session_id) do
    {:session_kill_request, %{host: host, session_id: session_id}}
  end

  # ── Data-plane builders (mirror the host executor contract exactly) ──────────

  @doc """
  One-shot shell exec. Mirrors what `Executor.Direct.Exec` reads: `id`, `cmd`,
  `cwd`, `timeout_ms`, `env`. The `id` is the broker session_id so replies route
  back.
  """
  @spec exec_job(String.t(), String.t(), keyword()) :: {:job, map()}
  def exec_job(session_id, cmd, opts \\ []) when is_binary(session_id) and is_binary(cmd) do
    job =
      %{id: session_id, kind: :exec_on_host, cmd: cmd}
      |> maybe_put(:cwd, opts[:cwd])
      |> maybe_put(:timeout_ms, opts[:timeout_ms])
      |> maybe_put(:env, opts[:env])

    {:job, job}
  end

  @doc """
  Agent task dispatch. Mirrors what `Executor.Direct.Agent` reads: `id`,
  `prompt`, `context` (`working_dir` / `provider` / `model`), `timeout_ms`.
  """
  @spec agent_job(String.t(), String.t(), keyword()) :: {:job, map()}
  def agent_job(session_id, prompt, opts \\ [])
      when is_binary(session_id) and is_binary(prompt) do
    context =
      %{}
      |> maybe_put(:working_dir, opts[:dir])
      |> maybe_put(:provider, opts[:provider])
      |> maybe_put(:model, opts[:model])

    job =
      %{id: session_id, kind: :dispatch_agent, prompt: prompt, context: context}
      |> maybe_put(:timeout_ms, opts[:timeout_ms])

    {:job, job}
  end

  @spec pty_open(String.t(), String.t() | nil, pos_integer(), pos_integer(), keyword()) ::
          {:pty_open_request, map()}
  def pty_open(session_id, shell, cols, rows, opts \\ []) when is_binary(session_id) do
    payload =
      %{session_id: session_id, cols: cols, rows: rows}
      |> maybe_put(:shell, shell)
      |> maybe_put(:cwd, opts[:cwd])
      |> maybe_put(:env, opts[:env])

    {:pty_open_request, payload}
  end

  @spec pty_input(String.t(), binary()) :: {:pty_input, map()}
  def pty_input(session_id, data) when is_binary(session_id) and is_binary(data) do
    {:pty_input, %{session_id: session_id, data: data}}
  end

  @spec pty_resize(String.t(), pos_integer(), pos_integer()) :: {:pty_resize, map()}
  def pty_resize(session_id, cols, rows) when is_binary(session_id) do
    {:pty_resize, %{session_id: session_id, cols: cols, rows: rows}}
  end

  @spec pty_close(String.t(), integer()) :: {:pty_close, map()}
  def pty_close(session_id, exit_code \\ 0) when is_binary(session_id) do
    {:pty_close, %{session_id: session_id, exit_code: exit_code}}
  end

  # ── Response parsers ─────────────────────────────────────────────────────────

  @doc "Extract the host list from a `{:hosts_list, _}` frame."
  @spec parse_hosts_list(term()) :: {:ok, [map()]} | :error
  def parse_hosts_list({:hosts_list, %{hosts: hosts}}) when is_list(hosts), do: {:ok, hosts}
  def parse_hosts_list(_), do: :error

  @doc "Extract `{host, session_id}` from a `{:session_created, _}` frame."
  @spec parse_session_created(term()) :: {:ok, map()} | :error
  def parse_session_created({:session_created, %{session_id: sid} = info}) when is_binary(sid) do
    {:ok, info}
  end

  def parse_session_created(_), do: :error

  @doc "Extract the session list from a `{:sessions_list, _}` frame."
  @spec parse_sessions_list(term()) :: {:ok, [map()]} | :error
  def parse_sessions_list({:sessions_list, %{sessions: sessions}}) when is_list(sessions) do
    {:ok, sessions}
  end

  def parse_sessions_list(_), do: :error

  @doc """
  Human-readable one-line summary of a host->client job result frame.
  Returns `{:done, text}` / `{:fail, text}` / `:ignore`.
  """
  @spec summarize_job_reply(term()) :: {:done, String.t()} | {:fail, String.t()} | :ignore
  def summarize_job_reply({:job_done, _id, %{stdout: out, exit_code: code}}) do
    {:done, "exit=#{code}\n#{out}"}
  end

  def summarize_job_reply({:job_done, _id, %{result: result}}) do
    {:done, to_string(result)}
  end

  def summarize_job_reply({:job_done, _id, result}), do: {:done, inspect(result)}

  def summarize_job_reply({:job_fail, _id, %{message: msg}}), do: {:fail, to_string(msg)}
  def summarize_job_reply({:job_fail, _id, info}), do: {:fail, inspect(info)}
  def summarize_job_reply(_), do: :ignore

  # ── Private ──────────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp osa_version do
    case Application.spec(:optimal_system_agent, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
