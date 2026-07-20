defmodule OptimalSystemAgent.Tools.Builtins.VaultCheckpoint do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "vault_checkpoint"

  @impl true
  def description,
    do: "Create a mid-session vault checkpoint — flushes observations and refreshes dirty flag"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Session identifier"}
      },
      "required" => ["session_id"]
    }
  end

  # `OptimalSystemAgent.Vault` does not exist in this build (there is no vault
  # backend yet — see the `@allowlist` comment in
  # `test/optimal_system_agent/tools/registry_coverage_test.exs`). This tool
  # is intentionally NOT wired into `Tools.Registry.load_builtin_tools/0`, so
  # the model never sees or calls it today. Still, `execute/1` must never
  # raise `UndefinedFunctionError` if it is ever invoked directly (a future
  # registration mistake, a direct call from other code, …) — fail with a
  # normal, honest tool error instead.
  @impl true
  def execute(%{"session_id" => _session_id}) do
    {:error, "vault checkpoint is not available in this build"}
  end
end
