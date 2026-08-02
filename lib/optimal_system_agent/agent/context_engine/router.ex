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

  @doc "The reserved built-in engine ids. Plugins may not claim these."
  @spec builtin_names() :: [atom()]
  def builtin_names, do: Map.keys(@builtins)

  @doc """
  Register a plugin engine at boot.

  Refuses ids that are already claimed by a built-in engine. A plugin that
  registered as `:compactor` would otherwise silently take over the default
  context engine for the whole agent, so the collision is rejected and logged
  rather than merged.
  """
  @spec register(atom(), module()) :: :ok | {:error, {:builtin_conflict, atom()}}
  def register(name, mod) when is_atom(name) and is_atom(mod) do
    cond do
      Map.has_key?(@builtins, name) ->
        Logger.warning(
          "ContextEngine.Router: refused plugin engine #{inspect(mod)} — id :#{name} is a " <>
            "built-in engine and cannot be overridden by a plugin"
        )

        {:error, {:builtin_conflict, name}}

      true ->
        existing = plugin_engines()

        unless List.keymember?(existing, name, 0) do
          :persistent_term.put({__MODULE__, :plugin_engines}, [{name, mod} | existing])
        end

        :ok
    end
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
    # Built-ins win. `Map.merge(@builtins, plugins)` had the plugin side as the
    # override, so a plugin registering `:compactor` silently replaced the
    # default context engine. Registration already refuses built-in ids; this is
    # the second line of defence for anything that got in another way.
    all = Map.merge(Map.new(plugin_engines()), @builtins)

    case Map.fetch(all, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_engine, name}}
    end
  end

  # --- Delegation ---

  @doc """
  Delegate `maybe_compact/4` to the active engine.

  `opts` is forwarded VERBATIM. It carries `:context_window` (the honest
  per-model window) and `:force` (the provider already returned a
  context-length error), and dropping either is not a cosmetic loss: without
  `:context_window` an engine falls back to a fabricated denominator and
  compacts a 1M-token session at ~11% occupancy; without `:force` the
  overflow-retry path cannot compact at all when the window is unresolvable.
  A router that swallowed `opts` would silently reintroduce both.
  """
  def maybe_compact(messages, known_tokens \\ nil, session_id \\ nil, opts \\ []) do
    ContextEngine.Router.active().maybe_compact(messages, known_tokens, session_id, opts)
  end

  @doc "Delegate `estimate_tokens/1` to the active engine."
  def estimate_tokens(input) do
    ContextEngine.Router.active().estimate_tokens(input)
  end

  @doc """
  Delegate `utilization_percent/2` to the active engine (optional).

  Returns a PERCENT in 0.0..100.0, or `:unknown` when the window cannot be
  resolved — including when the engine does not implement the callback. It
  never invents a denominator to produce a number.
  """
  @spec utilization_percent([map()], term()) :: float() | :unknown
  def utilization_percent(messages, context_window \\ nil) do
    mod = ContextEngine.Router.active()

    if function_exported?(mod, :utilization_percent, 2) do
      mod.utilization_percent(messages, context_window)
    else
      :unknown
    end
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
  @spec format_for_summary([map()]) :: String.t()
  def format_for_summary(messages) do
    mod = ContextEngine.Router.active()

    if function_exported?(mod, :format_for_summary, 1) do
      mod.format_for_summary(messages)
    else
      # The callback returns a flattened text blob, not a message list. Falling
      # back to `messages` here would hand a list to callers that interpolate
      # the result into a summarization prompt, so render a plain transcript.
      Enum.map_join(messages, "\n", fn msg ->
        "[#{Map.get(msg, :role, "unknown")}] #{Map.get(msg, :content, "")}"
      end)
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
