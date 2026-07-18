defmodule OptimalSystemAgent.Permissions do
  @moduledoc """
  Permission rule engine (CC-parity, WS3).

  ## Rule format

  Rules are `Tool` or `Tool(content)` strings — CC `permissionRuleParser`
  semantics. Parentheses and backslashes inside `content` are escaped as
  `\\(`, `\\)` and `\\\\`. Malformed rules degrade to a tool-name-only rule.
  CC tool names (`Bash`, `Edit`, `Write`, …) are accepted as aliases for the
  OSA tool names.

  Content matching (CC `shellRuleMatching` port):

    * `exact`     — `shell_execute(npm test)` matches only `npm test`
    * `prefix`    — `shell_execute(git:*)` matches `git` and `git <anything>`
    * `wildcard`  — `*` matches any characters (dotAll: newlines included);
                    `\\*` is a literal star, `\\\\` a literal backslash. A rule
                    ending in ` *` with a single wildcard also matches the bare
                    prefix (`git *` matches `git`).

  Shell commands are split into compound subcommands (`&&`, `||`, `;`, `|`,
  `&`, newline — quote-aware): a deny/ask rule fires when ANY subcommand
  matches; an allow requires the full command or EVERY subcommand covered.

  ## Sources & provenance

  Rules are read from the settings cascade plus the legacy rule store, each
  match carrying `%{behavior, rule, source}` provenance:

    * `:session` — in-memory session settings
    * `:flag`    — `--settings <file>` / `OSA_SETTINGS`
    * `:local`   — `.osa/settings.local.json`
    * `:project` — `.osa/settings.json`
    * `:user`    — `~/.osa/settings.json`
    * `:legacy`  — `~/.osa/permissions.json` (interactive "Always" store;
                   old `tool:pattern` colon rules are migrated on read)

  Settings-file shape:

      {"permissions": {"allow": ["shell_execute(npm test:*)"],
                       "deny":  ["file_edit(.env)"],
                       "ask":   ["shell_execute(git push:*)"],
                       "additionalDirectories": ["/extra/dir"]}}

  Evaluation order (CC `permissions.ts`): deny → ask → allow → default `:ask`.
  """

  alias OptimalSystemAgent.Settings

  @default_permissions_file Path.expand("~/.osa/permissions.json")

  # Settings-cascade sources, highest priority first (legacy store appended last).
  @settings_sources [:session, :flag, :local, :project, :user]

  # CC-style tool names accepted in rules as aliases for OSA tool names.
  @tool_aliases %{
    "Bash" => "shell_execute",
    "Edit" => "file_edit",
    "MultiEdit" => "multi_file_edit",
    "Write" => "file_write",
    "Read" => "file_read",
    "Glob" => "file_glob",
    "Grep" => "file_grep",
    "WebFetch" => "web_fetch",
    "WebSearch" => "web_search"
  }

  # File tools whose primary argument is a path they mutate.
  @file_mutating_tools ~w(file_write file_edit multi_file_edit file_create file_delete file_move)

  # Shell startup files — writes here are bypass-immune safety asks.
  @shell_rc_files ~w(.bashrc .zshrc .profile .bash_profile .bash_login .bash_logout .zshenv .zprofile .zlogin)

  # Commands whose first TWO words form the natural permission prefix
  # (`npm test:*` rather than `npm:*`).
  @two_word_prefixes ~w(npm pnpm yarn bun cargo go git mix make docker kubectl gh)

  # Resolved at call time (not compile time) so tests can redirect the legacy
  # rule store to a tmp path via `config :optimal_system_agent, :permissions_file`.
  defp permissions_file do
    Application.get_env(:optimal_system_agent, :permissions_file, @default_permissions_file)
  end

  # ── Evaluation ───────────────────────────────────────────────────────

  @doc """
  Check a tool call against every saved rule. Returns `:allow | :deny | :ask`.
  See `check_detailed/2` for provenance.
  """
  def check(tool_name, args \\ %{}) do
    {decision, _meta} = check_detailed(tool_name, args)
    decision
  end

  @doc """
  Like `check/2` but returns `{decision, meta}` where meta is
  `%{behavior, rule, source}` provenance for the matching rule, or
  `%{behavior: :ask, rule: nil, source: nil}` when no rule matched
  (the default-ask case).
  """
  def check_detailed(tool_name, args \\ %{})

  def check_detailed(tool_name, args) when is_binary(tool_name) do
    args = if is_map(args), do: args, else: %{}
    grouped = Enum.group_by(rules(), & &1.behavior)

    cond do
      meta = first_match(Map.get(grouped, :deny, []), tool_name, args) ->
        {:deny, meta}

      meta = first_match(Map.get(grouped, :ask, []), tool_name, args) ->
        {:ask, meta}

      meta = allow_match(Map.get(grouped, :allow, []), tool_name, args) ->
        {:allow, meta}

      true ->
        {:ask, %{behavior: :ask, rule: nil, source: nil}}
    end
  end

  def check_detailed(_tool_name, _args), do: {:ask, %{behavior: :ask, rule: nil, source: nil}}

  @doc """
  All rules from every source with provenance:
  `[%{behavior: :allow | :deny | :ask, rule: "Tool(content)", source: atom}]`.
  Order: session → flag → local → project → user → legacy.
  """
  def rules do
    settings_rules() ++ legacy_rules()
  end

  # ── Rule persistence (legacy store — interactive "Always" decisions) ──

  @doc """
  Save a permission rule to the legacy store (`~/.osa/permissions.json`).

  `rule` may be a bare tool name (`"shell_execute"`) or a full rule string
  (`"shell_execute(npm test:*)"`). Decision is `:allow_always | :deny_always`.
  """
  def save_rule(rule, decision) do
    rules = load_legacy()

    action =
      case decision do
        :allow_always -> "allow"
        :deny_always -> "deny"
        _ -> nil
      end

    if action do
      write_legacy(Map.put(rules, rule, action))
    end
  end

  @doc "List saved legacy rules as a `%{rule_string => \"allow\" | \"deny\"}` map."
  def list_rules do
    load_legacy()
  end

  @doc "Remove a saved legacy rule by its exact rule string."
  def remove_rule(rule) do
    write_legacy(Map.delete(load_legacy(), rule))
  end

  @doc """
  The rule string an interactive "Always" decision should persist for a call.

  Shell tools get a prefix rule built from the command (`npm test` →
  `shell_execute(npm test:*)`, CC suggestion semantics); every other tool gets
  a tool-level rule.
  """
  def suggested_rule(tool_name, args \\ %{}) do
    cmd = if shell_tool?(tool_name), do: command_of(args), else: nil

    case cmd do
      c when is_binary(c) ->
        case String.trim(c) do
          "" -> tool_name
          trimmed -> rule_to_string(tool_name, suggested_prefix(trimmed) <> ":*")
        end

      _ ->
        tool_name
    end
  end

  @doc false
  def suggested_prefix(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      [a, b | _] when a in @two_word_prefixes -> a <> " " <> b
      [a | _] -> a
      [] -> command
    end
  end

  # ── Rule string parsing (CC permissionRuleParser port) ───────────────

  @doc """
  Parse a `Tool` / `Tool(content)` rule string into
  `%{tool: name, content: content_or_nil}` (escaped parens honored, CC tool
  aliases normalized, malformed rules degrade to tool-name-only).
  """
  def parse_rule(rule) when is_binary(rule) do
    open = rule |> unescaped_positions(?() |> List.first()
    close = rule |> unescaped_positions(?)) |> List.last()

    cond do
      open == nil ->
        %{tool: normalize_tool(rule), content: nil}

      close == nil or close <= open or close != byte_size(rule) - 1 or open == 0 ->
        # Malformed (no close, close before open, trailing garbage, or missing
        # tool name) — treat the whole string as a tool name, like CC.
        %{tool: normalize_tool(rule), content: nil}

      true ->
        tool = binary_part(rule, 0, open)
        raw = binary_part(rule, open + 1, close - open - 1)

        # Empty content and a bare "*" mean the whole tool.
        if raw in ["", "*"] do
          %{tool: normalize_tool(tool), content: nil}
        else
          %{tool: normalize_tool(tool), content: unescape_content(raw)}
        end
    end
  end

  @doc "Build a rule string from a tool name and optional content (escaping parens/backslashes)."
  def rule_to_string(tool, nil), do: tool
  def rule_to_string(tool, content), do: tool <> "(" <> escape_content(content) <> ")"

  @doc false
  def escape_content(content) do
    content
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  @doc false
  def unescape_content(content) do
    content
    |> String.replace("\\(", "(")
    |> String.replace("\\)", ")")
    |> String.replace("\\\\", "\\")
  end

  # ── Shell rule matching (CC shellRuleMatching port) ──────────────────

  @doc """
  Match one rule content against one (sub)command: exact, legacy `prefix:*`,
  or wildcard `*` with `\\*` escape and dotAll semantics.
  """
  def match_shell_rule?(content, command) when is_binary(content) and is_binary(command) do
    command = String.trim(command)

    case classify_content(content) do
      {:prefix, prefix} -> command == prefix or String.starts_with?(command, prefix <> " ")
      {:wildcard, pattern} -> wildcard_match?(pattern, command)
      {:exact, exact} -> command == exact
    end
  end

  def match_shell_rule?(_, _), do: false

  @doc false
  def classify_content(content) do
    content = String.trim(content)

    cond do
      String.ends_with?(content, ":*") and byte_size(content) > 2 ->
        {:prefix, binary_part(content, 0, byte_size(content) - 2)}

      unescaped_positions(content, ?*) != [] ->
        {:wildcard, content}

      true ->
        {:exact, content}
    end
  end

  @doc false
  def wildcard_match?(pattern, value) when is_binary(pattern) and is_binary(value) do
    case wildcard_regex(String.trim(pattern)) do
      {:ok, regex} -> Regex.match?(regex, value)
      _ -> false
    end
  end

  def wildcard_match?(_, _), do: false

  defp wildcard_regex(pattern) do
    {tokens, star_count} = wc_tokens(String.to_charlist(pattern), [], 0)

    # 'git *' semantics: when the ONLY wildcard is a trailing " *", the
    # space-and-args group is optional so the rule also matches the bare
    # command (aligned with prefix `git:*` semantics).
    tokens =
      case {star_count, Enum.reverse(tokens)} do
        {1, [:star, {:lit, sp} | rest_rev]} when sp in [" ", "\\ "] ->
          Enum.reverse([{:lit, "( .*)?"} | rest_rev])

        _ ->
          tokens
      end

    body =
      tokens
      |> Enum.map(fn
        :star -> ".*"
        {:lit, lit} -> lit
      end)
      |> IO.iodata_to_binary()

    # dotAll so wildcards match embedded newlines (heredocs).
    Regex.compile("^" <> body <> "$", "s")
  end

  defp wc_tokens([?\\, ?* | rest], acc, n), do: wc_tokens(rest, [{:lit, "\\*"} | acc], n)
  defp wc_tokens([?\\, ?\\ | rest], acc, n), do: wc_tokens(rest, [{:lit, "\\\\"} | acc], n)
  defp wc_tokens([?* | rest], acc, n), do: wc_tokens(rest, [:star | acc], n + 1)

  defp wc_tokens([c | rest], acc, n),
    do: wc_tokens(rest, [{:lit, Regex.escape(<<c::utf8>>)} | acc], n)

  defp wc_tokens([], acc, n), do: {Enum.reverse(acc), n}

  @doc """
  Split a shell command into compound subcommands on unquoted `;`, `&`, `|`
  and newlines (`&&`/`||` fall out naturally). Quote- and escape-aware.
  """
  def split_compound(command) when is_binary(command) do
    command
    |> String.to_charlist()
    |> split_walk([], [], :none)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def split_compound(_), do: []

  defp split_walk([], cur, acc, _q), do: Enum.reverse([segment(cur) | acc])

  defp split_walk([?' | r], cur, acc, :none), do: split_walk(r, [?' | cur], acc, :single)
  defp split_walk([?' | r], cur, acc, :single), do: split_walk(r, [?' | cur], acc, :none)
  defp split_walk([?" | r], cur, acc, :none), do: split_walk(r, [?" | cur], acc, :double)
  defp split_walk([?" | r], cur, acc, :double), do: split_walk(r, [?" | cur], acc, :none)

  defp split_walk([?\\, c | r], cur, acc, q) when q != :single,
    do: split_walk(r, [c, ?\\ | cur], acc, q)

  defp split_walk([c | r], cur, acc, :none) when c in [?;, ?|, ?&, ?\n],
    do: split_walk(r, [], [segment(cur) | acc], :none)

  defp split_walk([c | r], cur, acc, q), do: split_walk(r, [c | cur], acc, q)

  defp segment(rev_chars), do: rev_chars |> Enum.reverse() |> List.to_string()

  # ── defaultMode (CC permissions.defaultMode) ─────────────────────────

  # CC `permissions.defaultMode` string → OSA permission-mode atom. Unmapped
  # values (incl. CC "dontAsk", which has no faithful OSA equivalent) fall back
  # to :ask — the safe interactive default — rather than over-permissioning.
  @default_mode_map %{
    "default" => :ask,
    "acceptEdits" => :accept_edits,
    "bypassPermissions" => :overdrive,
    "plan" => :plan
  }

  @doc """
  Startup permission mode from settings `permissions.defaultMode` (CC parity).
  Maps the CC mode string to an OSA mode atom
  (`:ask | :accept_edits | :plan | :overdrive`), defaulting to `:ask` when the
  key is absent or unrecognized. Seed `Loop` initial state with this so the
  settings `defaultMode` is honored on session start.
  """
  def default_mode do
    case Settings.get("permissions") do
      %{"defaultMode" => mode} when is_binary(mode) ->
        Map.get(@default_mode_map, mode, :ask)

      _ ->
        :ask
    end
  rescue
    _ -> :ask
  end

  # ── additionalDirectories + path scope ───────────────────────────────

  @doc "Extra directories (beyond cwd/tmp) writes are scoped to — settings `permissions.additionalDirectories`."
  def additional_directories do
    case Settings.get("permissions") do
      %{"additionalDirectories" => dirs} when is_list(dirs) ->
        Enum.filter(dirs, &is_binary/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Add a directory to the session's allowed scope (in-memory, `/add-dir` backing)."
  def add_directory(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    perms =
      case Settings.layer(:session) |> Map.get("permissions") do
        m when is_map(m) -> m
        _ -> %{}
      end

    dirs = perms |> Map.get("additionalDirectories") |> List.wrap() |> Enum.filter(&is_binary/1)

    Settings.set_session(
      "permissions",
      Map.put(perms, "additionalDirectories", Enum.uniq(dirs ++ [dir]))
    )

    :ok
  end

  @doc "True when `path` resolves under cwd, tmp, or an additional directory."
  def path_in_scope?(path) when is_binary(path) do
    expanded = Path.expand(path)

    roots =
      [File.cwd!(), System.tmp_dir()] ++ Enum.map(additional_directories(), &Path.expand/1)

    Enum.any?(roots, fn root ->
      is_binary(root) and (expanded == root or String.starts_with?(expanded, root <> "/"))
    end)
  rescue
    _ -> true
  end

  def path_in_scope?(_), do: true

  @doc """
  Returns the offending path when a file-mutating tool targets a path outside
  the workspace scope (cwd + tmp + additionalDirectories), else nil.
  """
  def out_of_scope_write(tool_name, args) do
    path = file_path_of(args)

    if tool_name in @file_mutating_tools and is_binary(path) and path != "" and
         not path_in_scope?(path) do
      path
    end
  end

  # ── Bypass-immune safety asks ────────────────────────────────────────

  @doc """
  Returns a reason string when a file-mutating call targets a path that must
  ALWAYS prompt — in every permission mode, overdrive included: `.git/`
  internals, OSA settings/permission files, and shell startup files.
  Returns nil otherwise.
  """
  def bypass_immune_ask(tool_name, args) do
    path = file_path_of(args)

    if tool_name in @file_mutating_tools and is_binary(path) and path != "" do
      protected_path_reason(path)
    end
  end

  defp protected_path_reason(path) do
    expanded = safe_expand(path)
    segments = Path.split(expanded)
    base = Path.basename(expanded)

    cond do
      ".git" in segments ->
        "modifies .git repository internals"

      base in @shell_rc_files ->
        "modifies a shell startup file (#{base})"

      ".osa" in segments and base in ["settings.json", "settings.local.json", "permissions.json"] ->
        "modifies OSA settings / permission rules"

      true ->
        nil
    end
  end

  # ── Private: rule assembly ───────────────────────────────────────────

  defp settings_rules do
    for source <- @settings_sources,
        {behavior, key} <- [deny: "deny", ask: "ask", allow: "allow"],
        rule <- layer_rule_list(source, key) do
      %{behavior: behavior, rule: rule, source: source}
    end
  end

  defp layer_rule_list(source, key) do
    case Settings.layer(source) do
      %{"permissions" => perms} when is_map(perms) ->
        perms |> Map.get(key) |> List.wrap() |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp legacy_rules do
    for {key, action} <- load_legacy(), is_binary(key), action in ["allow", "deny", "ask"] do
      %{behavior: String.to_existing_atom(action), rule: migrate_legacy_rule(key), source: :legacy}
    end
  end

  # Old colon rules ("shell_execute:git *") become "shell_execute(git *)".
  # Rules already in Tool(content) format (or bare tool names) pass through.
  defp migrate_legacy_rule(key) do
    cond do
      String.contains?(key, "(") ->
        key

      String.contains?(key, ":") ->
        case String.split(key, ":", parts: 2) do
          [tool, pattern] when tool != "" and pattern != "" -> rule_to_string(tool, pattern)
          _ -> key
        end

      true ->
        key
    end
  end

  # ── Private: matching ────────────────────────────────────────────────

  # Deny/ask semantics: ANY subcommand (or the full command / primary arg)
  # matching fires the rule. First hit wins (sources are priority-ordered).
  defp first_match(rules, tool_name, args) do
    Enum.find_value(rules, fn r ->
      if rule_hits?(r, tool_name, args), do: meta(r)
    end)
  end

  defp meta(r), do: %{behavior: r.behavior, rule: r.rule, source: r.source}

  defp rule_hits?(r, tool_name, args) do
    case parse_rule(r.rule) do
      %{tool: rtool, content: nil} ->
        tool_rule_matches?(rtool, tool_name)

      %{tool: rtool, content: content} ->
        tool_rule_matches?(rtool, tool_name) and content_hits?(content, tool_name, args)
    end
  end

  defp content_hits?(content, tool_name, args) do
    if shell_tool?(tool_name) do
      cmd = command_of(args)

      # Deny/ask are conservative: the full command OR any subcommand matching
      # fires the rule (more matches → safer).
      is_binary(cmd) and cmd != "" and
        (match_shell_rule?(content, cmd) or
           Enum.any?(shell_subcommands(cmd), &match_shell_rule?(content, &1)))
    else
      val = primary_arg(args)
      is_binary(val) and match_generic_rule?(content, val)
    end
  end

  # Heredoc-bearing commands are treated as a single unit (the dotAll wildcard
  # matcher covers their embedded newlines); everything else splits into
  # compound subcommands.
  defp shell_subcommands(cmd) do
    if String.contains?(cmd, "<<"), do: [cmd], else: split_compound(cmd)
  end

  # Allow semantics (CC): a tool-level allow, a full-command content match, or
  # — for shell — EVERY compound subcommand covered by some allow rule.
  defp allow_match(rules, tool_name, args) do
    parsed = Enum.map(rules, fn r -> {r, parse_rule(r.rule)} end)

    tool_level =
      Enum.find(parsed, fn {_r, p} ->
        p.content == nil and tool_rule_matches?(p.tool, tool_name)
      end)

    content_rules =
      for {r, p} <- parsed, p.content != nil, tool_rule_matches?(p.tool, tool_name), do: {r, p}

    cond do
      tool_level != nil ->
        tool_level |> elem(0) |> meta()

      shell_tool?(tool_name) ->
        shell_allow_match(content_rules, args)

      true ->
        val = primary_arg(args)

        Enum.find_value(content_rules, fn {r, p} ->
          if is_binary(val) and match_generic_rule?(p.content, val), do: meta(r)
        end)
    end
  end

  # An allow NEVER full-matches a compound command (a `cd:*` prefix rule must
  # not cover `cd x && rm -rf /`): single commands match rules directly;
  # compounds require EVERY subcommand covered by some allow rule.
  defp shell_allow_match(content_rules, args) do
    cmd = command_of(args)

    if is_binary(cmd) and String.trim(cmd) != "" do
      case shell_subcommands(cmd) do
        [] ->
          nil

        [single] ->
          Enum.find_value(content_rules, fn {r, p} ->
            if match_shell_rule?(p.content, single), do: meta(r)
          end)

        subs ->
          covered? =
            Enum.all?(subs, fn s ->
              Enum.any?(content_rules, fn {_r, p} -> match_shell_rule?(p.content, s) end)
            end)

          if covered? do
            content_rules |> List.first() |> elem(0) |> meta()
          end
      end
    end
  end

  defp tool_rule_matches?(rtool, tool_name) do
    rtool == tool_name or mcp_server_rule_matches?(rtool, tool_name)
  end

  # MCP server-level rules (WS14 semantics, integrated): "mcp__server" and
  # "mcp__server__*" both match every "mcp__server__<tool>". Deny beats allow
  # via the deny-first evaluation order in check_detailed/2.
  defp mcp_server_rule_matches?("mcp__" <> _ = rtool, "mcp__" <> _ = tool_name) do
    base =
      if String.ends_with?(rtool, "__*"),
        do: binary_part(rtool, 0, byte_size(rtool) - 3),
        else: rtool

    String.starts_with?(tool_name, base <> "__")
  end

  defp mcp_server_rule_matches?(_, _), do: false

  defp match_generic_rule?(content, value) do
    case classify_content(content) do
      {:prefix, prefix} -> value == prefix or String.starts_with?(value, prefix)
      {:wildcard, pattern} -> wildcard_match?(pattern, value)
      {:exact, exact} -> value == exact or safe_expand(value) == safe_expand(exact)
    end
  end

  defp normalize_tool(name), do: Map.get(@tool_aliases, name, name)

  defp shell_tool?(name),
    do: name in OptimalSystemAgent.Agent.Safety.DangerousCommands.shell_tools()

  defp command_of(args) when is_map(args) do
    Map.get(args, "command") || Map.get(args, "code") ||
      args |> Map.values() |> Enum.find(&is_binary/1)
  end

  defp command_of(_), do: nil

  defp primary_arg(args) when is_map(args) do
    Map.get(args, "command") || Map.get(args, "path") || Map.get(args, "url") ||
      Map.get(args, "query") || Map.get(args, "task") || Map.get(args, "target") ||
      args |> Map.values() |> Enum.find(&is_binary/1)
  end

  defp primary_arg(_), do: nil

  defp file_path_of(args) when is_map(args) do
    Map.get(args, "path") || Map.get(args, "file_path") || Map.get(args, "target")
  end

  defp file_path_of(_), do: nil

  # Byte positions of `char` in `bin` preceded by an EVEN number of
  # backslashes (i.e. unescaped). Parens/stars/backslash are all ASCII, so
  # byte scanning is UTF-8 safe.
  defp unescaped_positions(bin, char) do
    bytes = :binary.bin_to_list(bin)

    bytes
    |> Enum.with_index()
    |> Enum.filter(fn {b, i} -> b == char and even_backslashes_before?(bytes, i) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp even_backslashes_before?(bytes, i) do
    bytes
    |> Enum.take(i)
    |> Enum.reverse()
    |> Enum.take_while(&(&1 == ?\\))
    |> length()
    |> rem(2) == 0
  end

  defp safe_expand(path) do
    Path.expand(path)
  rescue
    _ -> path
  end

  # ── Private: legacy store I/O ────────────────────────────────────────

  defp load_legacy do
    case File.read(permissions_file()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, rules} when is_map(rules) -> rules
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp write_legacy(rules) do
    file = permissions_file()
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(rules, pretty: true))
  rescue
    _ -> :ok
  end
end
