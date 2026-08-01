defmodule OptimalSystemAgent.Agent.ContextDiscovery do
  @moduledoc """
  Auto-discovers project context files from the working directory.

  Scans for context files in priority order (first match wins):
    1. .osa/context.md (project-level OSA config)
    2. AGENTS.md (agent instructions)
    3. CLAUDE.md (Claude Code instructions)
    4. .cursorrules / .cursor/rules/*.mdc (Cursor rules)

  Content is truncated at 20,000 chars with a 70/20 head/tail ratio
  to keep the system prompt manageable.
  """
  require Logger

  @head_ratio 0.7
  @tail_ratio 0.2

  # Char cap for injected project context (configurable; default 8_000 ≈ 2k
  # tokens — lowered from the old hardcoded 20_000 so instruction files cannot
  # dominate the per-turn dynamic tier).
  defp max_chars,
    do: Application.get_env(:optimal_system_agent, :project_context_char_cap, 8_000)

  # Discovery cache — instruction files are read + injection-scanned once per
  # TTL instead of on every context build.
  @cache_table :osa_context_discovery_cache
  @cache_ttl 60_000

  @context_files [
    ".osa/context.md",
    ".osa/CONTEXT.md",
    "AGENTS.md",
    "agents.md",
    "CLAUDE.md",
    "claude.md",
    ".cursorrules"
  ]

  @spec discover(String.t() | nil) :: String.t() | nil
  def discover(working_dir) do
    dir = working_dir || OptimalSystemAgent.Workspace.Cwd.get()
    ensure_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, dir) do
      [{^dir, result, ts}] when now - ts < @cache_ttl ->
        result

      _ ->
        result = do_discover(dir)
        :ets.insert(@cache_table, {dir, result, now})
        result
    end
  rescue
    _ -> nil
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:named_table, :public, :set])
      _ -> @cache_table
    end
  rescue
    ArgumentError -> @cache_table
  end

  defp do_discover(dir) do
    search_dirs = search_dirs(dir)

    result =
      Enum.find_value(search_dirs, fn search_dir ->
        Enum.find_value(@context_files, fn filename ->
          path = Path.join(search_dir, filename)

          if File.regular?(path) do
            case File.read(path) do
              {:ok, content} when byte_size(content) > 0 ->
                Logger.debug("[ContextDiscovery] Found project context: #{path}")
                {path, content}

              _ ->
                nil
            end
          end
        end)
      end)

    result = result || find_cursor_rules(search_dirs)

    case result do
      {path, content} ->
        case scan_for_injection(content) do
          :clean ->
            truncated = truncate_smart(content, max_chars())
            "## Project Context (#{Path.basename(path)})\n\n#{truncated}"

          {:blocked, reason} ->
            Logger.warning(
              "[ContextDiscovery] BLOCKED #{path} — prompt injection detected: #{reason}"
            )

            nil
        end

      nil ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Directories searched for a project context file, innermost first.

  `git rev-parse --show-toplevel` alone is not enough. Inside a **nested
  independent repository** — a repo whose `.git` lives inside another repo's
  working tree, which the parent tracks as a single opaque gitlink — git answers
  with the *inner* repo. Anchoring discovery on that answer means the enclosing
  monorepo's `AGENTS.md` is never found, even though the operator is plainly
  working inside that monorepo. Submodules behave the same way.

  So we search the cwd, the git root, and every *enclosing workspace root* above
  it (`Topology.enclosing_roots/1`: outer git repos, Elixir umbrellas, Cargo /
  pnpm / npm workspaces, `go.work`). First match still wins, so an inner
  component's own instruction file continues to take precedence over the
  constellation's — only the fallback chain got longer.

  `enclosing_roots/1` walks upward with a handful of `File.exists?` probes and
  never triggers a topology walk, so this stays cheap enough for the cached
  discovery path.
  """
  @spec search_dirs(String.t()) :: [String.t()]
  def search_dirs(dir) do
    git_root = find_git_root(dir)

    enclosing =
      try do
        OptimalSystemAgent.Workspace.Topology.enclosing_roots(dir)
      rescue
        _ -> []
      end

    [dir, git_root]
    |> Enum.concat(enclosing)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp find_git_root(dir) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", "--show-toplevel"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {root, 0} -> String.trim(root)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp find_cursor_rules(dirs) do
    Enum.find_value(dirs, fn dir ->
      rules_dir = Path.join(dir, ".cursor/rules")

      if File.dir?(rules_dir) do
        case Path.wildcard(Path.join(rules_dir, "*.mdc")) do
          [first | _] = files ->
            content =
              Enum.map_join(files, "\n\n---\n\n", fn f ->
                case File.read(f) do
                  {:ok, c} -> "### #{Path.basename(f)}\n\n#{c}"
                  _ -> ""
                end
              end)

            if content != "", do: {first, content}

          [] ->
            nil
        end
      end
    end)
  end

  # Injection scanning for context files before loading into system prompt.
  @injection_patterns [
    ~r/ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompt|context|rules?)/i,
    ~r/ignore\s+all\s+(instructions?|rules?|guidelines?)/i,
    ~r/disregard\s+(your\s+)?(previous\s+)?(instructions?|guidelines?|rules?)/i,
    ~r/forget\s+(everything|all)\s+(you\s+)?(were\s+)?(told|instructed)/i,
    ~r/(override|bypass|circumvent|disable)\s+.{0,30}(instructions?|restrictions?|safety)/i,
    ~r/you\s+are\s+now\s+(a|an|the)\s+/i,
    ~r/(jailbreak|do\s+anything\s+now|developer\s+mode|prompt\s+injection)/i,
    ~r/(pretend|act\s+as\s+if|imagine)\s+.{0,40}(no\s+restrictions?|unrestricted|without\s+limits?)/i,
    ~r/\byou\s+(are|were|become)\s+DAN\b/i,
    ~r/(output|print|repeat|reveal)\s+(everything|all|your)\s+(above|before|system|prompt|instructions?)/i
  ]

  @invisible_chars ~r/[\x{200B}\x{200C}\x{200D}\x{200E}\x{200F}\x{FEFF}\x{00AD}\x{2060}\x{2061}\x{2062}\x{2063}\x{2064}]/u

  @doc """
  Scan instruction-file content for prompt-injection before loading it into the
  system prompt. Returns `:clean` or `{:blocked, reason}`. Public so the
  directory-scoped lazy injector (`ProjectInstructions`) reuses the same gate.
  """
  @spec scan_for_injection(String.t()) :: :clean | {:blocked, String.t()}
  def scan_for_injection(content) do
    has_invisible = Regex.match?(@invisible_chars, content)

    if has_invisible do
      {:blocked, "invisible Unicode characters detected (possible obfuscation)"}
    else
      case Enum.find(@injection_patterns, &Regex.match?(&1, content)) do
        nil -> :clean
        pattern -> {:blocked, "matched pattern: #{inspect(pattern.source)}"}
      end
    end
  end

  defp truncate_smart(content, max) when byte_size(content) <= max, do: content

  defp truncate_smart(content, max) do
    head_size = trunc(max * @head_ratio)
    tail_size = trunc(max * @tail_ratio)

    head = String.slice(content, 0, head_size)
    tail = String.slice(content, -tail_size, tail_size)
    omitted = String.length(content) - head_size - tail_size

    head <> "\n\n[... #{omitted} chars omitted ...]\n\n" <> tail
  end
end
