defmodule OptimalSystemAgent.Tools.Builtins.VaultContext do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "vault_context"

  @impl true
  def description, do: "Build profiled context from vault memories for a task or query"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "profile" => %{
          "type" => "string",
          "description" => "Context profile: default, planning, incident, handoff",
          "enum" => ["default", "planning", "incident", "handoff"]
        },
        "query" => %{
          "type" => "string",
          "description" => "Optional query to filter relevant memories"
        }
      },
      "required" => []
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
  def execute(_args) do
    {:error, "vault context is not available in this build"}
  end
end
