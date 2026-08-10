defmodule OptimalSystemAgent.Agent.ContextEngine.Router do
  @moduledoc """
  Routes context-compaction calls to the configured engine.

  Mirrors `Sandbox.Router` selection precedence:

  1. Explicit `:context_engine_module` in application env (a module atom).
  2. `:context_engine` in application env (a short atom, resolved via the
     built-in registry below).
  3. `[context].engine` in `~/.osa/config.toml` (a short atom, resolved
     via the built-in registry below).
  4. Default: `OptimalSystemAgent.Agent.Compactor`.

  ## Usage

  Call sites should use `ContextEngine.Router.maybe_compact/3` etc. instead
  of calling `Compactor` directly. This lets operators swap the engine via
  config without touching code.

      ContextEngine.Router.maybe_compact(messages, tokens, session_id)
      ContextEngine.Router.estimate_tokens(messages)
      ContextEngine.Router.utilization(messages)
      ContextEngine.Router.micro_compact(messages)
      ContextEngine.Router.format_for_summary(messages)
      ContextEngine.Router.stats()
      ContextEngine.Router.active()

  ## Built-in engines

  | Atom       | Module                                  |
  |------------|-----------------------------------------|
  | `:compactor` | `OptimalSystemAgent.Agent.Compactor` |
  | `:noop`       | `OptimalSystemAgent.Agent.ContextEngine.Noop` |

  Third-party engines registered via the Plugin Loader get added to the
  registry at boot.
  """

  require Logger

  alias OptimalSystemAgent.Agent.ContextEngine

  @builtins %{
    compactor: OptimalSystemAgent.Agent.Compactor,
    noop: OptimalSystemAgent.Agent.ContextEngine.Noop
  }

  @doc "Get the currently configured engine module."
  @spec active() :: module()
  def active do
    case resolve_module() do
      {:ok, mod} ->
        mod

      {:error, reason} ->
        Logger.warning(
          "ContextEngine.Router: failed to resolve engine (#{inspect(reason)}), falling back to Compactor"
        )

        OptimalSystemAgent.Agent.Compactor
    end
  end

  @doc "List all known engine atoms and their modules."
  @spec engines() :: [{atom(), module()}]
  def engines do
    Map.to_list(@builtins) ++ plugin_engines()
  end

  @doc "Register a plugin engine at boot."
  @spec register(atom(), module()) :: :ok
  def register(name, mod) when is_atom(name) and is_atom(mod) do
    existing = plugin_engines()

    unless List.keymember?(existing, name, 0) do
      :persistent_term.put({__MODULE__, :plugin_engines}, [{name, mod} | existing])
    end

    :ok
  end

  defp plugin_engines do
    :persistent_term.get({__MODULE__, :plugin_engines}, [])
  end

  # --- Resolution ---

  defp resolve_module do
    # 1. Direct module override
    case Application.fetch_env(:optimal_system_agent, :context_engine_module) do
      {:ok, mod} when is_atom(mod) ->
        {:ok, mod}

      _ ->
        resolve_by_atom()
    end
  end

  defp resolve_by_atom do
    # 2. Short atom in app env
    case Application.fetch_env(:optimal_system_agent, :context_engine) do
      {:ok, name} when is_atom(name) ->
        lookup(name)

      _ ->
        # 3. config.toml [context].engine
        case toml_context_engine() do
          {:ok, name} when is_atom(name) -> lookup(name)
          _ -> {:ok, OptimalSystemAgent.Agent.Compactor}
        end
    end
  end

  defp toml_context_engine do
    try do
      case OptimalSystemAgent.ConfigFile.get(["context", "engine"]) do
        name when is_binary(name) and name != "" -> {:ok, String.to_atom(name)}
        _ -> :none
      end
    rescue
      _ -> :none
    end
  end

  defp lookup(name) do
    all = Map.merge(@builtins, Map.new(plugin_engines()))

    case Map.fetch(all, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_engine, name}}
    end
  end

  # --- Delegation ---

  @doc "Delegate `maybe_compact/3` to the active engine."
  def maybe_compact(messages, known_tokens \\ 0, session_id \\ nil) do
    ContextEngine.Router.active().maybe_compact(messages, known_tokens, session_id)
  end

  @doc "Delegate `estimate_tokens/1` to the active engine."
  def estimate_tokens(input) do
    ContextEngine.Router.active().estimate_tokens(input)
  end

  @doc "Delegate `utilization/1` to the active engine."
  def utilization(messages) do
    ContextEngine.Router.active().utilization(messages)
  end

  @doc "Delegate `micro_compact/1` to the active engine (optional)."
  def micro_compact(messages) do
    mod = ContextEngine.Router.active()

    if function_exported?(mod, :micro_compact, 1) do
      mod.micro_compact(messages)
    else
      messages
    end
  end

  @doc "Delegate `format_for_summary/1` to the active engine (optional)."
  def format_for_summary(messages) do
    mod = ContextEngine.Router.active()

    if function_exported?(mod, :format_for_summary, 1) do
      mod.format_for_summary(messages)
    else
      messages
    end
  end

  @doc "Delegate `stats/0` to the active engine (optional)."
  def stats do
    mod = ContextEngine.Router.active()

    if function_exported?(mod, :stats, 0) do
      mod.stats()
    else
      %{}
    end
  end

  @doc "Start the engine's GenServer if it exports `start_link/1`."
  @spec maybe_start_engine(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  def maybe_start_engine(opts \\ []) do
    mod = ContextEngine.Router.active()

    if function_exported?(mod, :start_link, 1) do
      mod.start_link(opts)
    else
      :ignore
    end
  end
end
