defmodule OptimalSystemAgent.Sandbox.E2B do
  @moduledoc """
  E2B.dev cloud sandbox backend — runs code in isolated cloud VMs.

  Requires an E2B API key. Each execution gets a fresh sandbox that
  auto-destroys after the timeout.

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

  Or set E2B_API_KEY environment variable.
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  require Logger

  @api_url "https://api.e2b.dev/v1"

  @impl true
  def available? do
    api_key() != nil
  end

  @impl true
  def name, do: "e2b (cloud sandbox)"

  @impl true
  def execute(command, opts \\ []) do
    case api_key() do
      nil ->
        {:error, "E2B API key not configured. Set E2B_API_KEY or add to ~/.osa/sandbox.json"}

      key ->
        timeout = Keyword.get(opts, :timeout, 30_000)
        template = Keyword.get(opts, :template, "base")

        Logger.info("[Sandbox.E2B] Running in cloud sandbox: #{String.slice(command, 0, 80)}")

        # Create sandbox, execute, collect output, destroy
        with {:ok, sandbox_id} <- create_sandbox(key, template),
             {:ok, output} <- run_command(key, sandbox_id, command, timeout),
             :ok <- destroy_sandbox(key, sandbox_id) do
          {:ok, output}
        else
          {:error, reason} -> {:error, "E2B error: #{reason}"}
        end
    end
  end

  @impl true
  def run_file(path, opts \\ []) do
    content = File.read!(path)
    ext = Path.extname(path)

    command =
      case ext do
        ".py" ->
          "cat << 'SCRIPT_EOF' > /tmp/script.py\n#{content}\nSCRIPT_EOF\npython3 /tmp/script.py"

        ".js" ->
          "cat << 'SCRIPT_EOF' > /tmp/script.js\n#{content}\nSCRIPT_EOF\nnode /tmp/script.js"

        _ ->
          "cat << 'SCRIPT_EOF' > /tmp/script#{ext}\n#{content}\nSCRIPT_EOF\nsh /tmp/script#{ext}"
      end

    execute(command, opts)
  rescue
    e -> {:error, "Failed to read file: #{Exception.message(e)}"}
  end

  # --- Private ---

  defp api_key do
    System.get_env("E2B_API_KEY") ||
      Application.get_env(:optimal_system_agent, :e2b_api_key)
  end

  defp create_sandbox(key, template) do
    body = Jason.encode!(%{template: template})

    case Req.post("#{@api_url}/sandboxes",
           body: body,
           headers: [{"Authorization", "Bearer #{key}"}, {"Content-Type", "application/json"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: s, body: %{"id" => id}}} when s in 200..299 -> {:ok, id}
      {:ok, %{body: body}} -> {:error, "Create sandbox failed: #{inspect(body)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp run_command(key, sandbox_id, command, timeout) do
    body = Jason.encode!(%{cmd: command, timeout: div(timeout, 1000)})

    case Req.post("#{@api_url}/sandboxes/#{sandbox_id}/execute",
           body: body,
           headers: [{"Authorization", "Bearer #{key}"}, {"Content-Type", "application/json"}],
           receive_timeout: timeout + 5_000
         ) do
      {:ok, %{status: s, body: %{"stdout" => out}}} when s in 200..299 -> {:ok, out}
      {:ok, %{body: body}} -> {:error, "Execute failed: #{inspect(body)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp destroy_sandbox(key, sandbox_id) do
    Req.delete("#{@api_url}/sandboxes/#{sandbox_id}",
      headers: [{"Authorization", "Bearer #{key}"}],
      receive_timeout: 5_000
    )

    :ok
  rescue
    _ -> :ok
  end
end
