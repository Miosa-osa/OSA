defmodule OptimalSystemAgent.Tools.Registry do
  @moduledoc """
  Tool and skill registry — manages callable tools (Elixir modules) and discovers SKILL.md skill files.

  Tools/skills can be registered in three ways:
  1. Built-in tools (implement Tools.Behaviour)
  2. SKILL.md files from ~/.osa/skills/ (markdown-defined, parsed at boot)
  3. MCP server tools (auto-discovered from ~/.osa/mcp.json)

  Tool execution resolves through the in-memory `builtin_tools` map — see
  `handle_call({:execute, ...})`.

  ## Hot Code Reload
  When a new tool is registered via `register/1` it becomes available
  immediately — the registry's map and the `:persistent_term` snapshots are
  updated synchronously.

  ## Sub-modules
    - Registry.SkillLoader — loads/parses SKILL.md from priv/skills/ and ~/.osa/skills/
    - Registry.Search      — keyword search, applicability scoring, fallback suggestion
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Registry.{Search, SkillLoader, SkillTouch, SkillUsage}

  defstruct builtin_tools: %{}, skills: %{}, tools: []

  @max_triggered_skill_chars 4_000
  @max_triggered_total_chars 12_000

  # ── GenServer Start ──────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Register a tool module implementing Tools.Behaviour.

  `timeout` stays generous: a timeout here is an `exit`, not an error return,
  so it takes down whatever was registering rather than failing that one tool,
  and the registry is a singleton that other boot work queues behind.
  """
  def register(skill_module, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:register_module, skill_module}, timeout)
  end

  # Tools that stay REGISTERED and callable (internal orchestration uses them,
  # and `tool_search` can still surface them mid-turn) but are hidden from the
  # model's DEFAULT toolbox — they are harness/orchestration infrastructure,
  # UI/user actions, or redundant with a kept tool, NOT things the agent should
  # reach for on its own. Keeping the default set lean (CC-style) makes the model
  # sharper, not weaker. See list_active/0 + the :list_tools handler.
  @model_hidden MapSet.new(~w(
    team_create team_delete team_tasks
    peer_review peer_claim_region peer_negotiate_task cross_team_query
    list_agents create_agent message_agent spawn_conversation
    enter_worktree exit_worktree monitor verify_loop remote_trigger
    config session_search subscribe_pr send_user_file brief progress_note budget_status
    orchestrate knowledge create_skill list_skills save_skill find_skill
  ))

  @doc "Names hidden from the model's default toolbox (still callable internally)."
  def model_hidden, do: @model_hidden

  @doc "List all available tools (for LLM function calling), minus model-hidden."
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
    |> Enum.reject(&MapSet.member?(@model_hidden, &1.name))
  end

  @doc "List only non-deferred tools (for system prompt injection). Reduces prompt size."
  def list_active do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

    list_tools_direct()
    |> Enum.reject(fn tool ->
      cond do
        # Harness/UI/redundant tools: registered + searchable, but never in the
        # model's default toolbox.
        MapSet.member?(@model_hidden, tool.name) ->
          true

        # Built-in tool declaring itself deferred.
        (mod = Map.get(builtin_tools, tool.name)) != nil ->
          function_exported?(mod, :deferred?, 0) and mod.deferred?()

        # MCP tool marked should_defer? — CRITICAL: keep these out of the base
        # prompt so MCP tools don't flood the system prompt. They stay
        # discoverable mid-turn via `tool_search`.
        (info = Map.get(mcp_tools, tool.name)) != nil ->
          Map.get(info, :should_defer?, false)

        true ->
          false
      end
    end)
  end

  @doc """
  The live MCP catalog: `%{server_name => [%{name: prefixed, tool: original, description: desc}]}`.

  Reads the aggregate `mcp_tools` map published by `MCP.Client.Manager` and
  groups it back by originating server. This is what makes MCP servers
  *nameable* by the model: without it, a deferred MCP toolset leaves no trace
  anywhere in the prompt and the agent has no evidence a server exists.

  Entries are sorted by tool name within each server for a stable prompt.
  """
  @spec mcp_catalog() :: %{String.t() => [map()]}
  def mcp_catalog do
    :persistent_term.get({__MODULE__, :mcp_tools}, %{})
    |> Enum.map(fn {prefixed, info} ->
      server =
        case OptimalSystemAgent.MCP.Client.ToolBridge.parse_key(prefixed) do
          {:ok, {server, _tool}} -> server
          :error -> "unknown"
        end

      {server,
       %{
         name: prefixed,
         tool: Map.get(info, :original_name, prefixed),
         description: Map.get(info, :description, ""),
         deferred?: Map.get(info, :should_defer?, false)
       }}
    end)
    |> Enum.group_by(fn {server, _} -> server end, fn {_, entry} -> entry end)
    |> Map.new(fn {server, entries} -> {server, Enum.sort_by(entries, & &1.name)} end)
  rescue
    _ -> %{}
  end

  @doc """
  Names of MCP servers that currently contribute at least one tool.
  """
  @spec mcp_servers() :: [String.t()]
  def mcp_servers, do: mcp_catalog() |> Map.keys() |> Enum.sort()

  @doc """
  Every MCP tool belonging to `server`, or `[]` when the server is unknown.

  Used by `tool_search`'s `server:<name>` form so an agent can enumerate a
  server's whole toolset instead of guessing keywords against a top-N cutoff.
  """
  @spec mcp_tools_for_server(String.t()) :: [map()]
  def mcp_tools_for_server(server) when is_binary(server) do
    mcp_catalog() |> Map.get(server, [])
  end

  @doc "Search all tools (including deferred) by keyword match on name and description."
  def search(query, opts) do
    limit = Keyword.get(opts, :limit, 5)
    query_down = String.downcase(query)
    keywords = String.split(query_down, ~r/\s+/)

    list_tools_direct()
    |> Enum.map(fn tool ->
      name_down = String.downcase(tool.name)
      name_score = if String.contains?(name_down, query_down), do: 2.0, else: 0.0
      desc_down = String.downcase(tool.description)

      keyword_score =
        Enum.reduce(keywords, 0.0, fn kw, acc ->
          cond do
            # `name_down`, not `tool.name`: `kw` is already downcased, so
            # comparing it against the RAW name silently missed every tool with
            # an uppercase character in its name — including most MCP tools,
            # whose names are server-supplied.
            String.contains?(name_down, kw) -> acc + 1.5
            String.contains?(desc_down, kw) -> acc + 1.0
            true -> acc
          end
        end)

      jaro_score = String.jaro_distance(query_down, String.downcase(tool.name))

      {tool, name_score + keyword_score + jaro_score}
    end)
    |> Enum.filter(fn {_tool, score} -> score > 0.5 end)
    |> Enum.sort_by(fn {_tool, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {tool, _score} -> tool end)
  end

  @doc """
  List all available tools without going through the GenServer.

  Uses :persistent_term for lock-free reads. Safe to call from inside
  GenServer callbacks (e.g., during orchestration) without deadlocking.

  ## Ordering is part of the prompt-cache contract

  The returned list becomes the provider `tools` array, which Anthropic renders
  FIRST in the request — ahead of `system` and `messages`. Prompt caching is a
  prefix match, so the byte order of this list determines whether the entire
  ~48k-token static prefix is a cache read or a cache write.

  Both sources here are maps, and Erlang leaves map iteration order
  unspecified: it is a function of the key set and the runtime's internal
  hashing, not of insertion order, and it carries no stability guarantee across
  OTP versions. Two nodes, or the same node before and after an upgrade, could
  therefore emit the same tools in a different order and miss the cache for the
  whole prefix with nothing in the diff to explain why.

  Sorting by name makes the order a pure function of the tool NAMES, which is
  the only property that is actually stable. Builtins are sorted independently
  of MCP tools and kept ahead of them, so a connecting MCP server appends to the
  tail instead of interleaving into — and rewriting — the builtin prefix.
  """
  def list_tools_direct do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    builtin =
      builtin_tools
      |> Enum.filter(fn {_name, mod} -> tool_available?(mod) end)
      |> Enum.map(fn {_name, mod} ->
        %{
          name: mod.name(),
          description: mod.description(),
          parameters: mod.parameters()
        }
      end)
      |> Enum.sort_by(& &1.name)

    mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

    mcp =
      Enum.map(mcp_tools, fn {prefixed_name, info} ->
        %{
          name: prefixed_name,
          description: Map.get(info, :description, "MCP tool: #{info.original_name}"),
          parameters: Map.get(info, :input_schema, %{"type" => "object", "properties" => %{}})
        }
      end)
      |> Enum.sort_by(& &1.name)

    builtin ++ mcp
  end

  @doc """
  Execute a tool by name without going through the GenServer.

  Uses :persistent_term for tool lookup. Safe to call from inside GenServer
  callbacks or sub-agent Tasks during orchestration — prevents deadlock.

  MCP tools (prefixed `mcp_`) are routed to MCP.Client.call_tool/2.
  """
  def execute_direct(tool_name, arguments) do
    case circuit_breaker(tool_name, arguments) do
      {:blocked, reason} ->
        {:error, circuit_breaker_message(tool_name, reason)}

      :ok ->
        execute_direct_unguarded(tool_name, arguments)
    end
  end

  defp execute_direct_unguarded(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil ->
        mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

        case Map.get(mcp_tools, tool_name) do
          nil ->
            {:error, "Unknown tool: #{tool_name}"}

          _mcp_info ->
            with :ok <- action_authority_result(tool_name, arguments) do
              OptimalSystemAgent.MCP.Client.ToolBridge.call(tool_name, arguments)
            end
        end

      mod ->
        with :ok <- validate_arguments(mod, arguments),
             :ok <- action_authority_result(tool_name, arguments) do
          mod.execute(arguments)
        end
    end
  end

  @doc """
  Execute a tool by name with given arguments.

  Runs directly in the caller's process (no GenServer serialization) using
  :persistent_term for module lookup.
  """
  def execute(tool_name, arguments) do
    case circuit_breaker(tool_name, arguments) do
      {:blocked, reason} ->
        # Authoritative enforcement point. Every non-loop caller (MCP server
        # dispatcher, Tools.Pipeline, HTTP tool routes, sub-agent Tasks) reaches
        # tool execution through here, so the hard circuit-breaker cannot be
        # bypassed by skipping the agent loop.
        {:error, circuit_breaker_message(tool_name, reason)}

      :ok ->
        execute_unguarded(tool_name, arguments)
    end
  end

  # Hard, tier-independent circuit-breaker enforced at the tool-execution
  # MECHANISM (this module) so every caller — the agent loop, the MCP server
  # dispatcher, Tools.Pipeline, the cron scheduler, and sub-agent Tasks — is
  # covered. It cannot be bypassed by skipping the agent loop.
  defp circuit_breaker(tool_name, arguments) do
    OptimalSystemAgent.Agent.Safety.DangerousCommands.blocked?(%{
      name: tool_name,
      arguments: arguments
    })
  end

  defp circuit_breaker_message(tool_name, reason) do
    "Blocked by a hard safety limit (#{tool_name}): #{reason}. " <>
      "This action is never permitted, in any permission tier."
  end

  defp action_authority_result(tool_name, arguments) do
    case OptimalSystemAgent.ActionAuthority.authorize_tool(tool_name, arguments) do
      :not_governed -> :ok
      {:allow, _receipt} -> :ok
      {:blocked, message} -> {:error, "Blocked: " <> message}
    end
  end

  defp execute_unguarded(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil ->
        mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

        case Map.get(mcp_tools, tool_name) do
          nil ->
            {:error, "Unknown tool: #{tool_name}"}

          _mcp_info ->
            with :ok <- action_authority_result(tool_name, arguments) do
              OptimalSystemAgent.MCP.Client.ToolBridge.call(tool_name, arguments)
            end
        end

      mod ->
        with :ok <- validate_arguments(mod, arguments),
             :ok <- action_authority_result(tool_name, arguments) do
          dispatch(mod, arguments)
        end
    end
  rescue
    e ->
      {:error, "Tool execution error: #{Exception.message(e)}"}
  end

  # Routes a tool call through the appropriate execution path. Structured
  # tools (those exporting `execute/2`) go through `LegacyAdapter.execute/3`,
  # which runs the full `validate_input → check_permissions → execute`
  # pipeline with a `UseContext` built from the tool arguments. Flat tools
  # (only `execute/1`) call directly.
  defp dispatch(mod, arguments) do
    if OptimalSystemAgent.Tools.LegacyAdapter.structured?(mod) do
      ctx = build_minimal_use_context(arguments)
      OptimalSystemAgent.Tools.LegacyAdapter.execute(mod, arguments, ctx)
    else
      mod.execute(arguments)
    end
  end

  # Builds a minimal `UseContext` from injected tool arguments. The agent
  # loop's `ToolExecutor.execute_tool_call/2` injects `__session_id__` into
  # every call (see `tool_executor.ex:113`); this carries through to the
  # context so structured tools can identify the session without the agent
  # loop having to thread an explicit context through every callsite.
  # `tool_use_id` is per-call identity injected alongside `__session_id__`. It
  # carries the owning tool_call id so a streaming tool (shell_execute) can tag
  # its live-output deltas and the TUI can route them to the right cell even
  # when several identical commands run concurrently.
  defp build_minimal_use_context(arguments) do
    OptimalSystemAgent.Tools.UseContext.new(
      %{session_id: arguments["__session_id__"] || arguments[:__session_id__]},
      tool_use_id: arguments["__tool_use_id__"] || arguments[:__tool_use_id__]
    )
  end

  @doc """
  Look up the builtin tool module backing `tool_name`.

  Returns the module (a structured or flat tool) or `nil` when the name is not a
  builtin — e.g. MCP tools or an unknown/aliased name. Lock-free read via
  `:persistent_term`, safe to call from sub-agent Tasks and the agent loop.
  """
  @spec module_for(String.t()) :: module() | nil
  def module_for(tool_name) do
    :persistent_term.get({__MODULE__, :builtin_tools}, %{}) |> Map.get(tool_name)
  end

  @doc """
  Validate tool arguments against the module's JSON Schema (from `parameters/0`).

  Returns `:ok` when arguments conform to the schema, or
  `{:error, message}` with a structured description of all validation failures.

  If validation infrastructure is unavailable or crashes, read-only tools remain
  fail-open for compatibility. Mutating or unknown-safety tools fail closed.
  """
  @spec validate_arguments(module(), map()) :: :ok | {:error, String.t()}
  def validate_arguments(mod, arguments) do
    unless Code.ensure_loaded?(ExJsonSchema.Schema) and
             Code.ensure_loaded?(ExJsonSchema.Validator) do
      validation_infra_error_result(mod, arguments, :ex_json_schema_unavailable)
    else
      try do
        schema = mod.parameters()
        resolved = apply(ExJsonSchema.Schema, :resolve, [schema])

        case apply(ExJsonSchema.Validator, :validate, [resolved, arguments]) do
          :ok ->
            :ok

          {:error, errors} ->
            message = format_validation_errors(mod.name(), errors)
            {:error, message}
        end
      rescue
        e ->
          Logger.warning(
            "[Tools.Registry] Schema validation error for #{safe_tool_name(mod)}: #{inspect(e)}"
          )

          validation_infra_error_result(mod, arguments, e)
      end
    end
  end

  @doc """
  Discover MCP tools from all running servers and register them.

  Delegates to `MCP.Client.Manager.reload/0`, which re-reads `~/.osa/mcp.json`,
  reconciles running server sessions, and republishes the aggregate
  `mcp_tools` map into `:persistent_term` under this module's key.
  """
  def register_mcp_tools do
    OptimalSystemAgent.MCP.Client.Manager.reload()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "List tool and skill documentation (for context injection)."
  def list_docs do
    GenServer.call(__MODULE__, :list_docs)
  end

  @doc """
  List tool and skill documentation without going through the GenServer.

  Uses :persistent_term for lock-free reads.
  """
  def list_docs_direct do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    skills = :persistent_term.get({__MODULE__, :skills}, %{})
    tool_docs = Enum.map(builtin_tools, fn {name, mod} -> {name, mod.description()} end)
    skill_docs = Enum.map(skills, fn {name, skill} -> {name, skill.description} end)
    tool_docs ++ skill_docs
  end

  @doc "Reload skills from disk (~/.osa/skills/)."
  def reload_skills do
    GenServer.call(__MODULE__, :reload_skills)
  end

  @doc """
  Returns a formatted string of all active custom skills for prompt injection.

  Used by Context.build to inform the LLM about available custom skills.
  Returns nil if no custom skills are loaded.
  """
  @spec active_skills_context() :: String.t() | nil
  def active_skills_context do
    skills = :persistent_term.get({__MODULE__, :skills}, %{})

    if map_size(skills) == 0 do
      nil
    else
      # Progressive disclosure: skills declaring `paths:` globs stay hidden from
      # the model-facing listing until a matching file is touched this session.
      touched = touched_paths()

      active =
        skills
        |> SkillLoader.list_for_model(touched)
        |> SkillLoader.reject_disabled()

      if active == [] do
        nil
      else
        lines =
          Enum.map_join(active, "\n", fn skill ->
            "- **#{skill.name}**: #{skill.description}"
          end)

        "## Custom Skills\n\nThe following skills are available:\n#{lines}"
      end
    end
  rescue
    _ -> nil
  end

  @doc """
  Same as `active_skills_context/0` but also injects the full workflow instructions
  for any skills whose trigger keywords match the given message.
  """
  @spec active_skills_context(String.t() | nil) :: String.t() | nil
  def active_skills_context(nil), do: active_skills_context()
  def active_skills_context(""), do: active_skills_context()

  def active_skills_context(message) when is_binary(message) do
    base = active_skills_context()
    matched = match_skill_triggers(message)

    if matched != [] do
      skill_names = Enum.map(matched, fn {name, _} -> name end)

      Enum.each(skill_names, &SkillUsage.record_use/1)

      try do
        OptimalSystemAgent.Events.Bus.emit(:system_event, %{
          event: :skills_triggered,
          skills: skill_names,
          message_preview: String.slice(message, 0, 120)
        })
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    {injected_parts, _budget_used} =
      matched
      |> Enum.sort_by(fn {_name, skill} -> Map.get(skill, :priority, 5) end)
      |> Enum.reduce({[], 0}, fn {_name, skill}, {acc, used} ->
        remaining = @max_triggered_total_chars - used

        if remaining <= 0 do
          {acc, used}
        else
          # Progressive disclosure: the listing carries no body, so load the
          # instruction body on demand only for skills whose triggers matched.
          inst =
            case SkillLoader.load_body(skill[:path]) do
              {:ok, body} -> String.trim(body)
              _ -> skill[:instructions] |> to_string() |> String.trim()
            end

          if inst == "" do
            {acc, used}
          else
            capped =
              if String.length(inst) > @max_triggered_skill_chars do
                String.slice(inst, 0, @max_triggered_skill_chars) <>
                  "\n\n[Truncated — call `use_skill` with name \"#{skill.name}\" for full instructions]"
              else
                inst
              end

            capped =
              if String.length(capped) > remaining do
                String.slice(capped, 0, remaining) <>
                  "\n\n[Truncated — call `use_skill` with name \"#{skill.name}\" for full instructions]"
              else
                capped
              end

            {acc ++ ["### Active Skill: #{skill.name}\n\n#{capped}"],
             used + String.length(capped)}
          end
        end
      end)

    injected = Enum.join(injected_parts, "\n\n")

    cond do
      is_nil(base) and injected == "" -> nil
      is_nil(base) -> injected
      injected == "" -> base
      true -> base <> "\n\n" <> injected
    end
  rescue
    _ -> active_skills_context()
  end

  @doc """
  Match a message against all loaded skill trigger keywords.

  Returns a list of `{name, skill}` pairs whose trigger keywords appear
  anywhere in the (case-insensitive) message text.
  Skips skills with a wildcard trigger `"*"`.
  """
  @spec match_skill_triggers(String.t()) :: [{String.t(), map()}]
  def match_skill_triggers(message) when is_binary(message) do
    skills = :persistent_term.get({__MODULE__, :skills}, %{})
    message_lower = String.downcase(message)
    touched = touched_paths()

    Enum.filter(skills, fn {_name, skill} ->
      # This path INJECTS THE FULL INSTRUCTION BODY into the prompt, so it must
      # honour exactly the gates the listing honours — it used to honour
      # neither. A `.disabled` skill had its whole body shipped to the provider
      # on a trigger word, and a `paths:`-gated skill leaked before any matching
      # file was touched, defeating the withholding control outright.
      not SkillLoader.disabled?(skill) and
        SkillLoader.surfaced?(skill, touched) and
        trigger_match?(skill, message_lower)
    end)
  rescue
    _ -> []
  end

  def match_skill_triggers(_), do: []

  defp trigger_match?(skill, message_lower) do
    skill
    |> Map.get(:triggers, [])
    |> List.wrap()
    |> Enum.any?(fn t ->
      t = to_string(t)
      t != "*" and t != "" and String.contains?(message_lower, String.downcase(t))
    end)
  end

  defp touched_paths do
    case Process.get(:osa_session_id) do
      nil -> []
      session_id -> SkillTouch.list(session_id)
    end
  rescue
    _ -> []
  end

  @doc "Search existing tools and skills by keyword matching against names and descriptions."
  @spec search(String.t()) :: list({String.t(), String.t(), float()})
  def search(query) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    skills = :persistent_term.get({__MODULE__, :skills}, %{})
    Search.search(builtin_tools, skills, query)
  end

  @doc "Return a single skill map by name, or nil if not found."
  @spec get_skill(String.t()) :: map() | nil
  def get_skill(name) do
    :persistent_term.get({__MODULE__, :skills}, %{}) |> Map.get(name)
  end

  @doc """
  Record a filesystem path touched this session for `paths`-glob skill surfacing.

  Integration hook: call this whenever a file tool touches a path so that skills
  gated behind `paths:` globs can surface in the model-facing listing. Delegates
  to the session-scoped `SkillTouch` tracker.
  """
  @spec record_touched_path(term(), String.t()) :: :ok
  def record_touched_path(session_id, path) do
    SkillTouch.record(session_id, path)
  end

  @doc """
  Load a skill's instruction body on demand (progressive disclosure).

  The listing built by `load_skills/1` never carries bodies; use this when a
  skill is actually invoked. Accepts a skill name or a full entry map.
  """
  @spec load_skill_body(String.t() | map()) :: {:ok, String.t()} | {:error, term()}
  def load_skill_body(name) when is_binary(name) do
    case get_skill(name) do
      %{path: path} -> SkillLoader.load_body(path)
      _ -> {:error, :not_found}
    end
  end

  def load_skill_body(%{path: _} = entry), do: SkillLoader.load_body(entry.path)
  def load_skill_body(_), do: {:error, :no_path}

  @doc "Return all loaded skills as a list."
  @spec list_skills() :: [map()]
  def list_skills do
    :persistent_term.get({__MODULE__, :skills}, %{})
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Filter the full tool list to only tools relevant to the current session context.

  `context` keys: `:language`, `:framework`, `:history`.
  Returns tools in relevance order.
  """
  @spec filter_applicable_tools(map()) :: [map()]
  def filter_applicable_tools(context \\ %{}) do
    # Phase 3a: route through `list_active/0` so tools with
    # `should_defer?/0 == true` (or flat-layout `deferred?/0 == true`)
    # are excluded from the initial system prompt. Deferred tools are
    # discoverable mid-turn via the `tool_search` tool, which loads
    # their full schemas on demand. Mirrors the lazy-loading pattern at
    # upstream in the upstream contract.
    Search.filter_applicable_tools(context, list_active())
  end

  @doc """
  Suggest an alternative tool when `failed_tool` fails.

  Returns `{:ok, alternative_tool_name}` or `:no_alternative`.
  """
  @spec suggest_fallback_tool(String.t()) :: {:ok, String.t()} | :no_alternative
  def suggest_fallback_tool(failed_tool) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    Search.suggest_fallback(failed_tool, builtin_tools)
  end

  @doc "Load all skill definitions from priv/skills/. Delegates to SkillLoader."
  @spec load_skill_definitions() :: [map()]
  def load_skill_definitions do
    SkillLoader.load_skill_definitions()
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────

  @impl true
  def init(:ok) do
    builtin_tools = load_builtin_tools()
    skills = SkillLoader.load_skills()
    tools = build_tool_list(builtin_tools, skills)

    :persistent_term.put({__MODULE__, :builtin_tools}, builtin_tools)
    :persistent_term.put({__MODULE__, :skills}, skills)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info(
      "Tools registry: #{map_size(builtin_tools)} tools, #{map_size(skills)} skills, #{length(tools)} LLM tools"
    )

    SkillUsage.init()

    # Own the touched-path table on the long-lived Registry process so
    # `paths`-glob lazy surfacing state survives for the life of the node.
    SkillTouch.ensure_table()

    {:ok, %__MODULE__{builtin_tools: builtin_tools, skills: skills, tools: tools}}
  end

  @impl true
  def handle_call({:register_module, skill_module}, _from, state) do
    name = skill_module.name()
    builtin_tools = Map.put(state.builtin_tools, name, skill_module)
    tools = build_tool_list(builtin_tools, state.skills)

    :persistent_term.put({__MODULE__, :builtin_tools}, builtin_tools)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info("Registered tool: #{name} (hot reload)")
    {:reply, :ok, %{state | builtin_tools: builtin_tools, tools: tools}}
  end

  def handle_call(:list_tools, _from, state) do
    mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

    mcp =
      Enum.map(mcp_tools, fn {prefixed_name, info} ->
        %{
          name: prefixed_name,
          description: Map.get(info, :description, "MCP tool: #{info.original_name}"),
          parameters: Map.get(info, :input_schema, %{"type" => "object", "properties" => %{}})
        }
      end)

    {:reply, state.tools ++ mcp, state}
  end

  def handle_call(:reload_skills, _from, state) do
    skills = SkillLoader.load_skills()
    tools = build_tool_list(state.builtin_tools, skills)

    :persistent_term.put({__MODULE__, :skills}, skills)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info("Tools registry reloaded: #{map_size(skills)} skills")
    {:reply, :ok, %{state | skills: skills, tools: tools}}
  end

  def handle_call(:list_docs, _from, state) do
    tool_docs = Enum.map(state.builtin_tools, fn {name, mod} -> {name, mod.description()} end)
    skill_docs = Enum.map(state.skills, fn {name, skill} -> {name, skill.description} end)
    {:reply, tool_docs ++ skill_docs, state}
  end

  def handle_call({:search, query}, _from, state) do
    results = Search.search(state.builtin_tools, state.skills, query)
    {:reply, results, state}
  end

  def handle_call({:execute, tool_name, arguments}, _from, state) do
    result =
      case circuit_breaker(tool_name, arguments) do
        {:blocked, reason} ->
          {:error, circuit_breaker_message(tool_name, reason)}

        :ok ->
          case Map.get(state.builtin_tools, tool_name) do
            nil ->
              mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

              case Map.get(mcp_tools, tool_name) do
                nil -> {:error, "Unknown tool: #{tool_name}"}
                _mcp_info -> OptimalSystemAgent.MCP.Client.ToolBridge.call(tool_name, arguments)
              end

            mod ->
              case validate_arguments(mod, arguments) do
                :ok -> mod.execute(arguments)
                {:error, _reason} = error -> error
              end
          end
      end

    {:reply, result, state}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("Tools.Registry received unexpected call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    try do
      SkillUsage.persist()
    rescue
      _ -> :ok
    end

    :ok
  end

  # ── Private: Built-in Tools ───────────────────────────────────────────

  defp load_builtin_tools do
    %{
      # ── Structured-layout tools (per-tool directory) ───────────────────
      "file_read" => OptimalSystemAgent.Tools.Builtins.FileRead.Tool,
      "file_write" => OptimalSystemAgent.Tools.Builtins.FileWrite.Tool,
      "file_edit" => OptimalSystemAgent.Tools.Builtins.FileEdit.Tool,
      "file_glob" => OptimalSystemAgent.Tools.Builtins.FileGlob.Tool,
      "file_grep" => OptimalSystemAgent.Tools.Builtins.FileGrep.Tool,
      "dir_list" => OptimalSystemAgent.Tools.Builtins.DirList.Tool,
      "shell_execute" => OptimalSystemAgent.Tools.Builtins.ShellExecute.Tool,

      # ── Interactive PTY tools (complement to shell_execute for tty programs) ─
      "pty_start" => OptimalSystemAgent.Tools.Builtins.Pty.PtyStart,
      "pty_send" => OptimalSystemAgent.Tools.Builtins.Pty.PtySend,
      "pty_read" => OptimalSystemAgent.Tools.Builtins.Pty.PtyRead,
      "pty_wait" => OptimalSystemAgent.Tools.Builtins.Pty.PtyWait,
      "pty_stop" => OptimalSystemAgent.Tools.Builtins.Pty.PtyStop,
      "task_write" => OptimalSystemAgent.Tools.Builtins.TaskWrite.Tool,
      "memory_save" => OptimalSystemAgent.Tools.Builtins.MemorySave.Tool,
      "memory_recall" => OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool,
      "git" => OptimalSystemAgent.Tools.Builtins.Git.Tool,
      "web_fetch" => OptimalSystemAgent.Tools.Builtins.WebFetch.Tool,
      "web_search" => OptimalSystemAgent.Tools.Builtins.WebSearch.Tool,
      "tool_search" => OptimalSystemAgent.Tools.Builtins.ToolSearch.Tool,
      "use_tool" => OptimalSystemAgent.Tools.Builtins.UseTool.Tool,
      "cron" => OptimalSystemAgent.Tools.Builtins.Cron.Tool,
      "enter_plan_mode" => OptimalSystemAgent.Tools.Builtins.EnterPlanMode.Tool,
      "exit_plan_mode" => OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Tool,
      "enter_worktree" => OptimalSystemAgent.Tools.Builtins.EnterWorktree.Tool,
      "exit_worktree" => OptimalSystemAgent.Tools.Builtins.ExitWorktree.Tool,
      "notebook_edit" => OptimalSystemAgent.Tools.Builtins.NotebookEdit.Tool,

      # ── New companion tools (Pillar F: scheduling primitives) ──────────
      "sleep" => OptimalSystemAgent.Tools.Builtins.Sleep.Tool,
      "monitor" => OptimalSystemAgent.Tools.Builtins.Monitor.Tool,
      "remote_trigger" => OptimalSystemAgent.Tools.Builtins.RemoteTrigger.Tool,

      # ── Kairos proactive tools ─────────────────────────────────────────
      "brief" => OptimalSystemAgent.Tools.Builtins.Brief.Tool,
      "push_notification" => OptimalSystemAgent.Tools.Builtins.PushNotification.Tool,
      "subscribe_pr" => OptimalSystemAgent.Tools.Builtins.SubscribePr.Tool,
      "send_user_file" => OptimalSystemAgent.Tools.Builtins.SendUserFile.Tool,

      # ── Multi-agent + orchestration ────────────────────────────────────
      "delegate" => OptimalSystemAgent.Tools.Builtins.Delegate.Tool,
      "fleet" => OptimalSystemAgent.Tools.Builtins.Fleet.Tool,
      "list_agents" => OptimalSystemAgent.Tools.Builtins.ListAgents.Tool,
      "create_agent" => OptimalSystemAgent.Tools.Builtins.CreateAgent.Tool,
      "team_tasks" => OptimalSystemAgent.Tools.Builtins.TeamTasks.Tool,
      "scratchpad" => OptimalSystemAgent.Tools.Builtins.Scratchpad.Tool,
      "team_create" => OptimalSystemAgent.Tools.Builtins.TeamCreate.Tool,
      "team_delete" => OptimalSystemAgent.Tools.Builtins.TeamDelete.Tool,
      "message_agent" => OptimalSystemAgent.Tools.Builtins.MessageAgent.Tool,
      "mixture_of_agents" => OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Tool,

      # ── Peer / cross-team coordination ─────────────────────────────────
      "peer_review" => OptimalSystemAgent.Tools.Builtins.PeerReview.Tool,
      "peer_claim_region" => OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Tool,
      "peer_negotiate_task" => OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Tool,
      "cross_team_query" => OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Tool,

      # ── Comms / interaction ────────────────────────────────────────────
      "ask_user" => OptimalSystemAgent.Tools.Builtins.AskUser.Tool,
      "send_message" => OptimalSystemAgent.Tools.Builtins.SendMessage.Tool,
      "config" => OptimalSystemAgent.Tools.Builtins.Config.Tool,

      # ── Task management ────────────────────────────────────────────────
      "task_stop" => OptimalSystemAgent.Tools.Builtins.TaskStop.Tool,
      "task_resume" => OptimalSystemAgent.Tools.Builtins.TaskResume.Tool,
      "task_wait" => OptimalSystemAgent.Tools.Builtins.TaskWait.Tool,
      "task_output" => OptimalSystemAgent.Tools.Builtins.TaskOutput.Tool,
      "bash_output" => OptimalSystemAgent.Tools.Builtins.BashOutput.Tool,
      "session_search" => OptimalSystemAgent.Tools.Builtins.SessionSearch.Tool,
      "progress_note" => OptimalSystemAgent.Tools.Builtins.ProgressNote.Tool,

      # ── Code / utility ─────────────────────────────────────────────────
      "repl" => OptimalSystemAgent.Tools.Builtins.REPL.Tool,
      "code_symbols" => OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool,
      "multi_file_edit" => OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool,
      "download" => OptimalSystemAgent.Tools.Builtins.Download.Tool,

      # ── Filesystem checkpoints ─────────────────────────────────────────
      "rollback" => OptimalSystemAgent.Tools.Builtins.Rollback.Tool,

      # ── Skills ───────────────────────────────────────────────────────────
      "use_skill" => OptimalSystemAgent.Tools.Builtins.UseSkill,
      "skill_manager" => OptimalSystemAgent.Tools.Builtins.SkillManager,

      # ── Flat-layout tools (pending migration) ──────────────────────────
      # create_skill / list_skills now register their structured `.Tool` module
      # directly. Dispatch is identical (both the flat shim and the `.Tool`
      # module export execute/2 → LegacyAdapter structured path), so this is a
      # behavior-preserving consistency fix that also makes the redundant
      # `CreateSkill` / `ListSkills` defdelegate shims safe to delete.
      "create_skill" => OptimalSystemAgent.Tools.Builtins.CreateSkill.Tool,
      "list_skills" => OptimalSystemAgent.Tools.Builtins.ListSkills.Tool,
      "save_skill" => OptimalSystemAgent.Tools.Builtins.SaveSkill,
      "find_skill" => OptimalSystemAgent.Tools.Builtins.FindSkill,
      "computer_use" => OptimalSystemAgent.Tools.Builtins.ComputerUse,
      "verify_loop" => OptimalSystemAgent.Verification.Tools.VerifyLoop,
      "spawn_conversation" => OptimalSystemAgent.Conversations.Tools.SpawnConversation,
      "start_speculative" => OptimalSystemAgent.Speculative.Tools.StartSpeculative,

      # ── Previously-orphaned builtins (now wired) ───────────────────────
      # Fully-implemented, behaviour-conforming tools that were sitting on disk
      # unregistered (invisible to the model). Each conforms to the flat
      # contract (name/0 + execute/1 + description/0 + parameters/0) and gates
      # its own availability via available?/0 where the capability needs an
      # env/binary/service (browser HTTP-fallback, code_sandbox docker,
      # wallet_ops :wallet_enabled). Guarded against future drift by
      # test/optimal_system_agent/tools/registry_coverage_test.exs.
      "browser" => OptimalSystemAgent.Tools.Builtins.Browser,
      "github" => OptimalSystemAgent.Tools.Builtins.Github,
      "semantic_search" => OptimalSystemAgent.Tools.Builtins.SemanticSearch,
      "codebase_explore" => OptimalSystemAgent.Tools.Builtins.CodebaseExplore,
      "code_sandbox" => OptimalSystemAgent.Tools.Builtins.CodeSandbox,
      "knowledge" => OptimalSystemAgent.Tools.Builtins.Knowledge,
      "orchestrate" => OptimalSystemAgent.Tools.Builtins.Orchestrate,
      "diff" => OptimalSystemAgent.Tools.Builtins.Diff,
      "budget_status" => OptimalSystemAgent.Tools.Builtins.BudgetStatus,

      # ── Workspace shape ────────────────────────────────────────────────
      # Classifies submodules / nested independent repos / workspace members,
      # which `git ls-files` collapses to a single entry each. Cached per root.
      "workspace_map" => OptimalSystemAgent.Tools.Builtins.WorkspaceMap

      # NOT registered on purpose: mcts_index, wallet_ops, and the vault_*
      # tools have no backend (MCTS.Indexer / Integrations.Wallet / Vault do
      # not exist), so exposing them to the model would only produce runtime
      # errors. A tool earns registration only when it actually works.
    }
  end

  # ── Private: Tool List Building ───────────────────────────────────────

  defp build_tool_list(builtin_tools, _skills) do
    builtin_tools
    |> Enum.filter(fn {_name, mod} -> tool_available?(mod) end)
    |> Enum.map(fn {_name, mod} ->
      %{
        name: mod.name(),
        description: mod.description(),
        parameters: mod.parameters()
      }
    end)
  end

  defp tool_available?(mod) do
    not function_exported?(mod, :available?, 0) or mod.available?()
  end

  # Historical note: the registry used to compile a goldrush `:osa_tool_dispatcher`
  # module (`:glc.compile/2`) with one `:glc.any/1` branch per tool. Nothing ever
  # read it — tool execution resolves through the `builtin_tools` map in
  # `handle_call({:execute, ...})`, and `:glc.handle/2` is only ever called for
  # `:osa_event_router` (Events.Bus). Building it cost ~6s at 82 tools (superlinear:
  # 20 tools → 322ms, 40 → 1343ms, 60 → 3135ms, 82 → 6102ms), which was ~75% of
  # OSA's startup time. It has been removed outright rather than made lazy.

  # ── Private: Validation Error Formatting ─────────────────────────────

  defp validation_infra_error_result(mod, arguments, reason) do
    ctx = build_minimal_use_context(arguments)
    adapter = OptimalSystemAgent.Tools.LegacyAdapter

    read_only? = adapter.read_only?(mod, arguments, ctx)
    destructive? = adapter.destructive?(mod, arguments, ctx)

    if read_only? and not destructive? do
      :ok
    else
      {:error,
       "Tool '#{safe_tool_name(mod)}' argument validation unavailable: #{validation_reason(reason)}"}
    end
  rescue
    e ->
      {:error,
       "Tool '#{safe_tool_name(mod)}' argument validation unavailable: #{validation_reason(e)}"}
  end

  defp safe_tool_name(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0) do
      mod.name()
    else
      inspect(mod)
    end
  rescue
    _ -> inspect(mod)
  end

  defp validation_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp validation_reason(%{__struct__: _} = exception) do
    if is_exception(exception), do: Exception.message(exception), else: inspect(exception)
  end

  defp validation_reason(reason), do: inspect(reason)

  defp format_validation_errors(tool_name, errors) do
    details =
      Enum.map_join(errors, "\n", fn
        {message, "#" <> path} -> "  - #{path}: #{message}"
        {message, path} when is_binary(path) -> "  - #{path}: #{message}"
        {message, _} -> "  - #{message}"
      end)

    "Tool '#{tool_name}' argument validation failed:\n#{details}"
  end
end
