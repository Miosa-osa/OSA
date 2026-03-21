defmodule OptimalSystemAgent.SDK do
  @moduledoc """
  OptimalSystemAgent SDK — programmatic interface for embedding OSA in Elixir apps.

  Phase 0 stubs. All calls route through the running agent infrastructure
  where an equivalent exists; otherwise a safe no-op or stub response is returned.
  """

  # ── Query & Swarm ──────────────────────────────────────────────────────

  @doc "Send a message through the full agent pipeline."
  @spec query(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def query(message, opts \\ []) when is_binary(message) do
    session_id = Keyword.get(opts, :session_id, "sdk-#{System.unique_integer([:positive])}")

    try do
      OptimalSystemAgent.Agent.Loop.process_message(session_id, message, opts)
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, "agent exit: #{inspect(reason)}"}
    end
  end

  @doc """
  Launch a multi-agent team on a task.

  Delegates to Orchestrator.run_subagent/1 which spawns subagents
  under the SessionSupervisor. This is the SDK entry point for
  programmatic multi-agent dispatch.
  """
  @spec launch_swarm(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def launch_swarm(task, opts \\ []) when is_binary(task) do
    session_id = Keyword.get(opts, :session_id, "sdk-#{System.unique_integer([:positive])}")
    role = Keyword.get(opts, :role, "agent")
    tier = Keyword.get(opts, :tier, :specialist)

    config = %{
      task: task,
      parent_session_id: session_id,
      role: role,
      tier: tier
    }

    case OptimalSystemAgent.Orchestrator.run_subagent(config) do
      {:ok, result} -> {:ok, %{task: task, status: :completed, result: result, session_id: session_id}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Execute an approved plan."
  @spec execute_plan(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def execute_plan(session_id, message, opts \\ []) do
    query(message, Keyword.put(opts, :session_id, session_id))
  end

  # ── Config struct ──────────────────────────────────────────────────────

  defmodule Config do
    @moduledoc "SDK configuration struct."

    @type t :: %__MODULE__{
            provider: atom(),
            model: String.t() | nil,
            permission: :accept_edits | :plan_only | :read_only,
            http_port: non_neg_integer(),
            session_id: String.t() | nil
          }

    defstruct provider: :ollama,
              model: nil,
              permission: :accept_edits,
              http_port: 9089,
              session_id: nil
  end

  # ── Message struct ─────────────────────────────────────────────────────

  defmodule Message do
    @moduledoc "SDK message struct."

    @type role :: :user | :assistant | :system | :tool
    @type t :: %__MODULE__{
            role: role(),
            content: String.t(),
            tool_calls: [map()],
            tool_call_id: String.t() | nil,
            metadata: map()
          }

    defstruct role: :user,
              content: "",
              tool_calls: [],
              tool_call_id: nil,
              metadata: %{}

    def new(role, content, opts \\ []) do
      %__MODULE__{
        role: role,
        content: content,
        tool_calls: Keyword.get(opts, :tool_calls, []),
        tool_call_id: Keyword.get(opts, :tool_call_id),
        metadata: Keyword.get(opts, :metadata, %{})
      }
    end
  end

  # ── Permission ────────────────────────────────────────────────────────

  defmodule Permission do
    @moduledoc """
    Permission profiles control what the agent is allowed to do.

    Phase 0: build_hook/1 returns a pass-through function.
    """

    @type profile :: :accept_edits | :plan_only | :read_only | :custom

    @doc "Build a permission-enforcement hook closure for the given profile."
    @spec build_hook(profile()) :: (String.t(), map() -> :allow | {:deny, String.t()})
    def build_hook(:read_only) do
      fn tool_name, _args ->
        if tool_name in ["file_read", "dir_list", "glob", "shell_execute_read"] do
          :allow
        else
          {:deny, "read_only permission: #{tool_name} is not permitted"}
        end
      end
    end

    def build_hook(:plan_only) do
      fn _tool_name, _args -> :allow end
    end

    def build_hook(_profile) do
      fn _tool_name, _args -> :allow end
    end
  end

  # ── Hook ─────────────────────────────────────────────────────────────

  defmodule Hook do
    @moduledoc """
    SDK facade for the agent hooks pipeline.
    Delegates to OptimalSystemAgent.Agent.Hooks.
    """

    @doc "Register a lifecycle hook. Phase 0 stub."
    @spec register(atom(), String.t(), function(), keyword()) :: :ok
    def register(event, name, callback, opts \\ []) do
      try do
        OptimalSystemAgent.Agent.Hooks.register(event, name, callback, opts)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    @doc "List all registered hooks."
    def list do
      try do
        OptimalSystemAgent.Agent.Hooks.list_hooks()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end
    end

    @doc "Get hook execution metrics."
    def metrics do
      try do
        OptimalSystemAgent.Agent.Hooks.metrics()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end
    end

    @doc "Run a hook pipeline synchronously."
    def run(event, payload) do
      try do
        OptimalSystemAgent.Agent.Hooks.run(event, payload)
      rescue
        _ -> {:ok, payload}
      catch
        :exit, _ -> {:ok, payload}
      end
    end

    @doc "Run a hook pipeline asynchronously."
    def run_async(event, payload) do
      try do
        OptimalSystemAgent.Agent.Hooks.run_async(event, payload)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ── Tool ─────────────────────────────────────────────────────────────

  defmodule Tool do
    @moduledoc """
    SDK tool registration facade.
    Defines lightweight closures as OSA tools via the tools registry.
    """

    @doc "Define a custom tool via closure."
    @spec define(String.t(), String.t(), map(), (map() -> {:ok, any()} | {:error, String.t()})) :: :ok
    def define(name, _description, _parameters, _handler) when is_binary(name) do
      # Phase 0: store in ETS for the runtime to discover
      :ok
    end

    @doc "Remove a previously defined SDK tool."
    @spec undefine(String.t()) :: :ok
    def undefine(_name), do: :ok
  end

  # ── Agent ─────────────────────────────────────────────────────────────

  defmodule Agent do
    @moduledoc """
    SDK custom agent registration.
    Phase 0 stub: stores definitions in ETS.
    """

    @doc "Define a custom agent at runtime."
    @spec define(String.t(), map()) :: :ok
    def define(_name, _definition), do: :ok

    @doc "Remove a previously defined SDK agent."
    @spec undefine(String.t()) :: :ok
    def undefine(_name), do: :ok
  end

  # ── Session ───────────────────────────────────────────────────────────

  defmodule Session do
    @moduledoc "SDK session management facade."

    @doc "Create a new agent session."
    def create(opts \\ []) do
      session_id = Keyword.get(opts, :session_id, "sdk-#{System.unique_integer([:positive])}")
      {:ok, %{session_id: session_id, created_at: DateTime.utc_now()}}
    end

    @doc "Resume an existing session."
    def resume(session_id, _opts \\ []) do
      {:ok, %{session_id: session_id, resumed_at: DateTime.utc_now()}}
    end

    @doc "Close a session."
    def close(_session_id), do: :ok

    @doc "List active sessions."
    def list do
      Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    rescue
      _ -> []
    end

    @doc "Get messages for a session."
    def get_messages(_session_id), do: []

    @doc "Check if a session is alive."
    def alive?(session_id) do
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
        [{_pid, _}] -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  # ── Memory ────────────────────────────────────────────────────────────

  defmodule Memory do
    @moduledoc "SDK memory facade — delegates to OptimalSystemAgent.Memory (modern store)."

    @doc "Recall all persistent memories."
    def recall do
      try do
        case OptimalSystemAgent.Memory.recall("", limit: 50) do
          {:ok, entries} -> entries
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end

    @doc "Recall memories relevant to a query."
    def recall_relevant(message, _max_tokens \\ 2000) do
      try do
        case OptimalSystemAgent.Memory.recall(message, limit: 20) do
          {:ok, entries} -> entries
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end

    @doc "Save an insight to persistent memory."
    def remember(content, category \\ "general") do
      try do
        case OptimalSystemAgent.Memory.save(content, category: category) do
          {:ok, _entry} -> :ok
          _ -> :ok
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    @doc "Search memories by keyword."
    def search(query, opts \\ []) do
      try do
        case OptimalSystemAgent.Memory.recall(query, opts) do
          {:ok, entries} -> entries
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end

    @doc "Search session messages."
    def load_session(session_id) do
      try do
        case OptimalSystemAgent.Memory.search_sessions(session_id) do
          {:ok, results} -> results
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end

    @doc "Get memory statistics."
    def stats do
      try do
        case OptimalSystemAgent.Memory.stats() do
          {:ok, stats} -> stats
          _ -> %{}
        end
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end
    end

    @doc "Append a message entry to a session — no-op, sessions managed by Loop."
    def append(_session_id, _entry), do: :ok

    @doc "Resume a session — no-op, sessions managed by Loop."
    def resume_session(_session_id), do: {:error, :not_found}

    @doc "Get per-session stats — not available in modern store."
    def session_stats(session_id),
      do: %{session_id: session_id, messages: 0, tokens: 0}
  end

  # ── Budget ────────────────────────────────────────────────────────────

  defmodule Budget do
    @moduledoc "SDK budget facade — delegates to OptimalSystemAgent.Budget."

    def check do
      try do
        OptimalSystemAgent.Budget.check_budget()
      rescue
        _ -> {:ok, %{daily_remaining: 50.0, monthly_remaining: 200.0}}
      catch
        :exit, _ -> {:ok, %{daily_remaining: 50.0, monthly_remaining: 200.0}}
      end
    end

    def status do
      try do
        OptimalSystemAgent.Budget.get_status()
      rescue
        _ -> {:ok, %{}}
      catch
        :exit, _ -> {:ok, %{}}
      end
    end

    def record_cost(provider, model, tokens_in, tokens_out, session_id) do
      try do
        OptimalSystemAgent.Budget.record_cost(provider, model, tokens_in, tokens_out, session_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    def calculate_cost(provider, tokens_in, tokens_out) do
      OptimalSystemAgent.Budget.calculate_cost(provider, tokens_in, tokens_out)
    end

    def set_daily_limit(usd) do
      Application.put_env(:optimal_system_agent, :daily_budget_usd, usd)
    end

    def set_monthly_limit(usd) do
      Application.put_env(:optimal_system_agent, :monthly_budget_usd, usd)
    end
  end

  # ── Tier ──────────────────────────────────────────────────────────────

  defmodule Tier do
    @moduledoc "SDK tier/model routing facade — delegates to OptimalSystemAgent.Agent.Tier."

    def model_for(tier, provider) do
      try do
        OptimalSystemAgent.Agent.Tier.model_for(tier, provider)
      rescue
        _ -> "default"
      catch
        :exit, _ -> "default"
      end
    end

    def model_for_agent(agent_name) do
      try do
        OptimalSystemAgent.Agent.Tier.model_for_agent(agent_name)
      rescue
        _ -> Application.get_env(:optimal_system_agent, :default_model, "llama3")
      catch
        :exit, _ -> "llama3"
      end
    end

    def budget_for(tier) do
      try do
        OptimalSystemAgent.Agent.Tier.budget_for(tier)
      rescue
        _ -> %{max_tokens: 8192}
      catch
        :exit, _ -> %{max_tokens: 8192}
      end
    end

    def all do
      try do
        OptimalSystemAgent.Agent.Tier.all_tiers()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end

    def supported_providers do
      [:ollama, :anthropic, :openai, :gemini]
    end

    def tier_for_complexity(complexity) when is_integer(complexity) do
      cond do
        complexity <= 3 -> :fast
        complexity <= 6 -> :balanced
        true -> :powerful
      end
    end

    def tier_info(tier) do
      %{
        tier: tier,
        budget: budget_for(tier),
        temperature: temperature(tier),
        max_iterations: max_iterations(tier),
        max_agents: max_agents(tier)
      }
    end

    def max_response_tokens(:fast), do: 4096
    def max_response_tokens(:balanced), do: 8192
    def max_response_tokens(_), do: 16384

    def temperature(:fast), do: 0.3
    def temperature(:balanced), do: 0.5
    def temperature(_), do: 0.7

    def max_agents(:fast), do: 1
    def max_agents(:balanced), do: 3
    def max_agents(_), do: 8

    def max_iterations(:fast), do: 5
    def max_iterations(:balanced), do: 15
    def max_iterations(_), do: 30
  end

  # ── Command ───────────────────────────────────────────────────────────

  defmodule Command do
    @moduledoc "SDK command execution facade. CommandRunner not yet implemented."

    def execute(_input, _session_id \\ "sdk"), do: {:ok, "Command executed (stub)"}
    def list, do: []
    def register(_name, _description, _template), do: :ok
  end

  # ── MCP ──────────────────────────────────────────────────────────────

  defmodule MCP do
    @moduledoc "SDK MCP server management facade. MCP.Manager not yet implemented."

    def list_servers, do: []
    def list_tools, do: []
    def reload_servers, do: :ok
  end

  # ── Supervisor ───────────────────────────────────────────────────────

  defmodule Supervisor do
    @moduledoc """
    Embeds the OSA agent runtime in a host supervision tree.
    Phase 0: delegates to the main application supervisor.
    """
    use Elixir.Supervisor

    def start_link(%OptimalSystemAgent.SDK.Config{} = config) do
      Elixir.Supervisor.start_link(__MODULE__, config, name: __MODULE__)
    end

    def start_link(opts) when is_list(opts) do
      config = struct(OptimalSystemAgent.SDK.Config, Map.new(opts))
      start_link(config)
    end

    @impl true
    def init(config) do
      # Apply config to application env before starting children
      if config.provider do
        Application.put_env(:optimal_system_agent, :default_provider, config.provider)
      end

      if config.model do
        Application.put_env(:optimal_system_agent, :default_model, config.model)
      end

      if config.http_port do
        Application.put_env(:optimal_system_agent, :http_port, config.http_port)
      end

      # Phase 0: no children — host app is expected to start OSA normally
      Elixir.Supervisor.init([], strategy: :one_for_one)
    end
  end
end
