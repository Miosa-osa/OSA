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

    # Drop every cached variant; each is rebuilt lazily on its next read.
    invalidate_static_base()

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
  Drop every cached static-base variant so the next read re-renders it.

  Call this from anywhere the TOOL SET changes. `{{TOOL_DEFINITIONS}}` is
  rendered from the live registry (`Tools.Registry` builtins, the aggregate
  `mcp_tools` map, and — for the `:native_tools` variant — `list_active/0`),
  but the rendered result is process-wide cached in `:persistent_term`. Without
  this hook the prompt froze at whatever tool set existed on the first read:
  `MCP.Client.Manager` starts after `Tools.Registry` and its sessions connect
  asynchronously, so MCP tools always arrive later, and plugin tools later
  still.

  Deliberately does NOT rebuild. Rebuilding is expensive (every tool's
  `prompt/1` callback plus a full SYSTEM.md interpolation) and this runs inside
  registration paths that fire in bursts during boot — one cast per connecting
  MCP server. Lazy rebuild on next read is the existing contract and stays.

  Writing over an already-`nil` slot is skipped, so a burst of registrations
  costs one `:persistent_term.put/2` in total rather than one per registration.
  """
  @spec invalidate_static_base() :: :ok
  def invalidate_static_base do
    clear_variant(:static_base, :static_token_count)
    clear_variant(:static_base_lite, :static_token_count_lite)
    clear_variant(:static_base_native, :static_token_count_native)
    :ok
  end

  defp clear_variant(base_key, count_key) do
    case :persistent_term.get({__MODULE__, base_key}, nil) do
      nil ->
        :ok

      _cached ->
        :persistent_term.put({__MODULE__, base_key}, nil)
        :persistent_term.put({__MODULE__, count_key}, 0)
        :ok
    end
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

  ## Measured sizes (v1.0.82)

      :full          30,901 tokens
      :lite          24,375 tokens
      :native_tools  16,059 tokens

  `:lite` is NOT the small prompt its name suggests, and the numbers are
  recorded here because the code around it used to claim it was ~4-6k — a
  figure roughly five times off. Trimming the tool section removes about 6.5k
  from `:full`; the remaining ~24k is the SYSTEM.md body itself, which `:lite`
  does not touch. Anything reasoning about whether a small window can afford
  this prompt must use `static_token_count/1`, never the name.

  Note also that `:native_tools` is the SMALLEST variant, 8.3k below `:lite`.
  `Agent.Context.static_base_variant/2` still prefers `:lite` for local
  providers, deliberately: `:native_tools` omits the tool documentation on the
  assumption that the transport carries the schemas itself, which is not safe
  to assume for every local runtime. Keep the sizes in mind before treating
  "lite" as the cheap option — it is the middle one.

  `test/optimal_system_agent/soul/static_base_size_test.exs` pins these so the
  claim cannot silently rot again.
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
    case lean_template() || PromptLoader.get(:SYSTEM) do
      nil -> compose_legacy_template()
      content -> content
    end
  end

  # SYSTEM_LEAN.md, or nil to fall through to SYSTEM.md.
  #
  # A user override at ~/.osa/prompts/SYSTEM.md always wins: writing that file
  # is an explicit statement about what the prompt should be, and quietly
  # serving a different bundled template instead would discard it.
  defp lean_template do
    if lean_prompt?() and not PromptLoader.user_override?(:SYSTEM) do
      PromptLoader.get(:SYSTEM_LEAN)
    end
  end

  @doc """
  Serve the lean system-prompt template (`priv/prompts/SYSTEM_LEAN.md`) instead
  of `priv/prompts/SYSTEM.md`?

  Defaults to `true`. Set

      config :optimal_system_agent, :lean_prompt, false

  to restore the long template and the unfilled bundled rule files, without a
  code change or a deploy.

  ## What the lean template drops, and why it is safe

  `SYSTEM.md` is 41,242 B; `SYSTEM_LEAN.md` is roughly half that. Nothing was
  paraphrased away — the cuts are, in descending order of confidence:

    1. **Text the model already receives as a tool schema.** The provider ships
       every `Registry.list_active/0` description on the same request, so
       §5 "Tool Routing" is a second copy of `shell_execute`'s own routing list,
       §3's `delegate(...)` call examples and parameter docs are a second copy of
       the `delegate` schema, §6 "Complex Tasks" is a second copy of
       `task_write`'s "When to Use"/state-machine text, §6 "Memory" is a second
       copy of `memory_save`'s "Iron Rule", §5 "Tool Discovery" is a second copy
       of `tool_search`, and §8's committing rules are a second copy of the
       `git` tool's "Git Safety Protocol". Deleting the prose leaves the
       instruction intact on the wire.
    2. **Text duplicated elsewhere in the prompt itself** — the preamble rules
       appeared three times, "stop when done" twice.
    3. **UI affordances the model cannot act on** — `/effort`, `/coordinator`,
       `max_budget_usd`, and the "Allow once / Allow always / Deny" prompt are
       all harness-side; the model cannot set any of them.

  Guidance that exists in exactly one place is kept verbatim: the completion
  audit, the permission-mode validation matrix, ambition-vs-precision, the
  never-guess coding standards, the dirty-worktree git rules, and the whole
  terminal formatting contract.

  The same flag gates `rules_content/0` skipping bundled rule files that are
  still unfilled templates — see `substantive_rule?/1`.
  """
  @spec lean_prompt?() :: boolean()
  def lean_prompt? do
    Application.get_env(:optimal_system_agent, :lean_prompt, true) == true
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
    rule_dirs()
    |> Enum.flat_map(fn dir ->
      dir
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{dir, &1})
    end)
    |> Enum.map(fn {dir, path} ->
      name = Path.relative_to(path, dir) |> String.replace_suffix(".md", "")
      {meta, body} = split_rule_frontmatter(File.read!(path))

      cond do
        respect_always_apply?() and meta.always_apply? == false -> nil
        lean_prompt?() and not substantive_rule?(body) -> nil
        true -> "## Rule: #{name}\n#{strip_html_comments(body)}"
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> "# Active Rules\n\n" <> Enum.join(parts, "\n\n")
    end
  rescue
    _ -> nil
  end

  # Where rules are read from, in prompt order: the bundled ones, then the
  # user's own.
  #
  # There used to be only the bundled directory, which meant a personal rule had
  # nowhere to live except inside the product. `priv/rules/projects/bos.md` was
  # exactly that — one developer's BusinessOS conventions, naming their own
  # `~/Desktop/BOS` checkout and Go module — shipped to every OSA user and
  # inlined into the cached prefix of every request they ever made. It was 4,429
  # bytes of instructions about a repository they cannot see.
  #
  # `~/.osa/rules/**/*.md` (honouring `OSA_HOME`) is now read the same way, so
  # personal and project rules live with the user instead of in the release.
  defp rule_dirs do
    bundled =
      case :code.priv_dir(:optimal_system_agent) do
        {:error, _} -> nil
        dir -> Path.join(to_string(dir), "rules")
      end

    user =
      Path.join(System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa"), "rules")

    [bundled, user]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&File.dir?/1)
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

  # The five bundled `behaviors/*.md` rules are UNFILLED TEMPLATES. Every one is
  # a generic checklist followed by a "YOUR INSIGHTS (Edit Below)" half whose
  # entire content is HTML-comment placeholders:
  #
  #     ### Common Bug Patterns in Our Codebase
  #     <!-- Add patterns you've noticed -->
  #
  # They shipped 11,009 bytes on every request. The HTML comments are invisible
  # in a rendered doc, so nobody noticed they were being sent to the model as
  # instruction text — including the worked EXAMPLES inside them, which name
  # tools that do not exist here (`make debug`, Sentry, `kubectl logs`) and read
  # as fact once the comment markers are gone. The checklist halves duplicate
  # SYSTEM.md's own coding-standards and completion-audit sections.
  #
  # A rule is substantive when, after removing frontmatter, HTML comments,
  # headings and list scaffolding, it still says something. Filling any of these
  # files in makes it ship again automatically — this suppresses empty
  # templates, not the rules mechanism.
  # The marker every bundled behaviour template uses to separate the generic
  # checklist it ships with from the section a human is meant to fill in.
  @rule_template_marker ~r/##\s*YOUR INSIGHTS/i

  defp substantive_rule?(body) do
    case Regex.split(@rule_template_marker, body, parts: 2) do
      # No marker: not one of the fill-in templates. Never drop it — absence of
      # the marker is not evidence the file is empty. `projects/bos.md` lands
      # here and keeps shipping.
      [_] ->
        true

      [_generic_half, human_half] ->
        human_half
        |> strip_html_comments()
        |> String.replace(~r/^#+ .*$/m, "")
        |> String.replace(~r/^\s*-{3,}\s*$/m, "")
        |> String.trim()
        |> String.length()
        |> Kernel.>=(rule_substance_threshold())
    end
  end

  defp strip_html_comments(text), do: String.replace(text, ~r/<!--.*?-->/s, "")

  # Characters of real prose a rule must carry to be worth a request. The five
  # unfilled bundled behaviours land far below this; a genuinely written rule
  # clears it easily. Tunable so the threshold is not a magic number buried in
  # a guard.
  defp rule_substance_threshold do
    Application.get_env(:optimal_system_agent, :rule_substance_threshold, 400)
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
