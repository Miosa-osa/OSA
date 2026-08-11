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

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.System.JsonStore
  alias OptimalSystemAgent.MCP.Client.ToolBridge
  alias OptimalSystemAgent.Settings

  # Runtime-resolved default so a prebuilt release uses the END USER's home, not
  # the CI runner's baked-in path. The `:permissions_file` app-env override still
  # wins; only this fallback is resolved at call time.
  defp default_permissions_file, do: Path.join(ConfigFile.config_dir(), "permissions.json")

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

  # ── Banned "always allow" prefix suggestions ─────────────────────────
  #
  # Codex parity (`codex-rs/.../exec_policy.rs` `BANNED_PREFIX_SUGGESTIONS`).
  #
  # A prefix rule only constrains the FIRST token(s) of a command. For a
  # general-purpose interpreter, shell, or command wrapper that is no
  # constraint at all: `shell_execute(bash:*)` pre-approves `bash -lc 'rm -rf
  # /'` and every other shell command routed through bash, permanently
  # disabling the dangerous-command classifier. The operator cannot reasonably
  # infer that from a prompt that says "always allow bash".
  #
  # These programs therefore NEVER get an "always" suggestion. A one-time
  # allow is always still available; we never silently downgrade to a narrower
  # looking rule that is not actually narrower.
  @banned_prefix_suggestions ~w(
    bash sh zsh fish dash ksh csh tcsh ash busybox
    python python2 python3 py node nodejs deno bun ruby irb perl php
    lua luajit Rscript julia
    env xargs eval exec source su sudo doas runuser
    ssh scp sftp telnet
    nohup setsid nice time timeout stdbuf script watch chroot unshare
    awk gawk mawk sed find
    osascript powershell pwsh cmd
    rm
  )

  # Two-word prefixes whose SECOND word re-opens arbitrary code execution —
  # `docker run:*` is every container with every mount, `go run:*` is any Go
  # file, `mix run -e '<code>'` is any Elixir. Same reasoning as above: refuse
  # the suggestion outright rather than persist something that looks scoped
  # and is not.
  #
  # Deliberately NOT here: `npm run` / `cargo run` and friends. Their argument
  # space is bounded by the checked-in manifest (package.json scripts, the
  # current crate), not by arbitrary code typed on the command line, so
  # `npm run:*` is a real — if broad — scope. `npm exec` / `pnpm dlx` / `npx`
  # fetch and run arbitrary packages and ARE banned.
  @banned_two_word_seconds %{
    "npm" => ~w(exec x create init),
    "pnpm" => ~w(exec dlx x create init),
    "yarn" => ~w(exec dlx create init),
    "cargo" => ~w(install),
    "go" => ~w(run generate install),
    "mix" => ~w(run cmd escript.install archive.install local.rebar),
    "docker" => ~w(run exec),
    "kubectl" => ~w(exec run attach)
  }

  # Warn-once table for banned rules found already persisted on disk.
  @banned_rule_warned :osa_permissions_banned_rule_warned

  # Resolved at call time (not compile time) so tests can redirect the legacy
  # rule store to a tmp path via `config :optimal_system_agent, :permissions_file`.
  defp permissions_file do
    Application.get_env(:optimal_system_agent, :permissions_file) || default_permissions_file()
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
    (settings_rules() ++ legacy_rules())
    |> Enum.reject(&banned_persisted_rule?/1)
  end

  # LOAD-TIME guard. A banned-shape allow rule may already be on disk from
  # before the suggestion deny-list existed (or be hand-written into a
  # settings file). Guarding only new rules would leave those installs
  # exposed, so refuse to apply them here too — and say so once, naming the
  # rule and the file it came from.
  defp banned_persisted_rule?(%{behavior: :allow, rule: rule, source: source}) do
    if banned_allow_rule?(rule) do
      warn_banned_rule_once(rule, source)
      true
    else
      false
    end
  end

  defp banned_persisted_rule?(_), do: false

  defp warn_banned_rule_once(rule, source) do
    ensure_warn_table()

    if :ets.insert_new(@banned_rule_warned, {{rule, source}, true}) do
      require Logger

      Logger.warning(
        "[permissions] IGNORING persisted allow rule #{inspect(rule)} from #{source_file(source)} " <>
          "— a shell/interpreter prefix allow pre-approves every command run through it and " <>
          "disables the dangerous-command classifier. Remove it, or replace it with an exact " <>
          "command rule."
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp source_file(:legacy), do: permissions_file()
  defp source_file(:local), do: ".osa/settings.local.json"
  defp source_file(:project), do: ".osa/settings.json"
  defp source_file(:user), do: Path.join(ConfigFile.config_dir(), "settings.json")
  defp source_file(:flag), do: "--settings / OSA_SETTINGS file"
  defp source_file(other), do: "#{other} settings"

  defp ensure_warn_table do
    case :ets.whereis(@banned_rule_warned) do
      :undefined ->
        :ets.new(@banned_rule_warned, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ── Rule persistence (legacy store — interactive "Always" decisions) ──

  @doc """
  Save a permission rule to the legacy store (`~/.osa/permissions.json`).

  `rule` may be a bare tool name (`"shell_execute"`) or a full rule string
  (`"shell_execute(npm test:*)"`). Decision is `:allow_always | :deny_always`.

  A `nil` rule (no honest suggestion — see `suggested_rule/2`) and an ALLOW
  rule of banned shape (see `banned_allow_rule?/1`) are refused: persisting
  `shell_execute(bash:*)` would permanently disable the dangerous-command
  classifier. Deny rules are never refused.
  """
  def save_rule(rule, decision) do
    action =
      case decision do
        :allow_always -> "allow"
        :deny_always -> "deny"
        _ -> nil
      end

    cond do
      action == nil ->
        :ok

      not is_binary(rule) ->
        :ok

      action == "allow" and banned_allow_rule?(rule) ->
        require Logger

        Logger.warning(
          "[permissions] refusing to save allow rule #{inspect(rule)} — a shell/interpreter " <>
            "prefix rule pre-approves every command run through it and would disable the " <>
            "dangerous-command classifier. Not written to #{permissions_file()}."
        )

        :ok

      true ->
        update_legacy(&Map.put(&1, rule, action))
    end
  end

  @doc "List saved legacy rules as a `%{rule_string => \"allow\" | \"deny\"}` map."
  def list_rules do
    load_legacy()
  end

  @doc "Remove a saved legacy rule by its exact rule string."
  def remove_rule(rule) do
    update_legacy(&Map.delete(&1, rule))
  end

  @doc """
  The rule string an interactive "Always" decision should persist for a call.

  Shell tools get a prefix rule built from the command (`npm test` →
  `shell_execute(npm test:*)`, CC suggestion semantics); every other tool gets
  a tool-level rule.

  Returns `nil` when no honest "always" rule can be offered for a shell
  command — a general-purpose interpreter/shell/wrapper prefix, a bare `rm`, a
  heredoc, a command substitution, or a compound command. Callers MUST treat
  `nil` as "offer no always option"; a one-time allow is still available.
  """
  def suggested_rule(tool_name, args \\ %{}) do
    cmd = if shell_tool?(tool_name), do: command_of(args), else: nil

    case cmd do
      c when is_binary(c) ->
        case String.trim(c) do
          "" ->
            tool_name

          trimmed ->
            case suggested_prefix(trimmed) do
              nil -> nil
              prefix -> rule_to_string(tool_name, prefix <> ":*")
            end
        end

      _ ->
        tool_name
    end
  end

  @doc """
  The command prefix an "always allow" suggestion should use, or `nil` when
  none is safe to offer.

  NEVER returns a general-purpose interpreter/shell/wrapper (`bash`, `sh`,
  `python3`, `node`, `env`, `xargs`, `sudo`, …), a bare `rm`, or a prefix
  derived from a command whose remainder the prefix cannot constrain
  (heredocs, command substitution, compound commands).
  """
  @spec suggested_prefix(String.t()) :: String.t() | nil
  def suggested_prefix(command) when is_binary(command) do
    trimmed = String.trim(command)

    if unconstrainable_command?(trimmed) do
      nil
    else
      case String.split(trimmed, ~r/\s+/, trim: true) do
        [a, b | _] ->
          head = program_token(a)

          cond do
            head in @banned_prefix_suggestions -> nil
            banned_second_word?(head, b) -> nil
            head in @two_word_prefixes -> a <> " " <> b
            true -> a
          end

        [a] ->
          if program_token(a) in @banned_prefix_suggestions, do: nil, else: a

        [] ->
          nil
      end
    end
  end

  def suggested_prefix(_), do: nil

  # A prefix rule cannot constrain what follows these constructs, so no
  # "always" rule built from such a command is honest.
  defp unconstrainable_command?(command) do
    String.contains?(command, ["<<", "$(", "`"]) or split_compound(command) |> length() > 1
  end

  # `/usr/bin/env`, `./bash`, `\bash` → the bare program name, so a banned
  # interpreter cannot be smuggled in behind a path.
  defp program_token(token) do
    token
    |> String.trim_leading("\\")
    |> Path.basename()
  end

  defp banned_second_word?(head, second) do
    second in Map.get(@banned_two_word_seconds, head, [])
  end

  @doc """
  True when `rule` is an ALLOW rule that must never be honoured: a shell rule
  whose prefix/wildcard head is a banned interpreter, shell, wrapper, or bare
  `rm` (see `suggested_prefix/1`).

  Applies to allow rules only. A DENY (or ASK) rule with the same shape is
  strictly protective and is always honoured.
  """
  @spec banned_allow_rule?(String.t()) :: boolean()
  def banned_allow_rule?(rule) when is_binary(rule) do
    case parse_rule(rule) do
      %{content: nil} ->
        false

      %{tool: tool, content: content} ->
        shell_tool?(tool) and banned_rule_content?(content)
    end
  rescue
    _ -> false
  end

  def banned_allow_rule?(_), do: false

  defp banned_rule_content?(content) do
    head =
      case classify_content(content) do
        {:prefix, prefix} -> prefix
        {:wildcard, pattern} -> pattern |> String.split("*", parts: 2) |> List.first()
        # A fully-spelled-out exact command IS the thing the operator approved.
        {:exact, _} -> nil
      end

    case head do
      nil ->
        false

      head ->
        case head |> String.trim() |> String.split(~r/\s+/, trim: true) do
          [] -> false
          [a | _] -> program_token(a) in @banned_prefix_suggestions
        end
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

  # Legacy top-level `permission_mode` key vocabulary — the loop's original
  # startup source (`auto-edit/plan/overdrive/ask`). Kept as a fallback so
  # existing settings that used this key keep working after `default_mode/0`
  # became the single source of truth. Unknown -> :ask (safe interactive default).
  @legacy_mode_map %{
    "auto-edit" => :accept_edits,
    "plan" => :plan,
    "overdrive" => :overdrive,
    "ask" => :ask
  }

  @doc """
  Startup permission mode from settings (CC parity + legacy fallback).

  Precedence:
    1. CC key `permissions.defaultMode`
       (`default/acceptEdits/bypassPermissions/plan`) when present.
    2. Legacy top-level `permission_mode`
       (`auto-edit/plan/overdrive/ask`) when the CC key is absent.

  Maps to an OSA mode atom (`:ask | :accept_edits | :plan | :overdrive`),
  defaulting to `:ask` when neither key is present or the value is
  unrecognized. `Loop` seeds its initial state with this so the settings
  `defaultMode` is honored on session start (previously this was dead code —
  `Loop.init` read only the legacy key).
  """
  def default_mode do
    case Settings.get_trusted("permissions") do
      %{"defaultMode" => mode} when is_binary(mode) ->
        Map.get(@default_mode_map, mode, :ask)

      _ ->
        legacy_default_mode()
    end
  rescue
    _ -> :ask
  end

  # Fallback to the pre-parity top-level `permission_mode` string enum.
  defp legacy_default_mode do
    case Settings.get_trusted("permission_mode") do
      mode when is_binary(mode) -> Map.get(@legacy_mode_map, mode, :ask)
      _ -> :ask
    end
  end

  # ── additionalDirectories + path scope ───────────────────────────────

  @doc "Extra directories (beyond cwd/tmp) writes are scoped to — settings `permissions.additionalDirectories`."
  def additional_directories do
    case Settings.get_trusted("permissions") do
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
      [OptimalSystemAgent.Workspace.Cwd.get(), System.tmp_dir()] ++
        Enum.map(additional_directories(), &Path.expand/1)

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

  For `multi_file_edit` (no single top-level `path`, an `"edits"` list
  instead) every target path is checked — the FIRST one out of scope is
  returned, so a batch that touches even one foreign path is caught.
  """
  def out_of_scope_write(tool_name, args) do
    if tool_name in @file_mutating_tools do
      Enum.find(file_paths_of(args), fn path -> not path_in_scope?(path) end)
    end
  end

  # ── Bypass-immune safety asks ────────────────────────────────────────

  @doc """
  Returns a reason string when a file-mutating call targets a path that must
  ALWAYS prompt — in every permission mode, overdrive included: `.git/`
  internals, OSA settings/permission files, and shell startup files.
  Returns nil otherwise. Checks every target path for `multi_file_edit`.
  """
  def bypass_immune_ask(tool_name, args) do
    if tool_name in @file_mutating_tools do
      args
      |> file_paths_of()
      |> Enum.find_value(&protected_path_reason/1)
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

      # The credential store for the operator's paid accounts. Reads are
      # denied outright by `file_read`'s sensitive-path list; writes prompt in
      # every mode, overdrive included, because a rewrite is how a
      # subscription token gets swapped for an attacker's or its pinned
      # `base_url` gets redirected — neither of which the agent has any
      # legitimate reason to do.
      ".osa" in segments and base == "subscriptions.json" ->
        "modifies OSA's subscription credential store"

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

  # `trusted_layer/1` (not `layer/1`): the PROJECT layer is checked into the
  # repo, so a hostile clone must not be able to grant itself allow rules — or
  # any rules — before the user has accepted workspace trust. The whole
  # `permissions` block from an untrusted project is withheld (allow, deny,
  # ask and additionalDirectories alike): a partial suppression is harder to
  # reason about, and the built-in classifier + default-`:ask` already provide
  # the protection an untrusted repo's `deny` list would have added.
  defp layer_rule_list(source, key) do
    case Settings.trusted_layer(source) do
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
      %{
        behavior: String.to_existing_atom(action),
        rule: migrate_legacy_rule(key),
        source: :legacy
      }
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
  #
  # The server a key belongs to is decided by `ToolBridge.parse_key/1` — the
  # SAME parse the dispatcher uses — rather than by a prefix test of our own.
  # A rule must scope to exactly the server that will actually be invoked; two
  # independent readings of one key is precisely how `mcp__a` came to cover a
  # tool owned by `a__b`. (`ToolBridge` now also refuses to register a server
  # segment containing `__`, so no such key reaches here in the first place.)
  defp mcp_server_rule_matches?("mcp__" <> _ = rtool, "mcp__" <> _ = tool_name) do
    base =
      if String.ends_with?(rtool, "__*"),
        do: binary_part(rtool, 0, byte_size(rtool) - 3),
        else: rtool

    with "mcp__" <> rule_server <- base,
         {:ok, {server, _tool}} <- ToolBridge.parse_key(tool_name) do
      rule_server == server
    else
      _ -> false
    end
  end

  defp mcp_server_rule_matches?(_, _), do: false

  defp match_generic_rule?(content, value) do
    case classify_content(content) do
      {:prefix, prefix} -> prefix_match?(prefix, value)
      {:wildcard, pattern} -> wildcard_match?(pattern, value)
      {:exact, exact} -> value == exact or safe_expand(value) == safe_expand(exact)
    end
  end

  # A `prefix:*` allow rule matches at a TOKEN BOUNDARY only. A bare
  # `String.starts_with?/2` would let `file_write(/home/u/safe:*)` pre-approve
  # `/home/u/safe-backup-of-everything`, and `WebFetch(https://example.com:*)`
  # pre-approve `https://example.com.evil.tld` — the classic look-alike host.
  #
  # The two sibling matchers in this module already enforce a boundary
  # (`match_shell_rule?/2` demands a space, `path_in_scope?/1` demands a `/`);
  # this is the same discipline generalised, because the delimiter that keeps
  # you inside the same entity depends on what the content IS:
  #
  #   * a URL  — `/`, `?` or `#` stay on the same origin+path; `.`, `-`, `@`
  #              and `:` all move you to a DIFFERENT host, so they are not
  #              boundaries.
  #   * a path — only `/` descends into the approved directory.
  #   * other  — `/` or whitespace; anything else is a different token.
  #
  # A prefix that already ends in one of its own boundary characters
  # (`https://`, `/home/u/safe/`) needs no extra separator.
  defp prefix_match?("", _value), do: false

  defp prefix_match?(prefix, value) when is_binary(prefix) and is_binary(value) do
    cond do
      value == prefix ->
        true

      not String.starts_with?(value, prefix) ->
        false

      true ->
        bounds = prefix_boundaries(prefix)
        String.ends_with?(prefix, bounds) or next_grapheme(value, prefix) in bounds
    end
  end

  defp prefix_match?(_, _), do: false

  # The grapheme of `value` immediately after `prefix` (`nil` when there is none
  # — that case is already handled by the `value == prefix` branch).
  defp next_grapheme(value, prefix) do
    case String.next_grapheme(
           binary_part(value, byte_size(prefix), byte_size(value) - byte_size(prefix))
         ) do
      {g, _rest} -> g
      nil -> nil
    end
  end

  @url_boundaries ["/", "?", "#"]
  @path_boundaries ["/"]
  @generic_boundaries ["/", " ", "\t"]

  defp prefix_boundaries(prefix) do
    cond do
      Regex.match?(~r{^[a-zA-Z][a-zA-Z0-9+.\-]*://}, prefix) -> @url_boundaries
      String.starts_with?(prefix, ["/", "~"]) -> @path_boundaries
      true -> @generic_boundaries
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

  # Every target path for a file-mutating call. Single-path tools
  # (file_write/file_edit/file_create/file_delete/file_move) yield at most
  # one; `multi_file_edit`'s `%{"edits" => [%{"path" => ...}, ...]}` shape has
  # no top-level path, so its edit list is walked explicitly — otherwise a
  # multi-file batch would never be scope/safety checked at all.
  defp file_paths_of(%{"edits" => edits}) when is_list(edits) do
    edits
    |> Enum.map(fn
      %{"path" => p} when is_binary(p) and p != "" -> p
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end

  defp file_paths_of(args) do
    case file_path_of(args) do
      p when is_binary(p) and p != "" -> [p]
      _ -> []
    end
  end

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

  # Read-modify-write of the legacy rule store.
  #
  # Two defects this replaces. First, the read degraded to `%{}` on ANY failure
  # — so a permissions.json that had picked up a stray byte meant the next
  # "always allow" rewrote the file with that single rule and discarded every
  # stored allow AND deny the user had accumulated. Second, the write was a
  # plain `File.write!` under `rescue _ -> :ok`, so a failed write reported
  # success: the user was told their rule was saved when it was not, and would
  # only find out the next time the prompt reappeared.
  #
  # Both halves now fail loudly instead: refuse to write over a store we could
  # not read, and surface write errors.
  @spec update_legacy((map() -> map())) :: :ok | {:error, String.t()}
  defp update_legacy(fun) do
    file = permissions_file()

    with {:ok, rules} <- JsonStore.read_map_for_write(file),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- AtomicFile.write(file, Jason.encode!(fun.(rules), pretty: true)) do
      :ok
    else
      {:error, :corrupt} ->
        msg = JsonStore.corrupt_message("permission rules", file)
        require Logger
        Logger.error("[permissions] #{msg}")
        {:error, msg}

      {:error, reason} ->
        msg = "Failed to write #{file}: #{inspect(reason)}"
        require Logger
        Logger.error("[permissions] #{msg}")
        {:error, msg}
    end
  rescue
    e ->
      require Logger
      Logger.error("[permissions] Failed to update #{permissions_file()}: #{inspect(e)}")
      {:error, Exception.message(e)}
  end
end
