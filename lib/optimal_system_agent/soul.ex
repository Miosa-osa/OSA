defmodule OptimalSystemAgent.Soul do
  @moduledoc """
  Soul — loads, caches, and serves the cohesive system prompt.

  ## Architecture (v2 — Two-Tier)

  The Soul module manages a cacheable static base prompt:

      Static Base — SYSTEM.md interpolated with boot-time vars, cached in persistent_term
      Dynamic Context — assembled per-request by Agent.Context (not managed here)

  ## Static Base Assembly

  1. Load SYSTEM.md template (PromptLoader handles user override + bundled)
  2. On first call to `static_base/0`, interpolate boot-time variables:
     - `{{TOOL_DEFINITIONS}}` — tool schemas from Tools.Registry
     - `{{RULES}}` — project rules from priv/rules/
     - `{{USER_PROFILE}}` — USER.md content
  3. Cache the interpolated result + token count in persistent_term

  Lazy interpolation ensures Tools.Registry is available (it starts after Soul.load).

  ## Backward Compatibility

  If no SYSTEM.md exists but IDENTITY.md + SOUL.md do (old format),
  the module composes them with the security guardrail into a base prompt.

  ## File Locations

      priv/prompts/SYSTEM.md           — bundled cohesive system prompt (primary)
      ~/.osa/prompts/SYSTEM.md         — user override (takes precedence)
      ~/.osa/IDENTITY.md               — legacy identity (backward compat)
      ~/.osa/SOUL.md                   — legacy soul (backward compat)
      ~/.osa/USER.md                   — user profile
      ~/.osa/agents/<name>/            — per-agent overrides

  ## Caching

  Content is cached in `:persistent_term` for lock-free reads from any process.
  Files are re-read on explicit `reload/0` or at application boot.
  """

  require Logger

  alias OptimalSystemAgent.PromptLoader
  alias OptimalSystemAgent.Soul.ToolsSection

  defp soul_dir, do: Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Load soul files from disk and cache in persistent_term.
  Called at application boot and on explicit reload.

  Does NOT interpolate the static base — that happens lazily on first
  call to `static_base/0` (after Tools.Registry is available).
  """
  def load do
    dir = Path.expand(soul_dir())

    # Load user profile
    user = load_file(dir, "USER.md")
    :persistent_term.put({__MODULE__, :user}, user)

    # Load legacy files (backward compat + for_agent/1)
    identity = load_file(dir, "IDENTITY.md")
    soul = load_file(dir, "SOUL.md")
    :persistent_term.put({__MODULE__, :identity}, identity)
    :persistent_term.put({__MODULE__, :soul}, soul)

    # Discover per-agent souls
    agents_dir = Path.join(dir, "agents")
    agent_souls = load_agent_souls(agents_dir)
    :persistent_term.put({__MODULE__, :agent_souls}, agent_souls)

    # Invalidate cached static base (rebuilt lazily on next static_base/0 call)
    :persistent_term.put({__MODULE__, :static_base}, nil)
    :persistent_term.put({__MODULE__, :static_token_count}, 0)
    # Also invalidate the LITE variant (rebuilt lazily on next static_base(:lite) call)
    :persistent_term.put({__MODULE__, :static_base_lite}, nil)
    :persistent_term.put({__MODULE__, :static_token_count_lite}, 0)
    # ...and the NATIVE-TOOLS variant (static_base(:native_tools))
    :persistent_term.put({__MODULE__, :static_base_native}, nil)
    :persistent_term.put({__MODULE__, :static_token_count_native}, 0)

    loaded_count = Enum.count([identity, soul, user], &(&1 != nil))
    agent_count = map_size(agent_souls)

    Logger.info("[Soul] Loaded #{loaded_count}/3 bootstrap files, #{agent_count} agent soul(s)")
    :ok
  end

  @doc "Force reload all soul files from disk and invalidate cache."
  def reload do
    load()
    :ok
  end

  @doc """
  Returns the cached, interpolated static base prompt.

  On first call after boot or reload, reads the SYSTEM.md template,
  interpolates boot-time variables, caches the result, and returns it.
  Subsequent calls return the cached value (~0 cost).
  """
  @spec static_base() :: String.t()
  def static_base do
    case :persistent_term.get({__MODULE__, :static_base}, nil) do
      nil -> interpolate_and_cache()
      cached -> cached
    end
  end

  @doc "Returns the token count of the cached static base."
  @spec static_token_count() :: non_neg_integer()
  def static_token_count do
    # Ensure static base is built
    _ = static_base()
    :persistent_term.get({__MODULE__, :static_token_count}, 0)
  end

  @doc """
  Returns a named variant of the cached static base.

    * `:full`         — `static_base/0` unmodified.
    * `:lite`         — the same SYSTEM.md template with only the core-tool
      allowlist inlined; non-core tools are advertised by name via the
      `<system-reminder>` and loadable through tool_search. Used for local
      providers and small context windows.
    * `:native_tools` — the FULL tool set, but with the spans that duplicate
      the request's own native tool definitions removed from
      `{{TOOL_DEFINITIONS}}`. Only meaningful for a provider whose transport
      actually carries those schemas (`Providers.Registry.native_tool_schemas?/1`);
      selected in `Agent.Context` and gated by
      `config :optimal_system_agent, :dedupe_native_tool_prompt`.

  Each variant gets its OWN persistent_term slot: the static base is
  process-wide cached and cannot vary per request from a single slot.
  """
  @spec static_base(:full | :lite | :native_tools) :: String.t()
  def static_base(:full), do: static_base()

  def static_base(:lite) do
    case :persistent_term.get({__MODULE__, :static_base_lite}, nil) do
      nil -> interpolate_and_cache(:lite)
      cached -> cached
    end
  end

  def static_base(:native_tools) do
    case :persistent_term.get({__MODULE__, :static_base_native}, nil) do
      nil -> interpolate_and_cache(:native_tools)
      cached -> cached
    end
  end

  @doc "Token count of the given static-base variant. See `static_base/1`."
  @spec static_token_count(:full | :lite | :native_tools) :: non_neg_integer()
  def static_token_count(:full), do: static_token_count()

  def static_token_count(:lite) do
    # Ensure lite static base is built
    _ = static_base(:lite)
    :persistent_term.get({__MODULE__, :static_token_count_lite}, 0)
  end

  def static_token_count(:native_tools) do
    _ = static_base(:native_tools)
    :persistent_term.get({__MODULE__, :static_token_count_native}, 0)
  end

  @doc """
  Is the native-tool-schema de-duplication enabled?

  Defaults to `true`. Set

      config :optimal_system_agent, :dedupe_native_tool_prompt, false

  to fall back to the full prose tool block for every provider, without a
  code change.
  """
  @spec dedupe_native_tool_prompt?() :: boolean()
  def dedupe_native_tool_prompt? do
    Application.get_env(:optimal_system_agent, :dedupe_native_tool_prompt, true) == true
  end

  @doc "Get the user profile content (USER.md)."
  @spec user() :: String.t() | nil
  def user do
    :persistent_term.get({__MODULE__, :user}, nil)
  end

  @doc """
  Get the soul for a specific named agent.
  Falls back to the default soul if no agent-specific soul exists.
  """
  @spec for_agent(String.t()) :: %{identity: String.t() | nil, soul: String.t() | nil}
  def for_agent(agent_name) do
    agent_souls = :persistent_term.get({__MODULE__, :agent_souls}, %{})

    case Map.get(agent_souls, agent_name) do
      nil ->
        %{identity: identity(), soul: soul()}

      agent_soul ->
        %{
          identity: agent_soul[:identity] || identity(),
          soul: agent_soul[:soul] || soul()
        }
    end
  end

  # ── Backward Compat Accessors ──────────────────────────────────────
  # Still used by commands.ex and cli.ex for status display.

  @doc "Get the identity content (IDENTITY.md)."
  @spec identity() :: String.t() | nil
  def identity do
    :persistent_term.get({__MODULE__, :identity}, nil)
  end

  @doc "Get the soul content (SOUL.md)."
  @spec soul() :: String.t() | nil
  def soul do
    :persistent_term.get({__MODULE__, :soul}, nil)
  end

  # ── Static Base Assembly ───────────────────────────────────────────

  defp interpolate_and_cache do
    base = build_base(tools_content())

    token_count = estimate_tokens(base)
    :persistent_term.put({__MODULE__, :static_base}, base)
    :persistent_term.put({__MODULE__, :static_token_count}, token_count)

    Logger.info("[Soul] Static base cached: #{token_count} tokens")
    base
  end

  # LITE variant — same template, but only the core-tool allowlist is inlined
  # (ToolsSection.build(:lite)). Cached in its own persistent_term slot.
  defp interpolate_and_cache(:lite) do
    base = build_base(tools_content(:lite))

    token_count = estimate_tokens(base)
    :persistent_term.put({__MODULE__, :static_base_lite}, base)
    :persistent_term.put({__MODULE__, :static_token_count_lite}, token_count)

    Logger.info("[Soul] Static base (lite) cached: #{token_count} tokens")
    base
  end

  # NATIVE-TOOLS variant — same template and same tool set as the full base,
  # minus the spans the request's own tool definitions already carry.
  defp interpolate_and_cache(:native_tools) do
    base = build_base(tools_content(:native_tools))

    token_count = estimate_tokens(base)
    :persistent_term.put({__MODULE__, :static_base_native}, base)
    :persistent_term.put({__MODULE__, :static_token_count_native}, token_count)

    Logger.info("[Soul] Static base (native tools) cached: #{token_count} tokens")
    base
  end

  # Interpolate SYSTEM.md with the given pre-rendered tool-definitions block plus
  # the boot-time rules/user/soul/identity content. Shared by the full and lite
  # variants so the only difference between the two bases is the tools section.
  # Grok-style memory pointer: a tiny STATIC section advertising the on-demand
  # memory tools instead of force-injecting recalled memories every turn.
  # Compile-time constant appended to the cached base — stable across turns,
  # so it is safe inside the Anthropic ephemeral-cached content block.
  @memory_pointer """
  <memory>
  Long-term memory and learned skills are NOT auto-injected on trivial turns. \
  When the user references past work, preferences, decisions, or prior \
  sessions, call `memory_recall` with a focused query. Call `find_skill` to \
  load a learned skill's full steps.
  </memory>
  """

  defp build_base(tools_section) do
    base =
      load_system_template()
      |> interpolate("{{TOOL_DEFINITIONS}}", tools_section)
      |> interpolate("{{RULES}}", rules_content())
      |> interpolate("{{USER_PROFILE}}", user_content())
      |> interpolate("{{SOUL_CONTENT}}", soul_content())
      |> interpolate("{{IDENTITY_PROFILE}}", identity_content())

    base <> "\n\n" <> String.trim(@memory_pointer)
  end

  defp load_system_template do
    # Priority: PromptLoader (handles ~/.osa/prompts/ override + priv/prompts/ bundled)
    case PromptLoader.get(:SYSTEM) do
      nil -> compose_legacy_template()
      content -> content
    end
  end

  @doc false
  def compose_legacy_template do
    # Legacy path removed — SYSTEM.md is the only template.
    # If SYSTEM.md is missing, return a minimal fallback.
    """
    You are OSA (Optimal System Agent). Respond helpfully and concisely.

    {{TOOL_DEFINITIONS}}

    {{USER_PROFILE}}
    """
    |> String.trim()
  end

  defp interpolate(text, marker, nil), do: String.replace(text, marker, "")
  defp interpolate(text, marker, ""), do: String.replace(text, marker, "")
  defp interpolate(text, marker, content), do: String.replace(text, marker, content)

  # ── Boot-Time Content Generators ───────────────────────────────────

  # Delegates to Soul.ToolsSection which calls PromptAssembler.assemble/3,
  # invoking each structured tool's `prompt/1` callback (dynamic, with
  # cross-tool name references) and appending a <system-reminder> block for
  # any deferred tools.  Flat-layout tools fall back to `description/0`.
  defp tools_content do
    ToolsSection.build()
  end

  # LITE tools section: only the core allowlist inlined, everything else deferred.
  defp tools_content(:lite) do
    ToolsSection.build(:lite)
  end

  # NATIVE tools section: full tool set, duplicated spans removed.
  defp tools_content(:native_tools) do
    ToolsSection.build(:native_tools)
  end

  defp rules_content do
    rules_dir =
      case :code.priv_dir(:optimal_system_agent) do
        {:error, _} -> nil
        dir -> Path.join(to_string(dir), "rules")
      end

    if rules_dir && File.dir?(rules_dir) do
      rules_dir
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path ->
        name = Path.relative_to(path, rules_dir) |> String.replace_suffix(".md", "")
        {meta, body} = split_rule_frontmatter(File.read!(path))

        cond do
          respect_always_apply?() and meta.always_apply? == false -> nil
          true -> "## Rule: #{name}\n#{body}"
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        parts -> "# Active Rules\n\n" <> Enum.join(parts, "\n\n")
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  # Every bundled rule carries a YAML frontmatter block declaring `globs:` and,
  # for the narrow ones, `alwaysApply: false`. Nothing read it: the loader
  # concatenated the raw file, so
  #
  #   * `typescript.md`, `testing.md`, `api/security.md` and
  #     `frontend/components.md` — 5,812 bytes that say in their OWN metadata
  #     that they do not always apply — were nonetheless in the system prompt of
  #     every request, telling a model editing Elixir about `.tsx` conventions;
  #   * the frontmatter itself, `---` fences and all, was shipped to the model
  #     as if it were instruction text.
  #
  # A rule with no frontmatter, or with no `alwaysApply` key, is kept: absence
  # of the flag is not a claim that it should be dropped.
  defp split_rule_frontmatter(content) do
    case String.split(content, ~r/\A---\r?\n/, parts: 2) do
      [_, rest] ->
        case String.split(rest, ~r/\r?\n---\r?\n/, parts: 2) do
          [meta, body] -> {parse_rule_meta(meta), String.trim_leading(body)}
          _ -> {%{always_apply?: nil}, content}
        end

      _ ->
        {%{always_apply?: nil}, content}
    end
  end

  defp parse_rule_meta(meta) do
    always_apply? =
      cond do
        Regex.match?(~r/^\s*alwaysApply\s*:\s*false\s*$/mi, meta) -> false
        Regex.match?(~r/^\s*alwaysApply\s*:\s*true\s*$/mi, meta) -> true
        true -> nil
      end

    %{always_apply?: always_apply?}
  end

  @doc """
  Should a bundled rule's `alwaysApply: false` be honored?

  Defaults to `true`. Set

      config :optimal_system_agent, :rules_respect_always_apply, false

  to restore the previous behaviour of injecting every rule file into the
  static base regardless of what it declares.

  Frontmatter STRIPPING is not gated: a `---`/`globs:`/`alwaysApply:` block is
  loader metadata in every case, and there is no reading under which sending it
  to the model as instruction text is correct.
  """
  @spec respect_always_apply?() :: boolean()
  def respect_always_apply? do
    Application.get_env(:optimal_system_agent, :rules_respect_always_apply, true) == true
  end

  defp user_content do
    case user() do
      nil -> nil
      "" -> nil
      content -> content
    end
  end

  defp soul_content do
    case soul() do
      nil -> nil
      "" -> nil
      content -> content
    end
  end

  defp identity_content do
    case identity() do
      nil -> nil
      "" -> nil
      content -> content
    end
  end

  # ── Token Estimation ───────────────────────────────────────────────

  defp estimate_tokens(nil), do: 0
  defp estimate_tokens(""), do: 0

  defp estimate_tokens(text) when is_binary(text) do
    OptimalSystemAgent.Utils.Tokens.estimate(text)
  end

  # ── File Loading ───────────────────────────────────────────────────

  defp load_file(dir, filename) do
    path = Path.join(dir, filename)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          content = String.trim(content)
          if content == "", do: nil, else: content

        {:error, reason} ->
          Logger.warning("[Soul] Failed to read #{path}: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end

  defp load_agent_souls(agents_dir) do
    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
      |> Enum.reduce(%{}, fn agent_name, acc ->
        agent_dir = Path.join(agents_dir, agent_name)
        agent_identity = load_file(agent_dir, "IDENTITY.md")
        agent_soul = load_file(agent_dir, "SOUL.md")

        if agent_identity || agent_soul do
          Map.put(acc, agent_name, %{identity: agent_identity, soul: agent_soul})
        else
          acc
        end
      end)
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("[Soul] Failed to load agent souls: #{Exception.message(e)}")
      %{}
  end
end
