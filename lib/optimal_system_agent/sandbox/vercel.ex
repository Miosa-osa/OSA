defmodule OptimalSystemAgent.Sandbox.Vercel do
  @moduledoc """
  Vercel Sandbox backend — runs code in Vercel's isolated Linux microVMs.

  OSA itself runs **off-Vercel**, so this backend authenticates with a Vercel
  **Access Token** and is scoped to a team + project:

    * `VERCEL_TOKEN`      — access token (`Authorization: Bearer <token>`)
    * `VERCEL_TEAM_ID`    — team scope (`?teamId=`)
    * `VERCEL_PROJECT_ID` — project scope (`?projectId=`)

  ## Two planes

    * **Control plane (REST, confirmed):** the sandbox lifecycle is available as
      REST under `https://api.vercel.com` — `POST /v2/sandboxes` (create),
      `GET /v2/sandboxes/{name}` (get/resume), delete/stop. These are used for
      `create/1` + `destroy/1`.
    * **Command execution:** Vercel exposes command execution / file APIs
      primarily through its JS SDK (`@vercel/sandbox` — `runCommand`,
      `writeFiles`, …). A stable REST-only "run command" path is **not currently
      confirmable**, so `execute/2` and `run_file/2` shell out to a minimal
      `@vercel/sandbox` helper via `node`.

  > **⚠ NEEDS ENDPOINT VERIFICATION:** the `execute/2` / `run_file/2` path below
  > relies on a `node` + `@vercel/sandbox` helper resolvable in the ambient
  > environment. OSA does **not** declare a runtime dependency on the JS SDK; if
  > the SDK is not present the command returns a clear error. Replace this shell
  > shim with a direct REST call once Vercel documents a stable run-command
  > endpoint.

  ## Configuration

  ```json ~/.osa/sandbox.json
  {
    "backend": "vercel",
    "vercel": {
      "token": "...",
      "team_id": "team_...",
      "project_id": "prj_...",
      "runtime": "node22",
      "timeout": 30
    }
  }
  ```

  Or set `VERCEL_TOKEN`, `VERCEL_TEAM_ID`, and `VERCEL_PROJECT_ID`.
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  require Logger

  @api_url "https://api.vercel.com"
  @default_runtime "node22"
  @default_timeout 30_000

  # --- Required core ---

  @impl true
  def available? do
    token() != nil and team_id() != nil and project_id() != nil
  end

  @impl true
  def name, do: "vercel (cloud sandbox)"

  @impl true
  def execute(command, opts \\ []) do
    with :ok <- ensure_configured(),
         :ok <- ensure_node() do
      Logger.info("[Sandbox.Vercel] exec: #{String.slice(command, 0, 80)}")
      run_via_helper(%{run: command}, opts)
    end
  end

  @impl true
  def run_file(path, opts \\ []) do
    content = File.read!(path)
    ext = Path.extname(path)
    remote = "script#{ext}"

    run_cmd =
      case ext do
        ".py" -> "python3 #{remote}"
        ".js" -> "node #{remote}"
        ".ts" -> "npx tsx #{remote}"
        ".sh" -> "bash #{remote}"
        _ -> "sh #{remote}"
      end

    with :ok <- ensure_configured(),
         :ok <- ensure_node() do
      run_via_helper(%{write: %{path: remote, content: content}, run: run_cmd}, opts)
    end
  rescue
    e -> {:error, "Failed to read file: #{Exception.message(e)}"}
  end

  # --- Optional: session lifecycle (REST control plane, confirmed) ---

  @impl true
  def create(opts \\ []) do
    with :ok <- ensure_configured() do
      runtime = Keyword.get(opts, :runtime, config()[:runtime] || @default_runtime)
      secs = div(timeout(opts), 1000)
      body = %{runtime: runtime, timeout: secs}

      Logger.info("[Sandbox.Vercel] Creating sandbox (runtime=#{runtime})")

      case Req.post("#{@api_url}/v2/sandboxes",
             json: body,
             params: scope_params(),
             headers: headers(),
             receive_timeout: @default_timeout
           ) do
        {:ok, %{status: s, body: %{"sandboxId" => id} = b}} when s in 200..299 ->
          {:ok, %{id: id, name: b["name"], url: b["url"]}}

        {:ok, %{status: s, body: %{"id" => id} = b}} when s in 200..299 ->
          {:ok, %{id: id, name: b["name"], url: b["url"]}}

        {:ok, %{body: b}} ->
          {:error, "Create sandbox failed: #{inspect(b)}"}

        {:error, e} ->
          {:error, inspect(e)}
      end
    end
  end

  @impl true
  def destroy(%{id: id}) do
    Req.delete("#{@api_url}/v2/sandboxes/#{id}",
      params: scope_params(),
      headers: headers(),
      receive_timeout: 5_000
    )

    :ok
  rescue
    _ -> :ok
  end

  # --- Private ---

  # Shell to a minimal @vercel/sandbox helper. NEEDS ENDPOINT VERIFICATION —
  # replace with a direct REST call once a run-command endpoint is documented.
  defp run_via_helper(plan, opts) do
    script = helper_script()

    env = [
      {"VERCEL_TOKEN", token()},
      {"VERCEL_TEAM_ID", team_id()},
      {"VERCEL_PROJECT_ID", project_id()},
      {"OSA_SANDBOX_PLAN", Jason.encode!(plan)}
    ]

    timeout = timeout(opts) + 5_000

    try do
      task =
        Task.async(fn ->
          System.cmd("node", ["-e", script],
            env: OptimalSystemAgent.OS.Env.cmd_env(env),
            stderr_to_stdout: true
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, code}} -> {:error, "Vercel helper exit #{code}: #{output}"}
        nil -> {:error, "Vercel helper timed out after #{div(timeout, 1000)}s"}
      end
    rescue
      e -> {:error, "Vercel helper failed (@vercel/sandbox present?): #{Exception.message(e)}"}
    end
  end

  # Minimal Node helper: reads a JSON "plan" from OSA_SANDBOX_PLAN, optionally
  # writes a file, then runs a command via @vercel/sandbox and prints stdout.
  defp helper_script do
    """
    (async () => {
      const { Sandbox } = require('@vercel/sandbox');
      const plan = JSON.parse(process.env.OSA_SANDBOX_PLAN || '{}');
      const sandbox = await Sandbox.create();
      try {
        if (plan.write) {
          await sandbox.writeFiles([
            { path: plan.write.path, content: Buffer.from(plan.write.content) },
          ]);
        }
        if (plan.run) {
          const [cmd, ...args] = plan.run.split(' ');
          const res = await sandbox.runCommand(cmd, args);
          process.stdout.write(await res.stdout());
          const err = await res.stderr();
          if (err) process.stdout.write(err);
        }
      } finally {
        await sandbox.stop();
      }
    })().catch((e) => { console.error(e && e.message ? e.message : e); process.exit(1); });
    """
  end

  defp ensure_configured do
    if available?() do
      :ok
    else
      {:error,
       "Vercel sandbox not configured. Set VERCEL_TOKEN, VERCEL_TEAM_ID and VERCEL_PROJECT_ID."}
    end
  end

  defp ensure_node do
    case System.find_executable("node") do
      nil -> {:error, "Vercel backend requires `node` (with @vercel/sandbox) on PATH."}
      _ -> :ok
    end
  end

  defp scope_params, do: [teamId: team_id(), projectId: project_id()]

  defp headers do
    [{"Authorization", "Bearer #{token()}"}, {"Content-Type", "application/json"}]
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, config()[:timeout_ms] || @default_timeout)

  defp config, do: Application.get_env(:optimal_system_agent, :sandbox_vercel, %{})

  defp token do
    System.get_env("VERCEL_TOKEN") || config()[:token]
  end

  defp team_id do
    System.get_env("VERCEL_TEAM_ID") || config()[:team_id]
  end

  defp project_id do
    System.get_env("VERCEL_PROJECT_ID") || config()[:project_id]
  end
end
