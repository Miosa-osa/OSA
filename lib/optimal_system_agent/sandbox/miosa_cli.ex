defmodule OptimalSystemAgent.Sandbox.MiosaCli do
  @moduledoc """
  MIOSA sandbox backend that delegates to the **`miosa` CLI** instead of
  speaking to the platform REST API directly.

  ## Why a second MIOSA backend

  `Sandbox.MIOSA` hand-rolls the platform HTTP contract. That contract has more
  surface than the module models — working directories, tenant/organization/
  workspace scoping, idempotent creates, idle timeouts — and every gap shows up
  as a silent behavioural drift rather than an error. The CLI is released
  alongside the control plane, so delegating to it keeps OSA on the current
  contract for free.

  Concretely, the CLI already owns:

    * **Credentials.** `miosa login` writes `~/.miosa/config.json`. The HTTP
      backend only reads `MIOSA_PLATFORM_API_KEY`, so a logged-in operator still
      shows up as "unavailable".
    * **Scoping.** That same file carries `tenant`, `organization`, `workspace`,
      `endpoint` and `region`. The HTTP backend has no concept of any of them.
    * **Working directories.** `--cwd` (and the `cd <dir> && ` prefix the CLI
      applies on top of it).
    * **Lifecycle.** pause / resume / stop / fork / extend, plus
      `--idempotency-key` so a retried create cannot orphan a sandbox.

  ## Exit codes

  Under `--json` the CLI reports a failed remote command as data rather than as
  a CLI failure: it prints `{"stdout", "stderr", "exit_code"}` and exits 0. So a
  non-zero remote status arrives intact, alongside the output that produced it,
  and the command itself is passed through untouched.

  A CLI-level failure (bad id, auth, transport) is different: the process exits
  non-zero, or returns `{"ok": false, "error": {...}}`. Both are surfaced as
  `{:error, _}` so a broken sandbox is never mistaken for a failing command.

  ## Configuration

  ```json ~/.osa/sandbox.json
  {
    "backend": "miosa_cli",
    "miosa_cli": {
      "sandbox_id": "sbx_existing",
      "size": "small",
      "idle_timeout": "30m",
      "timeout": 30
    }
  }
  ```

  `sandbox_id` **attaches** to a sandbox you already created (with
  `miosa sandbox create`, say) instead of provisioning a new one — the gap that
  made OSA and the CLI feel like two unrelated tools.
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  use GenServer

  require Logger

  @server __MODULE__.Server
  @default_size "small"
  @default_idle_timeout "30m"
  @default_timeout 30_000

  # --- Required core ---

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def available?, do: cli_path() != nil and credential_present?()

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def name, do: "miosa-cli (MIOSA CLI)"

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def execute(command, opts \\ []) do
    case Keyword.get(opts, :session) do
      nil ->
        with {:ok, _pid} <- ensure_server(opts) do
          GenServer.call(@server, {:exec, command, opts}, call_timeout(opts))
        end

      session ->
        exec_in_session(session, command, opts)
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def run_file(path, opts \\ []) do
    with {:ok, content} <- File.read(path) do
      ext = Path.extname(path)
      remote = "/workspace/osa_script#{ext}"

      case interpreter(ext) do
        nil ->
          {:error, "Unsupported file type for sandbox execution: #{ext}"}

        run_cmd ->
          with {:ok, _pid} <- ensure_server(opts) do
            GenServer.call(
              @server,
              {:run_file, remote, content, "#{run_cmd} #{remote}", opts},
              call_timeout(opts)
            )
          end
      end
    else
      {:error, reason} -> {:error, "Could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # --- Optional: lifecycle ---

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def create(opts \\ []) do
    cond do
      cli_path() == nil ->
        {:error, "miosa CLI not found on PATH. Install it, or switch to another sandbox backend."}

      not credential_present?() ->
        {:error, "miosa CLI is not authenticated. Run `miosa login`."}

      # Attach to an operator-provided sandbox instead of provisioning one.
      id = configured_sandbox_id(opts) ->
        Logger.info("[Sandbox.MiosaCli] Attaching to existing sandbox #{id}")
        {:ok, %{id: id, attached: true}}

      true ->
        provision(opts)
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def destroy(%{attached: true, id: id}) do
    # Never destroy a sandbox we did not create - the operator owns its lifetime.
    Logger.info("[Sandbox.MiosaCli] Leaving attached sandbox #{id} running")
    :ok
  end

  def destroy(%{id: id}) do
    case cli(["sandbox", "destroy", id, "--force"], @default_timeout) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Optional: filesystem + networking ---

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def write_file(%{id: id}, path, content) do
    # `write-file` takes literal text or a local path; a temp file avoids both
    # argv length limits and any ambiguity between the two forms.
    tmp = Path.join(System.tmp_dir!(), "osa-sbx-#{unique_token()}")

    try do
      with :ok <- File.write(tmp, content),
           {:ok, _} <- cli(["sandbox", "write-file", id, path, tmp], @default_timeout) do
        :ok
      else
        {:error, reason} when is_binary(reason) -> {:error, "write_file failed: #{reason}"}
        {:error, posix} -> {:error, "write_file failed: #{inspect(posix)}"}
      end
    after
      File.rm(tmp)
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def read_file(%{id: id}, path) do
    case cli(["sandbox", "read-file", id, path], @default_timeout) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "read_file failed: #{reason}"}
    end
  end

  @impl OptimalSystemAgent.Sandbox.Behaviour
  def expose_port(%{id: id}, port) do
    case cli_json(["sandbox", "domain", id, to_string(port)], @default_timeout) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:ok, %{"domain" => domain}} -> {:ok, domain}
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
          {:error, reason} -> {:error, "miosa-cli server failed to start: #{inspect(reason)}"}
        end

      pid ->
        {:ok, pid}
    end
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{session: nil, opts: opts}}
  end

  @impl GenServer
  def handle_call({:exec, command, opts}, _from, state) do
    case ensure_session(state, opts) do
      {:ok, session, state} ->
        reply = exec_in_session(session, command, opts)
        {:reply, reply, maybe_invalidate_session(state, reply)}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:run_file, remote, content, run_cmd, opts}, _from, state) do
    with {:ok, session, state} <- ensure_session(state, opts),
         :ok <- write_file(session, remote, content) do
      reply = exec_in_session(session, run_cmd, opts)
      {:reply, reply, maybe_invalidate_session(state, reply)}
    else
      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Tear down only what we provisioned. An attached sandbox outlives OSA.
  @impl GenServer
  def terminate(_reason, %{session: %{} = session}) do
    destroy(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp ensure_session(%{session: %{} = session} = state, _opts), do: {:ok, session, state}

  defp ensure_session(%{session: nil} = state, opts) do
    case create(Keyword.merge(state.opts, opts)) do
      {:ok, session} -> {:ok, session, %{state | session: session}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Drop the cached session only when the sandbox itself is gone. A command that
  # merely timed out says nothing about the sandbox's health, so - unlike the
  # HTTP backend - a slow build does not cost us the warm sandbox.
  defp maybe_invalidate_session(state, {:error, reason}) when is_binary(reason) do
    if dead_sandbox_error?(reason), do: %{state | session: nil}, else: state
  end

  defp maybe_invalidate_session(state, _reply), do: state

  @doc false
  def dead_sandbox_error?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    Enum.any?(
      ["not found", "404", "410", "destroyed", "does not exist", "no such sandbox"],
      &String.contains?(normalized, &1)
    )
  end

  def dead_sandbox_error?(_), do: false

  # --- Private: exec ---

  defp exec_in_session(%{id: id}, command, opts) do
    timeout_ms = timeout(opts)
    secs = max(div(timeout_ms, 1000), 1)

    args =
      ["sandbox", "exec", id, "--cmd", command, "--timeout", to_string(secs)] ++ cwd_args(opts)

    Logger.info("[Sandbox.MiosaCli] exec: #{String.slice(command, 0, 80)}")

    case cli_json(args, timeout_ms + 15_000) do
      {:ok, body} ->
        format_result(collect_output(body), exit_code(body))

      {:error, reason} ->
        {:error, "MIOSA CLI exec failed: #{reason}"}
    end
  end

  @doc false
  def exit_code(%{"exit_code" => code}) when is_integer(code), do: code

  def exit_code(%{"exit_code" => code}) when is_binary(code) do
    case Integer.parse(code) do
      {n, _} -> n
      :error -> nil
    end
  end

  def exit_code(_), do: nil

  defp cwd_args(opts) do
    case Keyword.get(opts, :working_dir) do
      dir when is_binary(dir) and dir != "" -> ["--cwd", dir]
      _ -> []
    end
  end

  @doc false
  def format_result(output, 0), do: {:ok, output}
  def format_result(output, nil), do: {:ok, output}

  def format_result(output, code) do
    {:ok, output <> "\n[exit code: #{code}]"}
  end

  @doc false
  def collect_output(%{} = body) do
    stdout = to_text(body["stdout"])
    stderr = to_text(body["stderr"])

    case {stdout, stderr} do
      {"", ""} -> ""
      {out, ""} -> out
      {"", err} -> err
      {out, err} -> out <> "\n" <> err
    end
  end

  def collect_output(body), do: to_text(body)

  defp to_text(nil), do: ""
  defp to_text(v) when is_binary(v), do: v
  defp to_text(v), do: inspect(v)

  # --- Private: provisioning ---

  defp provision(opts) do
    size = Keyword.get(opts, :size, config()[:size] || @default_size)
    idle = config()[:idle_timeout] || @default_idle_timeout
    label = "osa-#{unique_token()}"

    args = [
      "sandbox",
      "create",
      "--name",
      label,
      "--size",
      size,
      "--idle-timeout",
      idle,
      "--idempotency-key",
      label,
      "--wait"
    ]

    Logger.info("[Sandbox.MiosaCli] Creating sandbox #{label} (size=#{size}, idle=#{idle})")

    case cli_json(args, 180_000) do
      {:ok, %{} = body} ->
        case body["id"] || body["sandbox_id"] || body["slug"] do
          nil -> {:error, "Create sandbox: no id in response #{inspect(body)}"}
          id -> {:ok, %{id: to_string(id), attached: false}}
        end

      {:ok, other} ->
        {:error, "Create sandbox: unexpected response #{inspect(other)}"}

      {:error, reason} ->
        {:error, "Create sandbox failed: #{reason}"}
    end
  end

  defp configured_sandbox_id(opts) do
    value = Keyword.get(opts, :sandbox_id) || config()[:sandbox_id]

    case value do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: id
      _ -> nil
    end
  end

  # --- Private: CLI invocation ---

  defp cli_json(args, timeout_ms) do
    with {:ok, raw} <- cli(["--json" | args], timeout_ms) do
      case Jason.decode(raw) do
        {:ok, decoded} -> unwrap_envelope(decoded)
        # A command that succeeded but printed no JSON is still a success.
        {:error, _} -> {:ok, %{"stdout" => raw}}
      end
    end
  end

  # The CLI reports its own failures as `{"ok": false, "error": {...}}` and can
  # still exit 0 doing it, so the envelope has to be checked separately from the
  # process status. This is a broken sandbox, not a failing command.
  defp unwrap_envelope(%{"ok" => false} = body) do
    error = body["error"] || %{}

    detail =
      [error["code"], error["message"], error["details"]]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" - ")

    {:error, if(detail == "", do: inspect(body), else: detail)}
  end

  defp unwrap_envelope(%{} = body), do: {:ok, body}
  defp unwrap_envelope(other), do: {:ok, %{"stdout" => to_text(other)}}

  defp cli(args, timeout_ms) do
    case cli_path() do
      nil ->
        {:error, "miosa CLI not found on PATH"}

      path ->
        task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: false) end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, 0}} ->
            {:ok, out}

          {:ok, {out, status}} ->
            {:error, "miosa exited #{status}: #{String.trim(out)}"}

          nil ->
            {:error, "miosa CLI timed out after #{timeout_ms}ms"}
        end
    end
  rescue
    e -> {:error, "miosa CLI invocation error: #{Exception.message(e)}"}
  end

  @doc false
  def cli_path do
    case Application.get_env(:optimal_system_agent, :miosa_cli_path) do
      path when is_binary(path) -> if File.exists?(path), do: path, else: nil
      _ -> System.find_executable("miosa")
    end
  end

  # `miosa login` is the normal path and writes ~/.miosa/config.json; an explicit
  # env var still wins for CI and headless installs.
  @doc false
  def credential_present? do
    env_key?() or cli_config_key?()
  end

  defp env_key? do
    case System.get_env("MIOSA_PLATFORM_API_KEY") do
      key when is_binary(key) -> String.trim(key) != ""
      _ -> false
    end
  end

  defp cli_config_key? do
    path =
      Path.expand(
        Application.get_env(:optimal_system_agent, :miosa_cli_config) || "~/.miosa/config.json"
      )

    with {:ok, raw} <- File.read(path),
         {:ok, %{"api_key" => key}} <- Jason.decode(raw),
         true <- is_binary(key) and String.trim(key) != "" do
      true
    else
      _ -> false
    end
  end

  # --- Private: misc ---

  # `:erlang.unique_integer/1` restarts its counter with the VM, so two OSA runs
  # mint the same value. As an idempotency key that is actively harmful: the
  # platform retains keys for 24h and tries to *resume* the prior sandbox, which
  # fails once that sandbox has been destroyed. Randomness, not a counter.
  defp unique_token do
    8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp interpreter(".py"), do: "python3"
  defp interpreter(".js"), do: "node"
  defp interpreter(".mjs"), do: "node"
  defp interpreter(".ts"), do: "npx --yes tsx"
  defp interpreter(".rb"), do: "ruby"
  defp interpreter(".sh"), do: "sh"
  defp interpreter(".exs"), do: "elixir"
  defp interpreter(_), do: nil

  defp timeout(opts) do
    Keyword.get(opts, :timeout) || to_ms(config()[:timeout]) || @default_timeout
  end

  # The documented config key is seconds; accept milliseconds too so an operator
  # who writes 30_000 does not silently get a 30_000 second timeout.
  defp to_ms(nil), do: nil
  defp to_ms(n) when is_integer(n) and n >= 1000, do: n
  defp to_ms(n) when is_integer(n) and n > 0, do: n * 1000
  defp to_ms(_), do: nil

  defp call_timeout(opts), do: timeout(opts) + 30_000

  defp config, do: Application.get_env(:optimal_system_agent, :sandbox_miosa_cli, %{})
end
