defmodule OptimalSystemAgent.Sandbox.E2B do
  @moduledoc """
  E2B cloud sandbox backend — runs code in isolated cloud microVMs.

  This is the **reference REST-from-Elixir** implementation (using `Req`).
  It talks to two planes of the E2B API:

    * **Control plane** — `https://api.e2b.app` handles the sandbox lifecycle
      (create / kill / pause / resume). Authenticated with the `X-API-Key`
      header using a key that starts with `e2b_`.
    * **Data plane** — command execution and filesystem access happen against
      the individual sandbox's own `envd` host (returned as `domain` in the
      create response), NOT the central API. envd exposes an HTTP `/files`
      route for reads/writes and a process route for command execution.

  Each sandbox can be used one-shot (`execute/2` creates → runs → kills) or as a
  warm, reusable session via the optional `create/1` + `destroy/1` callbacks.

  ## Configuration

  ```json ~/.osa/sandbox.json
  {
    "backend": "e2b",
    "e2b": {
      "api_key": "e2b_...",
      "template": "base",
      "timeout": 30
    }
  }
  ```

  Or set the `E2B_API_KEY` environment variable (key starts with `e2b_`).

  > **Note:** The envd data-plane command endpoint is a streaming Connect-RPC
  > service; the synchronous HTTP shape used here (`49983-<host>`) should be
  > re-verified against the envd version pinned by your template.
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  require Logger

  # Control plane (sandbox lifecycle). Was incorrectly https://api.e2b.dev/v1.
  @api_url "https://api.e2b.app"
  # envd (data plane) listens on this port on the sandbox host.
  @envd_port 49_983
  @default_timeout 30_000

  # --- Required core ---

  @impl true
  def available?, do: api_key() != nil

  @impl true
  def name, do: "e2b (cloud sandbox)"

  @impl true
  def execute(command, opts \\ []) do
    case Keyword.get(opts, :session) do
      nil ->
        # One-shot: create → run → kill.
        with {:ok, session} <- create(opts) do
          try do
            exec_in_session(session, command, timeout(opts))
          after
            destroy(session)
          end
        end

      session ->
        # Warm reuse: run against an existing session.
        exec_in_session(session, command, timeout(opts))
    end
  end

  @impl true
  def run_file(path, opts \\ []) do
    content = File.read!(path)
    ext = Path.extname(path)
    remote = "/tmp/script#{ext}"

    run_cmd =
      case ext do
        ".py" -> "python3 #{remote}"
        ".js" -> "node #{remote}"
        ".ts" -> "npx tsx #{remote}"
        ".sh" -> "sh #{remote}"
        _ -> "sh #{remote}"
      end

    with {:ok, session} <- create(opts) do
      try do
        with :ok <- write_file(session, remote, content) do
          exec_in_session(session, run_cmd, timeout(opts))
        end
      after
        destroy(session)
      end
    end
  rescue
    e -> {:error, "Failed to read file: #{Exception.message(e)}"}
  end

  # --- Optional: session lifecycle ---

  @impl true
  def create(opts \\ []) do
    case api_key() do
      nil ->
        {:error, "E2B API key not configured. Set E2B_API_KEY or add to ~/.osa/sandbox.json"}

      key ->
        template = Keyword.get(opts, :template, config()[:template] || "base")
        secs = div(timeout(opts), 1000)
        body = %{templateID: template, timeout: secs}

        Logger.info("[Sandbox.E2B] Creating sandbox (template=#{template})")

        case Req.post("#{@api_url}/sandboxes",
               json: body,
               headers: control_headers(key),
               receive_timeout: @default_timeout
             ) do
          {:ok, %{status: s, body: %{"sandboxID" => id} = b}} when s in 200..299 ->
            {:ok,
             %{
               id: id,
               client_id: b["clientID"],
               domain: b["domain"] || "e2b.app",
               access_token: b["envdAccessToken"],
               key: key
             }}

          {:ok, %{body: b}} ->
            {:error, "Create sandbox failed: #{inspect(b)}"}

          {:error, e} ->
            {:error, inspect(e)}
        end
    end
  end

  @impl true
  def destroy(%{id: id, key: key}) do
    Req.delete("#{@api_url}/sandboxes/#{id}",
      headers: control_headers(key),
      receive_timeout: 5_000
    )

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def write_file(%{} = session, path, content) do
    # envd HTTP filesystem route: PUT /files?path=<path>
    case Req.post(envd_url(session, "/files"),
           params: [path: path],
           headers: envd_headers(session),
           form_multipart: [file: content],
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "write_file failed (#{s}): #{inspect(b)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  @impl true
  def read_file(%{} = session, path) do
    case Req.get(envd_url(session, "/files"),
           params: [path: path],
           headers: envd_headers(session),
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, to_string(b)}
      {:ok, %{status: s, body: b}} -> {:error, "read_file failed (#{s}): #{inspect(b)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  @impl true
  def expose_port(%{id: id, client_id: client_id, domain: domain}, port) do
    # E2B preview URLs are deterministic: <port>-<sandboxID>-<clientID>.<domain>
    host = [id, client_id] |> Enum.reject(&is_nil/1) |> Enum.join("-")
    {:ok, "https://#{port}-#{host}.#{domain}"}
  end

  # --- Private ---

  defp exec_in_session(%{} = session, command, timeout) do
    Logger.info("[Sandbox.E2B] exec: #{String.slice(command, 0, 80)}")

    # NOTE: envd command execution is a Connect-RPC process service; this
    # synchronous POST shape should be verified against your envd version.
    body = %{cmd: command, timeout: div(timeout, 1000)}

    case Req.post(envd_url(session, "/commands"),
           json: body,
           headers: envd_headers(session),
           receive_timeout: timeout + 5_000
         ) do
      {:ok, %{status: s, body: %{"stdout" => out} = b}} when s in 200..299 ->
        {:ok, out <> (b["stderr"] || "")}

      {:ok, %{status: s, body: b}} when s in 200..299 ->
        {:ok, to_string(b)}

      {:ok, %{body: b}} ->
        {:error, "E2B execute failed: #{inspect(b)}"}

      {:error, e} ->
        {:error, "E2B error: #{inspect(e)}"}
    end
  end

  defp envd_url(%{id: id, client_id: client_id, domain: domain}, path) do
    host = [id, client_id] |> Enum.reject(&is_nil/1) |> Enum.join("-")
    "https://#{@envd_port}-#{host}.#{domain}#{path}"
  end

  defp control_headers(key) do
    [{"X-API-Key", key}, {"Content-Type", "application/json"}]
  end

  defp envd_headers(%{access_token: token}) when is_binary(token) do
    [{"X-Access-Token", token}]
  end

  defp envd_headers(_session), do: []

  defp timeout(opts), do: Keyword.get(opts, :timeout, config()[:timeout_ms] || @default_timeout)

  defp config, do: Application.get_env(:optimal_system_agent, :sandbox_e2b, %{})

  defp api_key do
    System.get_env("E2B_API_KEY") ||
      Application.get_env(:optimal_system_agent, :e2b_api_key)
  end
end
