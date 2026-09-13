defmodule OptimalSystemAgent.Sandbox.MIOSA do
  @moduledoc """
  MIOSA platform sandbox backend — the **recommended default** cloud sandbox.

  Talks to the MIOSA platform API at `https://api.miosa.ai/api/v1/sandboxes`
  using **Bearer** auth from `MIOSA_PLATFORM_API_KEY`.

  > **Important:** `MIOSA_PLATFORM_API_KEY` (platform / sandboxes, `api.miosa.ai`)
  > is a **distinct** credential from the inference `MIOSA_API_KEY`
  > (`optimal.miosa.ai`, LLM completions). Do not reuse one for the other.

  ## Persistent sessions & warm reuse

  MIOSA sandboxes are **persistent** (pause / resume / snapshot), so rather than
  create-and-destroy a fresh sandbox on every command, this backend keeps a
  small `GenServer` that holds one **reusable `sandbox_id`** across commands.
  `execute/2` and `run_file/2` route through that server and share a single warm
  sandbox; the optional `create/1` + `destroy/1` callbacks still let callers
  provision dedicated sessions explicitly.

  The server is started lazily on first use — nothing runs (and no sandbox is
  provisioned) until the backend is actually selected and invoked.

  ## Configuration

  ```json ~/.osa/sandbox.json
  {
    "backend": "miosa",
    "miosa": {
      "api_key": "...",
      "size": "medium",
      "timeout": 30
    }
  }
  ```

  Or set the `MIOSA_PLATFORM_API_KEY` environment variable.
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  use GenServer

  require Logger

  @base_url "https://api.miosa.ai/api/v1"
  @default_size "medium"
  @default_timeout 30_000
  @server __MODULE__.Server

  # --- Required core ---

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def available?, do: api_key() != nil

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def name, do: "miosa (persistent cloud sandbox)"

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def execute(command, opts \\ []) do
    case Keyword.get(opts, :session) do
      nil ->
        # Warm reuse via the reusable-sandbox GenServer.
        with {:ok, _pid} <- ensure_server(opts) do
          GenServer.call(@server, {:exec, command, opts}, call_timeout(opts))
        end

      session ->
        exec_in_session(session, command, timeout(opts), opts)
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def run_file(path, opts \\ []) do
    content = File.read!(path)
    ext = Path.extname(path)
    remote = "/workspace/script#{ext}"

    run_cmd =
      case ext do
        ".py" -> "python3 #{remote}"
        ".js" -> "node #{remote}"
        ".ts" -> "npx tsx #{remote}"
        ".sh" -> "bash #{remote}"
        _ -> "sh #{remote}"
      end

    session_or_server =
      case Keyword.get(opts, :session) do
        nil -> {:server, ensure_server(opts)}
        session -> {:session, session}
      end

    case session_or_server do
      {:session, session} ->
        with :ok <- write_file(session, remote, content) do
          exec_in_session(session, run_cmd, timeout(opts))
        end

      {:server, {:ok, _pid}} ->
        GenServer.call(@server, {:run_file, remote, content, run_cmd, opts}, call_timeout(opts))

      {:server, {:error, _} = err} ->
        err
    end
  rescue
    e -> {:error, "Failed to read file: #{Exception.message(e)}"}
  end

  # --- Optional: session lifecycle ---

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def create(opts \\ []) do
    case api_key() do
      nil ->
        {:error,
         "MIOSA platform API key not configured. Set MIOSA_PLATFORM_API_KEY or add to ~/.osa/sandbox.json"}

      key ->
        size = Keyword.get(opts, :size, config()[:size] || @default_size)
        body = %{size: size, persistent: true}

        Logger.info("[Sandbox.MIOSA] Creating persistent sandbox (size=#{size})")

        case request(:post, "/sandboxes", key, json: body) do
          {:ok, %{"id" => id} = b} ->
            {:ok, %{id: id, key: key, preview_domain: b["preview_domain"]}}

          {:ok, other} ->
            {:error, "Create sandbox: unexpected response #{inspect(other)}"}

          {:error, reason} ->
            {:error, "Create sandbox failed: #{reason}"}
        end
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def destroy(%{id: id, key: key}) do
    # Persistent sandboxes: DELETE removes it along with snapshots.
    case request(:delete, "/sandboxes/#{id}", key, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> :ok
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def write_file(%{id: id, key: key}, path, content) do
    case request(:post, "/sandboxes/#{id}/files", key, json: %{path: path, content: content}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "write_file failed: #{reason}"}
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def read_file(%{id: id, key: key}, path) do
    case request(:get, "/sandboxes/#{id}/files", key, params: [path: path]) do
      {:ok, %{"content" => content}} -> {:ok, content}
      {:ok, other} -> {:error, "read_file: unexpected response #{inspect(other)}"}
      {:error, reason} -> {:error, "read_file failed: #{reason}"}
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def expose_port(%{id: id, key: key}, port) do
    case request(:post, "/sandboxes/#{id}/ports", key, json: %{port: port}) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:ok, other} -> {:error, "expose_port: unexpected response #{inspect(other)}"}
      {:error, reason} -> {:error, "expose_port failed: #{reason}"}
    end
  end

  # --- Reusable-sandbox GenServer ---

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  defp ensure_server(opts) do
    case GenServer.whereis(@server) do
      nil ->
        case start_link(opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, "MIOSA server failed to start: #{inspect(reason)}"}
        end

      pid ->
        {:ok, pid}
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{session: nil, opts: opts}}
  end

  @impl GenServer
  def handle_call({:exec, command, opts}, _from, state) do
    with {:ok, session, state} <- ensure_session(state, opts) do
      reply = exec_in_session(session, command, timeout(opts), opts)
      {:reply, reply, maybe_invalidate_session(state, reply)}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:run_file, remote, content, run_cmd, opts}, _from, state) do
    with {:ok, session, state} <- ensure_session(state, opts),
         :ok <- write_file(session, remote, content) do
      reply = exec_in_session(session, run_cmd, timeout(opts))
      {:reply, reply, maybe_invalidate_session(state, reply)}
    else
      {:error, reason, state} ->
        {:reply, {:error, reason}, maybe_invalidate_session(state, {:error, reason})}

      {:error, reason} ->
        {:reply, {:error, reason}, maybe_invalidate_session(state, {:error, reason})}
    end
  end

  # If a call failed because the remote sandbox is gone (expired/paused/deleted),
  # clear the cached session so the NEXT call re-provisions instead of retrying
  # the same dead id forever.
  defp maybe_invalidate_session(state, {:error, reason}) do
    if dead_sandbox_error?(reason), do: %{state | session: nil}, else: state
  end

  defp maybe_invalidate_session(state, _reply), do: state

  defp dead_sandbox_error?(reason) when is_binary(reason) do
    String.contains?(reason, ["HTTP 404", "HTTP 410", "HTTP 409"]) or
      String.contains?(reason, ["closed", "econnrefused", "timeout", "nxdomain"])
  end

  defp dead_sandbox_error?(_), do: false

  # Reuse the live session, provisioning one on first use.
  defp ensure_session(%{session: %{} = session} = state, _opts), do: {:ok, session, state}

  defp ensure_session(%{session: nil} = state, opts) do
    case create(Keyword.merge(state.opts, opts)) do
      {:ok, session} -> {:ok, session, %{state | session: session}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # --- Private ---

  # Two defects lived here, both of which made this backend quietly wrong rather
  # than visibly broken, and both of which `:miosa_cli` avoids by delegating to
  # the CLI:
  #
  #   * `working_dir` was accepted by callers and then dropped. Host and Docker
  #     both honour it, so the same command ran in a different directory
  #     depending only on which backend was selected. The platform accepts the
  #     directory as BOTH `cwd` and `dir`, and the official client additionally
  #     prefixes `cd <dir> && ` - all three are sent here for the same reason it
  #     does: the belt is cheap and the braces are cheaper than a silent
  #     wrong-directory write.
  #
  #   * `exit_code` was discarded and stdout/stderr concatenated, so a FAILED
  #     command was reported to the model as `{:ok, output}`. The agent could
  #     not tell a passing build from a failing one.
  defp exec_in_session(session, command, timeout),
    do: exec_in_session(session, command, timeout, [])

  defp exec_in_session(%{id: id, key: key}, command, timeout, opts) do
    Logger.info("[Sandbox.MIOSA] exec: #{String.slice(command, 0, 80)}")
    secs = div(timeout, 1000)
    cwd = Keyword.get(opts, :working_dir)

    body =
      %{command: with_cwd(command, cwd), timeout: secs}
      |> maybe_put_cwd(cwd)

    case request(:post, "/sandboxes/#{id}/exec", key,
           json: body,
           receive_timeout: timeout + 5_000
         ) do
      {:ok, %{} = b} -> {:ok, format_exec(b)}
      {:ok, other} -> {:ok, to_string_body(other)}
      {:error, reason} -> {:error, "MIOSA exec failed: #{reason}"}
    end
  end

  defp with_cwd(command, nil), do: command
  defp with_cwd(command, ""), do: command
  defp with_cwd(command, cwd), do: "cd #{shell_quote(cwd)} && #{command}"

  defp maybe_put_cwd(body, cwd) when is_binary(cwd) and cwd != "",
    do: body |> Map.put(:cwd, cwd) |> Map.put(:dir, cwd)

  defp maybe_put_cwd(body, _), do: body

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  # Keep stdout and stderr separable, and never report a non-zero exit as a
  # plain success.
  defp format_exec(%{} = b) do
    out = to_string(b["stdout"] || "")
    err = to_string(b["stderr"] || "")

    text =
      case {out, err} do
        {"", ""} -> ""
        {o, ""} -> o
        {"", e} -> e
        {o, e} -> o <> "\n" <> e
      end

    case b["exit_code"] do
      code when is_integer(code) and code != 0 -> text <> "\n[exit code: #{code}]"
      _ -> text
    end
  end

  defp request(method, path, key, opts) do
    {req_opts, extra} = Keyword.split(opts, [:json, :params, :receive_timeout])

    args =
      [
        method: method,
        url: "#{@base_url}#{path}",
        headers: headers(key),
        receive_timeout: req_opts[:receive_timeout] || @default_timeout
      ] ++ Keyword.take(req_opts, [:json, :params]) ++ extra

    case Req.request(args) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      {:ok, %{status: s, body: body}} -> {:error, "HTTP #{s}: #{inspect(body)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp headers(key) do
    [{"Authorization", "Bearer #{key}"}, {"Content-Type", "application/json"}]
  end

  defp to_string_body(b) when is_binary(b), do: b
  defp to_string_body(b), do: inspect(b)

  defp timeout(opts), do: Keyword.get(opts, :timeout, config()[:timeout_ms] || @default_timeout)

  defp call_timeout(opts), do: timeout(opts) + 15_000

  defp config, do: Application.get_env(:optimal_system_agent, :sandbox_miosa, %{})

  defp api_key do
    System.get_env("MIOSA_PLATFORM_API_KEY") ||
      Application.get_env(:optimal_system_agent, :miosa_platform_api_key)
  end
end
