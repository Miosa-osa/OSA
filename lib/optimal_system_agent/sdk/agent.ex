defmodule OptimalSystemAgent.SDK.Agent do
  @moduledoc """
  Define custom agents for the SDK.

  SDK agents are stored in ETS (`:osa_sdk_agents`) and transparently merged
  into Roster lookups. This allows external applications to extend the agent
  roster at runtime without modifying the compiled `@agents` map.

  ## Example

      OptimalSystemAgent.SDK.Agent.define("custom-reviewer", %{
        tier: :specialist,
        role: :qa,
        description: "Custom code reviewer with domain-specific rules",
        skills: ["file_read"],
        triggers: ["custom review", "domain check"],
        territory: ["*.ex"],
        escalate_to: nil,
        prompt: "You are a custom code reviewer..."
      })
  """

  alias OptimalSystemAgent.Agent.Roster

  @table :osa_sdk_agents

  @doc """
  Ensure the ETS table for SDK agents exists.

  Called by `SDK.Supervisor` during embedded boot. Safe to call multiple times.
  """
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Define and register a custom agent.

  The agent definition must include: tier, role, description, skills, triggers,
  territory, escalate_to, and prompt. The name must be unique across both
  the compiled roster and SDK agents.

  Returns `:ok` on success, `{:error, reason}` on conflict.
  """
  @spec define(String.t(), map()) :: :ok | {:error, term()}
  def define(name, definition) when is_binary(name) and is_map(definition) do
    init_table()

    # Check for conflict with compiled roster
    if Roster.get(name) != nil and not sdk_agent?(name) do
      {:error, {:conflict, "Agent '#{name}' already exists in compiled roster"}}
    else
      agent_def =
        Map.merge(
          %{
            name: name,
            tier: :specialist,
            role: :backend,
            description: "",
            skills: [],
            triggers: [],
            territory: ["*"],
            escalate_to: nil,
            prompt: ""
          },
          definition
        )
        |> Map.put(:name, name)

      :ets.insert(@table, {name, agent_def})
      :ok
    end
  end

  @doc """
  Remove a previously defined SDK agent.
  """
  @spec undefine(String.t()) :: :ok
  def undefine(name) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, name)
    end

    :ok
  end

  @doc """
  Get all SDK-defined agents as a map.

  Returns `%{}` if the ETS table doesn't exist (standalone mode).
  """
  @spec all() :: %{String.t() => Roster.agent_def()}
  def all do
    if :ets.whereis(@table) != :undefined do
      @table |> :ets.tab2list() |> Map.new()
    else
      %{}
    end
  end

  @doc """
  Get a single SDK agent by name.
  """
  @spec get(String.t()) :: Roster.agent_def() | nil
  def get(name) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, name) do
        [{^name, def}] -> def
        [] -> nil
      end
    end
  end

  @doc """
  List all SDK agent names.
  """
  @spec list_names() :: [String.t()]
  def list_names do
    all() |> Map.keys()
  end

  # Check if a name exists as an SDK agent (not compiled)
  defp sdk_agent?(name) do
    if :ets.whereis(@table) != :undefined do
      :ets.member(@table, name)
    else
      false
    end
  end
end
